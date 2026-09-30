//! Multithreaded CPU search; SHA-NI is picked up at runtime by the sha1/sha2 crates.

use crate::job::Job;
use crate::Search;
use std::sync::atomic::Ordering;
use std::sync::Arc;

/// Attempts between checks of the shared stop flag.
const BATCH: u64 = 1 << 14;

/// Searches counters `start, start + threads, …` below `end` on each thread.
pub fn run(job: &Job, search: &Arc<Search>, threads: usize, start: u64, end: u64) {
    std::thread::scope(|scope| {
        for t in 0..threads as u64 {
            let search = Arc::clone(search);
            scope.spawn(move || {
                let mut tail = job.tail.clone();
                let mut counter = start + t;
                let step = threads as u64;
                while !search.stop.load(Ordering::Relaxed) {
                    for _ in 0..BATCH {
                        if counter >= end {
                            search.hashed.fetch_add(BATCH, Ordering::Relaxed);
                            return;
                        }
                        job.write_nonce(&mut tail, counter);
                        let mut state = job.midstate;
                        job.algo.compress(&mut state, &tail);
                        if job.target.matches(&state) {
                            search.found(counter, "cpu");
                            return;
                        }
                        counter = counter.saturating_add(step);
                    }
                    search.hashed.fetch_add(BATCH, Ordering::Relaxed);
                }
            });
        }
    });
}
