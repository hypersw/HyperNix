//! git-mine-commit — picks the value of a commit's `nonce` header so that the
//! commit's object name starts with a chosen hex prefix.
//!
//! Called by the patched git (see ../git-mine.patch) with the commit body on
//! stdin; prints the nonce digits on stdout and exits 0, or exits 1 when the
//! time budget runs out. `--benchmark` measures the hash rate instead.

mod cpu;
mod gpu;
mod job;

use job::{Algo, Job, Target};
use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// State shared by all backends of one search.
pub struct Search {
    pub stop: AtomicBool,
    /// Attempts by all backends.
    pub hashed: AtomicU64,
    /// The GPU's share of `hashed`.
    pub gpu_hashed: AtomicU64,
    result: Mutex<Option<(u64, &'static str)>>,
}

impl Search {
    fn new() -> Search {
        Search {
            stop: AtomicBool::new(false),
            hashed: AtomicU64::new(0),
            gpu_hashed: AtomicU64::new(0),
            result: Mutex::new(None),
        }
    }

    /// Records the first hit and stops every backend; later hits are ignored.
    pub fn found(&self, counter: u64, backend: &'static str) {
        let mut result = self.result.lock().unwrap();
        if result.is_none() {
            *result = Some((counter, backend));
        }
        self.stop.store(true, Ordering::Relaxed);
    }
}

struct Options {
    algo: Algo,
    prefix: Option<String>,
    offset: Option<usize>,
    width: usize,
    timeout: Duration,
    threads: usize,
    verbose: bool,
    benchmark: bool,
    backend: Backend,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Backend {
    Cpu,
    Gpu,
    /// The CPU and the GPU race on disjoint halves of the counter space.
    All,
}

const USAGE: &str = "\
usage: git-mine-commit --prefix <hex> --offset <n> [--width <n>] [--algo sha1|sha256]
                       [--timeout <seconds>] [--threads <n>] [--backend cpu|gpu|all]
                       [--verbose]   < commit-body
       git-mine-commit --benchmark [--algo sha1|sha256] [--timeout <seconds>] [--threads <n>]
                       [--backend cpu|gpu|all]";

fn parse_options() -> Result<Options, String> {
    let mut o = Options {
        algo: Algo::Sha1,
        prefix: None,
        offset: None,
        width: 16,
        timeout: Duration::from_secs(60),
        // Half the cores by default, so a commit does not starve whatever else is running.
        threads: std::thread::available_parallelism().map_or(1, |n| (n.get() / 2).max(1)),
        verbose: false,
        benchmark: false,
        backend: Backend::All,
    };
    let mut args = std::env::args().skip(1);
    while let Some(arg) = args.next() {
        // Both "--key value" and "--key=value".
        let (key, inline) = match arg.split_once('=') {
            Some((k, v)) => (k.to_string(), Some(v.to_string())),
            None => (arg.clone(), None),
        };
        let mut value = || inline.clone().or_else(|| args.next()).ok_or(format!("{key} needs a value"));
        let number = |v: String| v.parse::<usize>().map_err(|_| format!("{key}: '{v}' is not a number"));
        match key.as_str() {
            "--algo" => {
                let v = value()?;
                o.algo = Algo::parse(&v).ok_or(format!("unsupported hash algorithm '{v}'"))?
            }
            "--prefix" => o.prefix = Some(value()?),
            "--offset" => o.offset = Some(number(value()?)?),
            "--width" => o.width = number(value()?)?,
            "--threads" => o.threads = number(value()?)?.max(1),
            "--timeout" => {
                let v = value()?;
                let secs = v.parse::<f64>().map_err(|_| format!("--timeout: '{v}' is not a number"))?;
                o.timeout = Duration::from_secs_f64(secs.max(0.0));
            }
            "--verbose" | "-v" => o.verbose = true,
            "--benchmark" => o.benchmark = true,
            "--backend" => {
                o.backend = match value()?.as_str() {
                    "cpu" => Backend::Cpu,
                    "gpu" => Backend::Gpu,
                    "all" => Backend::All,
                    v => return Err(format!("unknown backend '{v}'")),
                }
            }
            "--help" | "-h" => {
                println!("{USAGE}");
                std::process::exit(0);
            }
            _ => return Err(format!("unknown argument '{arg}'")),
        }
    }
    Ok(o)
}

/// Runs every backend on `job` until a hit, exhaustion or the deadline.
fn search(job: &Job, o: &Options) -> (Arc<Search>, Duration) {
    let search = Arc::new(Search::new());
    let started = Instant::now();
    let end = u64::try_from(job.space()).unwrap_or(u64::MAX);
    std::thread::scope(|scope| {
        let timer = Arc::clone(&search);
        let timeout = o.timeout;
        scope.spawn(move || {
            while started.elapsed() < timeout && !timer.stop.load(Ordering::Relaxed) {
                std::thread::sleep(Duration::from_millis(10).min(timeout.saturating_sub(started.elapsed())));
            }
            timer.stop.store(true, Ordering::Relaxed);
        });
        let use_gpu = o.backend != Backend::Cpu && gpu::eligible(job);
        if o.backend == Backend::Gpu && !use_gpu {
            eprintln!(
                "git-mine-commit: the GPU kernel handles only SHA-1 with 16-digit nonces and up to {} tail blocks; using the CPU",
                gpu::MAX_TAIL_BLOCKS
            );
        }
        // The GPU takes the upper half of the counter space, the CPU the lower.
        let half = 1u64 << 63;
        if use_gpu {
            let gpu_search = Arc::clone(&search);
            let verbose = o.verbose;
            scope.spawn(move || {
                if let Err(e) = gpu::run(job, &gpu_search, half, verbose) {
                    // Without a GPU the CPU keeps going; GPU-only mode has nothing left.
                    if verbose || o.backend == Backend::Gpu {
                        eprintln!("git-mine-commit: gpu: {e}");
                    }
                    if o.backend == Backend::Gpu {
                        gpu_search.stop.store(true, Ordering::Relaxed);
                    }
                }
            });
        }
        if o.backend != Backend::Gpu || !use_gpu {
            cpu::run(job, &search, o.threads, 0, if use_gpu { half } else { end });
            // Exhausting the CPU's space ends the search too.
            search.stop.store(true, Ordering::Relaxed);
        }
    });
    (search, started.elapsed())
}

fn rate(hashed: u64, elapsed: Duration) -> String {
    format!("{:.1} MH/s", hashed as f64 / elapsed.as_secs_f64() / 1e6)
}

fn benchmark(o: &Options) -> Result<(), String> {
    // A typical small commit; a prefix of all 1-bits is never expected to hit.
    let body = b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n\
parent 4b825dc642cb6eb9a060e54bf8d69288fbee4904\n\
author A U Thor <author@example.com> 1700000000 +0000\n\
committer C O Mitter <committer@example.com> 1700000000 +0000\n\
nonce 0000000000000000\n\
\n\
Benchmark the commit miner\n";
    let offset = body.windows(6).position(|w| w == b"nonce ").unwrap() + 6;
    let target = Target::parse(&"f".repeat(o.algo.words() * 8), o.algo)?;
    let job = Job::new(o.algo, target, body, offset, 16)?;
    let (search, elapsed) = search(&job, o);
    let hashed = search.hashed.load(Ordering::Relaxed);
    let gpu_hashed = search.gpu_hashed.load(Ordering::Relaxed);
    println!(
        "{:?}, {} blocks per attempt: total {} = cpu {} ({} threads) + gpu {}",
        o.algo,
        job.tail.len(),
        rate(hashed, elapsed),
        rate(hashed - gpu_hashed, elapsed),
        o.threads,
        rate(gpu_hashed, elapsed)
    );
    Ok(())
}

fn mine(o: &Options) -> Result<bool, String> {
    let prefix = o.prefix.as_deref().ok_or("--prefix is required")?;
    let offset = o.offset.ok_or("--offset is required")?;
    let target = Target::parse(prefix, o.algo)?;
    let mut body = Vec::new();
    std::io::stdin().read_to_end(&mut body).map_err(|e| format!("reading the commit body: {e}"))?;
    let job = Job::new(o.algo, target, &body, offset, o.width)?;

    let (search, elapsed) = search(&job, o);
    let hashed = search.hashed.load(Ordering::Relaxed);
    let result = *search.result.lock().unwrap();
    match result {
        Some((counter, backend)) => {
            if o.verbose {
                eprintln!(
                    "git-mine-commit: {} via {backend} after {hashed} attempts in {:.2}s ({})",
                    job.digest_hex(counter),
                    elapsed.as_secs_f64(),
                    rate(hashed, elapsed)
                );
            }
            let mut stdout = std::io::stdout().lock();
            writeln!(stdout, "{}", job.format_nonce(counter)).map_err(|e| e.to_string())?;
            stdout.flush().map_err(|e| e.to_string())?;
            Ok(true)
        }
        None => {
            eprintln!(
                "git-mine-commit: no '{prefix}' hash after {hashed} attempts in {:.1}s ({}; about {:.0} expected)",
                elapsed.as_secs_f64(),
                rate(hashed, elapsed),
                job.target.expected_attempts()
            );
            Ok(false)
        }
    }
}

fn main() {
    let outcome = parse_options().and_then(|o| if o.benchmark { benchmark(&o).map(|_| true) } else { mine(&o) });
    // Exit right away: a GPU backend may still be tearing down.
    match outcome {
        Ok(true) => std::process::exit(0),
        Ok(false) => std::process::exit(1),
        Err(e) => {
            eprintln!("git-mine-commit: {e}\n{USAGE}");
            std::process::exit(2);
        }
    }
}
