//! GPU search through wgpu (Vulkan), SHA-1 only.
//!
//! The compute shader is generated per job: the midstate, every tail word and
//! the target are baked in as constants, so the shader compiler folds all
//! work that does not depend on the nonce. Each invocation spells its 16
//! nonce digits from a per-dispatch high word and its own low word.

use crate::job::{Algo, Job};
use crate::Search;
use std::fmt::Write as _;
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

const WORKGROUP: u32 = 256;
/// Workgroups along x; one dispatch row covers 2^20 counters.
const ROW_GROUPS: u32 = 4096;
const ROW: u64 = (WORKGROUP * ROW_GROUPS) as u64;
const MAX_ROWS: u64 = 1024;
/// Dispatches grow until one takes about this long, bounding stop latency.
const TARGET_DISPATCH: Duration = Duration::from_millis(25);
/// The shader is fully unrolled; longer tails stay on the CPU.
pub const MAX_TAIL_BLOCKS: usize = 32;

/// Whether this job suits the GPU kernel at all.
pub fn eligible(job: &Job) -> bool {
    job.algo == Algo::Sha1 && job.width == 16 && job.tail.len() <= MAX_TAIL_BLOCKS
}

fn shader(job: &Job) -> String {
    let mut s = String::new();
    let w = &mut s;
    w.push_str(
        "@group(0) @binding(0) var<uniform> dispatch: vec4<u32>;\n\
         @group(0) @binding(1) var<storage, read_write> result: array<atomic<u32>, 4>;\n\
         fn rotl(x: u32, n: u32) -> u32 { return (x << n) | (x >> (32u - n)); }\n\
         fn hexchar(d: u32) -> u32 { return d + 48u + select(0u, 39u, d > 9u); }\n",
    );
    let _ = writeln!(w, "@compute @workgroup_size({WORKGROUP})");
    w.push_str(
        "fn main(@builtin(global_invocation_id) gid: vec3<u32>, @builtin(num_workgroups) groups: vec3<u32>) {\n",
    );
    let _ = writeln!(w, "  let hi = dispatch.x;");
    let _ = writeln!(w, "  let lo = dispatch.y + gid.x + gid.y * (groups.x * {WORKGROUP}u);");
    // Digits 0..8 come from the high word, 8..16 from the low word, most significant first.
    for j in 0..16 {
        let (src, shift) = if j < 8 { ("hi", 28 - 4 * j) } else { ("lo", 28 - 4 * (j - 8)) };
        let _ = writeln!(w, "  let n{j} = hexchar(({src} >> {shift}u) & 15u);");
    }
    for i in 0..5 {
        let _ = writeln!(w, "  var h{i} = {:#010x}u;", job.midstate[i]);
    }
    let _ = writeln!(w, "  var a: u32; var b: u32; var c: u32; var d: u32; var e: u32;");
    for i in 0..16 {
        let _ = writeln!(w, "  var w{i}: u32;");
    }

    for (bi, block) in job.tail.iter().enumerate() {
        for i in 0..16 {
            let base = bi * 64 + i * 4;
            let mut constant = u32::from_be_bytes([block[i * 4], block[i * 4 + 1], block[i * 4 + 2], block[i * 4 + 3]]);
            let mut expr = String::new();
            for k in 0..4 {
                let p = base + k;
                if p >= job.nonce_at && p < job.nonce_at + 16 {
                    let shift = 24 - 8 * k;
                    constant &= !(0xffu32 << shift);
                    let _ = write!(expr, " | (n{} << {shift}u)", p - job.nonce_at);
                }
            }
            let _ = writeln!(w, "  w{i} = {constant:#010x}u{expr};");
        }
        let _ = writeln!(w, "  a = h0; b = h1; c = h2; d = h3; e = h4;");
        // Rename instead of shuffling: after a round, (a, b, c, d, e) are held by (e, a, b, c, d).
        let mut v = ["a", "b", "c", "d", "e"];
        for t in 0..80 {
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
            let [a, b, c, d, e] = v;
            let (f, k) = match t {
                0..=19 => (format!("(({c} ^ {d}) & {b}) ^ {d}"), 0x5a827999u32),
                20..=39 => (format!("{b} ^ {c} ^ {d}"), 0x6ed9eba1),
                40..=59 => (format!("({b} & {c}) | ({d} & ({b} | {c}))"), 0x8f1bbcdc),
                _ => (format!("{b} ^ {c} ^ {d}"), 0xca62c1d6),
            };
            let _ = writeln!(w, "  {e} = rotl({a}, 5u) + ({f}) + {e} + {k:#010x}u + w{};", t % 16);
            let _ = writeln!(w, "  {b} = rotl({b}, 30u);");
            v = [e, a, b, c, d];
        }
        let [a, b, c, d, e] = v;
        let _ = writeln!(w, "  h0 += {a}; h1 += {b}; h2 += {c}; h3 += {d}; h4 += {e};");
    }

    let checks: Vec<String> = (0..job.target.words)
        .filter(|&i| job.target.mask[i] != 0)
        .map(|i| format!("((h{i} & {:#010x}u) == {:#010x}u)", job.target.mask[i], job.target.value[i]))
        .collect();
    let _ = writeln!(w, "  if {} {{", if checks.is_empty() { "true".to_string() } else { checks.join(" && ") });
    w.push_str(
        "    if atomicAdd(&result[0], 1u) == 0u {\n\
         \x20     atomicStore(&result[1], lo);\n\
         \x20     atomicStore(&result[2], hi);\n\
         \x20   }\n\
         \x20 }\n\
         }\n",
    );
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
    let (device, queue) = pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor {
        label: Some("git-mine-commit"),
        ..Default::default()
    }))
    .map_err(|e| format!("cannot open {}: {e}", info.name))?;

    let module = device.create_shader_module(wgpu::ShaderModuleDescriptor {
        label: Some("sha1-mine"),
        source: wgpu::ShaderSource::Wgsl(shader(job).into()),
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
        size: 16,
        usage: wgpu::BufferUsages::STORAGE | wgpu::BufferUsages::COPY_SRC | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let readback = device.create_buffer(&wgpu::BufferDescriptor {
        label: Some("readback"),
        size: 16,
        usage: wgpu::BufferUsages::MAP_READ | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
        label: None,
        layout: &pipeline.get_bind_group_layout(0),
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: dispatch.as_entire_binding() },
            wgpu::BindGroupEntry { binding: 1, resource: result.as_entire_binding() },
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
        encoder.copy_buffer_to_buffer(&result, 0, &readback, 0, 16);
        queue.submit([encoder.finish()]);
        readback.map_async(wgpu::MapMode::Read, .., |_| {});
        device
            .poll(wgpu::PollType::Wait { submission_index: None, timeout: None })
            .map_err(|e| format!("GPU poll failed: {e}"))?;
        let hit = {
            let view = readback.get_mapped_range(..).map_err(|e| format!("GPU readback failed: {e:?}"))?;
            let r: Vec<u32> = view.chunks(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect();
            (r[0] != 0).then(|| (u64::from(r[2]) << 32) | u64::from(r[1]))
        };
        readback.unmap();
        search.hashed.fetch_add(n_rows * ROW, Ordering::Relaxed);
        search.gpu_hashed.fetch_add(n_rows * ROW, Ordering::Relaxed);

        if let Some(hit) = hit {
            // The shader is generated code; confirm the hit with the reference hash.
            if job.target.matches(&job.digest(hit)) {
                search.found(hit, "gpu");
                return Ok(());
            }
            return Err(format!("GPU reported nonce {} that does not match; kernel bug", job.format_nonce(hit)));
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
