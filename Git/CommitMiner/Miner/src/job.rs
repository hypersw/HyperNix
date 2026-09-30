//! The search problem, prepared once and shared by every backend.
//!
//! A commit's object name is `H("commit <len>\0" + body)`. The nonce sits at a
//! fixed offset with a fixed width, so the object length never changes and
//! every hash block before the nonce's block is identical across attempts.
//! Those blocks are compressed once into a midstate; an attempt then only
//! rewrites the nonce digits in a copy of the padded tail and compresses the
//! tail blocks.

use sha1::digest::generic_array::{typenum::U64, GenericArray};

pub type Block = GenericArray<u8, U64>;

pub const HEX: &[u8; 16] = b"0123456789abcdef";

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Algo {
    Sha1,
    Sha256,
}

impl Algo {
    pub fn parse(name: &str) -> Option<Algo> {
        match name {
            "sha1" => Some(Algo::Sha1),
            "sha256" => Some(Algo::Sha256),
            _ => None,
        }
    }

    /// Digest length in 32-bit big-endian words.
    pub fn words(self) -> usize {
        match self {
            Algo::Sha1 => 5,
            Algo::Sha256 => 8,
        }
    }

    pub fn iv(self) -> [u32; 8] {
        match self {
            Algo::Sha1 => [0x67452301, 0xefcdab89, 0x98badcfe, 0x10325476, 0xc3d2e1f0, 0, 0, 0],
            Algo::Sha256 => [
                0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
            ],
        }
    }

    /// Compresses whole blocks into `state`; SHA-1 uses only the first five words.
    #[inline(always)]
    pub fn compress(self, state: &mut [u32; 8], blocks: &[Block]) {
        match self {
            Algo::Sha1 => {
                let mut s = [state[0], state[1], state[2], state[3], state[4]];
                sha1::compress(&mut s, blocks);
                state[..5].copy_from_slice(&s);
            }
            Algo::Sha256 => sha2::compress256(state, blocks),
        }
    }
}

/// A hex prefix with `_` wildcards, as masks over the leading digest words.
#[derive(Clone, Debug)]
pub struct Target {
    pub mask: [u32; 8],
    pub value: [u32; 8],
    /// Number of leading words that carry any constraint.
    pub words: usize,
}

impl Target {
    pub fn parse(prefix: &str, algo: Algo) -> Result<Target, String> {
        if prefix.len() > algo.words() * 8 {
            return Err(format!("prefix '{prefix}' is longer than the digest"));
        }
        let mut target = Target { mask: [0; 8], value: [0; 8], words: 0 };
        for (i, c) in prefix.bytes().enumerate() {
            let shift = 28 - 4 * (i % 8) as u32;
            match c {
                b'_' => continue,
                b'0'..=b'9' | b'a'..=b'f' => {
                    let digit = (c as char).to_digit(16).unwrap();
                    target.mask[i / 8] |= 0xf << shift;
                    target.value[i / 8] |= digit << shift;
                    target.words = target.words.max(i / 8 + 1);
                }
                _ => return Err(format!("prefix '{prefix}' may hold only lowercase hex digits and '_'")),
            }
        }
        Ok(target)
    }

    #[inline(always)]
    pub fn matches(&self, state: &[u32; 8]) -> bool {
        (0..self.words).all(|i| state[i] & self.mask[i] == self.value[i])
    }

    /// Expected attempts until a hit: 16 to the power of the constrained digit count.
    pub fn expected_attempts(&self) -> f64 {
        let bits: u32 = self.mask.iter().map(|m| m.count_ones()).sum();
        2f64.powi(bits as i32)
    }
}

#[derive(Clone)]
pub struct Job {
    pub algo: Algo,
    pub target: Target,
    /// Hash state after every block that precedes the nonce's first block.
    pub midstate: [u32; 8],
    /// The remaining blocks, padded, with a placeholder nonce.
    pub tail: Vec<Block>,
    /// Byte offset of the nonce's first digit within `tail`.
    pub nonce_at: usize,
    pub width: usize,
}

impl Job {
    pub fn new(algo: Algo, target: Target, body: &[u8], offset: usize, width: usize) -> Result<Job, String> {
        if width == 0 || width > 16 {
            return Err(format!("nonce width {width} is outside 1..=16"));
        }
        if offset + width > body.len() {
            return Err(format!("nonce at {offset}+{width} runs past the {}-byte body", body.len()));
        }
        // The object header is part of the hashed stream but not of the body git sends.
        let mut stream = format!("commit {}\0", body.len()).into_bytes();
        let nonce_pos = stream.len() + offset;
        stream.extend_from_slice(body);
        let bit_len = (stream.len() as u64) * 8;

        let split = nonce_pos / 64 * 64;
        let mut midstate = algo.iv();
        let head: Vec<Block> = stream[..split].chunks(64).map(|c| Block::clone_from_slice(c)).collect();
        algo.compress(&mut midstate, &head);

        // Merkle-Damgard padding: 0x80, zeros, then the bit length in the last eight bytes.
        let mut tail = stream[split..].to_vec();
        tail.push(0x80);
        while tail.len() % 64 != 56 {
            tail.push(0);
        }
        tail.extend_from_slice(&bit_len.to_be_bytes());
        let tail = tail.chunks(64).map(|c| Block::clone_from_slice(c)).collect();

        Ok(Job { algo, target, midstate, tail, nonce_at: nonce_pos - split, width })
    }

    /// Size of the counter space a `width`-digit nonce can spell.
    pub fn space(&self) -> u128 {
        1u128 << (4 * self.width)
    }

    /// Writes `counter` as `width` hex digits into a tail copy, most significant first.
    #[inline(always)]
    pub fn write_nonce(&self, tail: &mut [Block], counter: u64) {
        for j in 0..self.width {
            let digit = (counter >> (4 * (self.width - 1 - j))) & 0xf;
            let at = self.nonce_at + j;
            tail[at / 64][at % 64] = HEX[digit as usize];
        }
    }

    pub fn format_nonce(&self, counter: u64) -> String {
        (0..self.width)
            .map(|j| HEX[((counter >> (4 * (self.width - 1 - j))) & 0xf) as usize] as char)
            .collect()
    }

    /// Hashes one attempt from scratch; the reference the backends are checked against.
    pub fn digest(&self, counter: u64) -> [u32; 8] {
        let mut tail = self.tail.clone();
        self.write_nonce(&mut tail, counter);
        let mut state = self.midstate;
        self.algo.compress(&mut state, &tail);
        state
    }

    pub fn digest_hex(&self, counter: u64) -> String {
        let state = self.digest(counter);
        state[..self.algo.words()].iter().map(|w| format!("{w:08x}")).collect()
    }
}
