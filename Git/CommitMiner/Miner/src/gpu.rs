//! GPU search through wgpu (Vulkan), SHA-1 only.
//!
//! The compute shader is the same for every commit, so the driver's shader
//! cache serves it after the first compile. Everything about the commit
//! travels in the `job` storage buffer (see `job_words`): the midstate, the
//! targets, a template of the one or two blocks the nonce touches, and the
//! precomputed message schedule of every block after them. Each invocation
//! spells its 16 nonce digits from a per-dispatch high word and its own low
//! word, rebuilds the nonce blocks, then loops over the remaining blocks.

use crate::job::{Algo, Block, Job};
use crate::Search;
use std::fmt::Write as _;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

const WORKGROUP: u32 = 256;
/// Workgroups along x; one dispatch row covers 2^16 counters.
const ROW_GROUPS: u32 = 256;
const ROW: u64 = (WORKGROUP * ROW_GROUPS) as u64;
/// Bounded by the 65535 workgroups a dispatch may have along y.
const MAX_ROWS: u64 = 16384;
/// Dispatches grow until one takes about this long, bounding stop latency.
const TARGET_DISPATCH: Duration = Duration::from_millis(25);

// Word offsets in the `job` buffer; the shader text is generated from the same constants.
const MIDSTATE: usize = 0;
const MASK: usize = 5;
const VALUE: usize = 10;
const FALLBACK_MASK: usize = 15;
const FALLBACK_VALUE: usize = 20;
const HAS_FALLBACK: usize = 25;
/// Index of the first word the nonce touches, counted from the start of the tail.
const NONCE_WORD: usize = 26;
/// Byte offset of the nonce within that word, 0..4.
const NONCE_SHIFT: usize = 27;
/// How many leading tail blocks the nonce touches: 1 or 2.
const NONCE_BLOCKS: usize = 28;
const BLOCKS: usize = 29;
/// Two blocks of 16 words with the nonce bytes zeroed.
const TEMPLATE: usize = 32;
/// 80 schedule words per block after the nonce blocks.
const SCHEDULE: usize = 64;

/// Whether this job suits the GPU kernel at all.
pub fn eligible(job: &Job) -> bool {
    job.algo == Algo::Sha1 && job.width == 16
}

/// SHA-1's message schedule: the word each of the 80 rounds mixes in.
fn schedule(block: &Block) -> [u32; 80] {
    let mut w = [0u32; 80];
    for (t, word) in block.chunks(4).enumerate() {
        w[t] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
    }
    for t in 16..80 {
        w[t] = (w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16]).rotate_left(1);
    }
    w
}

/// The `job` buffer contents, laid out as the constants above describe.
fn job_words(job: &Job) -> Vec<u32> {
    let nonce_blocks = if job.nonce_at + job.width > 64 { 2 } else { 1 };
    let mut v = vec![0u32; SCHEDULE];
    v[MIDSTATE..MIDSTATE + 5].copy_from_slice(&job.midstate[..5]);
    v[MASK..MASK + 5].copy_from_slice(&job.target.mask[..5]);
    v[VALUE..VALUE + 5].copy_from_slice(&job.target.value[..5]);
    if let Some(fallback) = &job.fallback {
        v[FALLBACK_MASK..FALLBACK_MASK + 5].copy_from_slice(&fallback.mask[..5]);
        v[FALLBACK_VALUE..FALLBACK_VALUE + 5].copy_from_slice(&fallback.value[..5]);
        v[HAS_FALLBACK] = 1;
    }
    v[NONCE_WORD] = (job.nonce_at / 4) as u32;
    v[NONCE_SHIFT] = (job.nonce_at % 4) as u32;
    v[NONCE_BLOCKS] = nonce_blocks as u32;
    v[BLOCKS] = job.tail.len() as u32;
    for b in 0..nonce_blocks {
        let mut block = job.tail[b];
        // The shader ORs the digits in, so their bytes must start out as zero.
        for p in job.nonce_at..job.nonce_at + job.width {
            if p / 64 == b {
                block[p % 64] = 0;
            }
        }
        for (i, word) in block.chunks(4).enumerate() {
            v[TEMPLATE + 16 * b + i] = u32::from_be_bytes([word[0], word[1], word[2], word[3]]);
        }
    }
    for block in &job.tail[nonce_blocks..] {
        v.extend_from_slice(&schedule(block));
    }
    v
}

/// One compression of the block in w0..w15 (expanded on the fly) or at `job[base..base + 80]` (precomputed) into h0..h4.
fn compress(w: &mut String, is_precomputed: bool) {
    let _ = writeln!(w, "  a = h0; b = h1; c = h2; d = h3; e = h4;");
    // Rename instead of shuffling: after a round, (a, b, c, d, e) are held by (e, a, b, c, d).
    let mut v = ["a", "b", "c", "d", "e"];
    for t in 0..80 {
        let word = if is_precomputed {
            format!("job[base + {t}u]")
        } else {
            if t >= 16 {
                let _ = writeln!(
                    w,
                    "  w{0} = rotl(w{1} ^ w{2} ^ w{3} ^ w{0}, 1u);",
                    t % 16,
                    (t + 13) % 16,
                    (t + 8) % 16,
                    (t + 2) % 16
                );
            }
            format!("w{}", t % 16)
        };
        let [a, b, c, d, e] = v;
        let (f, k) = match t {
            0..=19 => (format!("(({c} ^ {d}) & {b}) ^ {d}"), 0x5a827999u32),
            20..=39 => (format!("{b} ^ {c} ^ {d}"), 0x6ed9eba1),
            40..=59 => (format!("({b} & {c}) | ({d} & ({b} | {c}))"), 0x8f1bbcdc),
            _ => (format!("{b} ^ {c} ^ {d}"), 0xca62c1d6),
        };
        let _ = writeln!(w, "  {e} = rotl({a}, 5u) + ({f}) + {e} + {k:#010x}u + {word};");
        let _ = writeln!(w, "  {b} = rotl({b}, 30u);");
        v = [e, a, b, c, d];
    }
    let [a, b, c, d, e] = v;
    let _ = writeln!(w, "  h0 += {a}; h1 += {b}; h2 += {c}; h3 += {d}; h4 += {e};");
}

/// Builds the nonce block `b` from its template into w0..w15 and compresses it.
fn nonce_block(w: &mut String, b: usize) {
    for i in 0..16 {
        let g = 16 * b + i;
        let _ = writeln!(w, "  w{i} = job[{}u] | pick({g}u - nw, e0, e1, e2, e3, e4);", TEMPLATE + g);
    }
    compress(w, false);
}

/// WGSL test of the digest words h0..h4 against the target stored at `mask` and `value`.
fn condition(mask: usize, value: usize) -> String {
    (0..5)
        .map(|i| format!("((h{i} & job[{}u]) == job[{}u])", mask + i, value + i))
        .collect::<Vec<_>>()
        .join(" && ")
}

/// WGSL that stores this invocation's counter in result slots `at + 1, at + 2`, unless an earlier hit took them.
fn record(at: usize) -> String {
    format!(
        "    if atomicAdd(&result[{at}], 1u) == 0u {{\n\
         \x20     atomicStore(&result[{}], lo);\n\
         \x20     atomicStore(&result[{}], hi);\n\
         \x20   }}\n",
        at + 1,
        at + 2
    )
}

/// The kernel; it does not depend on the job.
fn shader() -> String {
    let mut s = String::new();
    let w = &mut s;
    w.push_str(
        "@group(0) @binding(0) var<uniform> dispatch: vec4<u32>;\n\
         @group(0) @binding(1) var<storage, read_write> result: array<atomic<u32>, 8>;\n\
         @group(0) @binding(2) var<storage, read> job: array<u32>;\n\
         fn rotl(x: u32, n: u32) -> u32 { return (x << n) | (x >> (32u - n)); }\n\
         fn hexchar(d: u32) -> u32 { return d + 48u + select(0u, 39u, d > 9u); }\n\
         // The four hex characters of the low 16 bits of x, most significant first, packed big-endian.\n\
         fn chars(x: u32) -> u32 {\n\
         \x20 return (hexchar((x >> 12u) & 15u) << 24u) | (hexchar((x >> 8u) & 15u) << 16u)\n\
         \x20   | (hexchar((x >> 4u) & 15u) << 8u) | hexchar(x & 15u);\n\
         }\n\
         // Word d of the nonce as it lies in the message, or zero where the nonce does not reach.\n\
         fn pick(d: u32, e0: u32, e1: u32, e2: u32, e3: u32, e4: u32) -> u32 {\n\
         \x20 return select(0u, e0, d == 0u) | select(0u, e1, d == 1u) | select(0u, e2, d == 2u)\n\
         \x20   | select(0u, e3, d == 3u) | select(0u, e4, d == 4u);\n\
         }\n",
    );
    let _ = writeln!(w, "@compute @workgroup_size({WORKGROUP})");
    w.push_str(
        "fn main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) groups: vec3<u32>) {\n",
    );
    let _ = writeln!(w, "  let hi = dispatch.x;");
    let _ = writeln!(w, "  let lo = dispatch.y + gid.x + gid.y * (groups.x * {WORKGROUP}u);");
    // The 16 digits as four packed words, then shifted into the message's own word alignment.
    w.push_str(
        "  let c0 = chars(hi >> 16u); let c1 = chars(hi & 0xffffu);\n\
         \x20 let c2 = chars(lo >> 16u); let c3 = chars(lo & 0xffffu);\n",
    );
    let _ = writeln!(w, "  let nw = job[{NONCE_WORD}u];");
    let _ = writeln!(w, "  let s = job[{NONCE_SHIFT}u] * 8u;");
    // A shift by 32 is a shift by 0 in WGSL, so the aligned case needs its own branch.
    w.push_str(
        "  var e0 = c0; var e1 = c1; var e2 = c2; var e3 = c3; var e4 = 0u;\n\
         \x20 if s != 0u {\n\
         \x20   let r = 32u - s;\n\
         \x20   e0 = c0 >> s; e1 = (c0 << r) | (c1 >> s); e2 = (c1 << r) | (c2 >> s);\n\
         \x20   e3 = (c2 << r) | (c3 >> s); e4 = c3 << r;\n\
         \x20 }\n",
    );
    for i in 0..5 {
        let _ = writeln!(w, "  var h{i} = job[{}u];", MIDSTATE + i);
    }
    let _ = writeln!(w, "  var a: u32; var b: u32; var c: u32; var d: u32; var e: u32;");
    for i in 0..16 {
        let _ = writeln!(w, "  var w{i}: u32;");
    }

    nonce_block(w, 0);
    let _ = writeln!(w, "  let nonce_blocks = job[{NONCE_BLOCKS}u];");
    w.push_str("  if nonce_blocks == 2u {\n");
    nonce_block(w, 1);
    w.push_str("  }\n");
    // Every invocation runs the same blocks, so the loop and its loads stay uniform.
    let _ = writeln!(w, "  for (var blk = nonce_blocks; blk < job[{BLOCKS}u]; blk++) {{");
    let _ = writeln!(w, "  let base = {SCHEDULE}u + (blk - nonce_blocks) * 80u;");
    compress(w, true);
    w.push_str("  }\n");

    // Slots 0..3 take the first full hit, slots 4..7 the first fallback hit.
    let _ = writeln!(w, "  if {} {{", condition(MASK, VALUE));
    w.push_str(&record(0));
    let _ = writeln!(w, "  }} else if job[{HAS_FALLBACK}u] != 0u && {} {{", condition(FALLBACK_MASK, FALLBACK_VALUE));
    w.push_str(&record(4));
    w.push_str("  }\n}\n");
    s
}

/// Searches counters from `start` upward until the search stops; returns why it did not run.
pub fn run(job: &Job, search: &Arc<Search>, start: u64, verbose: bool) -> Result<(), String> {
    let started = Instant::now();
    let instance = wgpu::Instance::new(wgpu::InstanceDescriptor {
        backends: wgpu::Backends::VULKAN,
        ..wgpu::InstanceDescriptor::new_without_display_handle()
    });
    let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
        power_preference: wgpu::PowerPreference::HighPerformance,
        force_fallback_adapter: false,
        compatible_surface: None,
        ..Default::default()
    }))
    .map_err(|e| format!("no GPU adapter: {e}"))?;
    let info = adapter.get_info();
    // A software rasterizer (llvmpipe) would only compete with the CPU threads.
    if info.device_type == wgpu::DeviceType::Cpu {
        return Err(format!("only a software adapter is available ({})", info.name));
    }
    let job_bytes: Vec<u8> = job_words(job).iter().flat_map(|w| w.to_le_bytes()).collect();
    // The default limit (128 MiB) is far beyond any commit message, but say so rather than fail obscurely.
    let limits = adapter.limits();
    if job_bytes.len() as u64 > limits.max_storage_buffer_binding_size {
        return Err(format!("the commit needs a {}-byte job buffer, more than {} allows", job_bytes.len(), info.name));
    }
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("git-mine-commit"),
        ..Default::default()
    }))
    .map_err(|e| format!("cannot open {}: {e}", info.name))?;

    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("sha1-mine"),
        source: wgpu::ShaderSource::Wgsl(shader().into()),
    });
    let pipeline = device.create_compute_pipeline(&wgpu::ComputePipelineDescriptor {
        label: Some("sha1-mine"),
        layout: None,
        module: &module,
        entry_point: Some("main"),
        compilation_options: Default::default(),
        cache: None,
    });
    let dispatch = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("dispatch"),
        size: 16,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let result = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("result"),
        size: 32,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: 32,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let job_buffer = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("job"),
        size: job_bytes.len() as u64,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    queue.write_buffer(&job_buffer, 0, &job_bytes);
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: dispatch.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: result.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 2, resource: job_buffer.as_entire_binding() },
        ],
    });
    if verbose {
        eprintln!(
            "git-mine-commit: gpu {} ({:?}) ready after {:.0}ms",
            info.name,
            info.backend,
            started.elapsed().as_secs_f64() * 1e3
        );
    }

    let mut counter = start;
    let mut rows = 1u64;
    while !search.stop.load(Ordering::Relaxed) {
        // A dispatch must not carry the low word past 2^32; counters stay multiples of ROW.
        let lo_left = (1u64 << 32) - (counter & 0xffff_ffff);
        let n_rows = rows.min(lo_left / ROW);
        let words = [(counter >> 32) as u32, counter as u32, 0, 0];
        queue.write_buffer(&dispatch, 0, &words.iter().flat_map(|w| w.to_le_bytes()).collect::<Vec<u8>>());

        let t0 = Instant::now();
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        {
            let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor { label: None, timestamp_writes: None });
            pass.set_pipeline(&pipeline);
            pass.set_bind_group(0, &bind_group, &[]);
            pass.dispatch_workgroups(ROW_GROUPS, n_rows as u32, 1);
        }
        encoder.copy_buffer_to_buffer(&result, 0, &readback, 0, 32);
        queue.submit([encoder.finish()]);
        readback.map_async(wgpu::MapMode::Read, .., |_| {});
        device
            .poll(wgpu::PollType::Wait { submission_index: None, timeout: None })
            .map_err(|e| format!("GPU poll failed: {e}"))?;
        let (hit, fallback_hit) = {
            let view = readback.get_mapped_range(..).map_err(|e| format!("GPU readback failed: {e:?}"))?;
            let r: Vec<u32> = view.chunks(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
            let slot = |at: usize| (r[at] != 0).then(|| (u64::from(r[at + 2]) << 32) | u64::from(r[at + 1]));
            (slot(0), slot(4))
        };
        readback.unmap();
        search.hashed.fetch_add(n_rows * ROW, Ordering::Relaxed);
        search.gpu_hashed.fetch_add(n_rows * ROW, Ordering::Relaxed);

        if let Some(hit) = hit {
            // The kernel is generated code; confirm the hit with the reference hash.
            if job.target.matches(&job.digest(hit)) {
                search.found(hit, "gpu");
                return Ok(());
            }
            return Err(format!("GPU reported nonce {} that does not match; kernel bug", job.format_nonce(hit)));
        }
        // The slot keeps reporting its first hit, so only the first readback of it counts.
        if let (Some(hit), Some(fallback)) = (fallback_hit, &job.fallback) {
            if !search.has_candidate.load(Ordering::Relaxed) {
                if !fallback.matches(&job.digest(hit)) {
                    return Err(format!("GPU reported fallback nonce {} that does not match; kernel bug", job.format_nonce(hit)));
                }
                search.fallback_found(hit, "gpu");
            }
        }
        if t0.elapsed() < TARGET_DISPATCH && rows < MAX_ROWS {
            rows *= 2;
        }
        counter = match counter.checked_add(n_rows * ROW) {
            Some(c) => c,
            None => return Ok(()),
        };
    }
    Ok(())
}

