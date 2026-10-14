# CommitMiner — vanity commit hashes, mined like proof-of-work

`git config mine.prefix 0000000` and every new commit gets an object name
starting with `0000000`. The message and all visible fields stay as written.
The varying part is one extra header in the raw commit object:

```
tree aaff74984cccd156a469afa7d9ab10e4777beb24
author T <t@e> 1790803790 +0200
committer T <t@e> 1790803790 +0200
nonce 00000000034daef1

first mined commit
```

## Pieces

| Path | What |
|---|---|
| `git-mine.patch` | Patch to git's `commit.c`. It covers `commit_tree_extended()`, which every commit-creating command goes through: commit, commit-tree, merge, am, and rebase/cherry-pick/revert. It adds the `nonce` header and runs the miner. |
| `git.nix` | The patched git: a separate derivation, **not** an overlay over `pkgs.git`, which would rebuild half of nixpkgs. |
| `Miner/` | `git-mine-commit`, a Rust miner. The CPU backend uses all SHA-NI threads. The GPU backend runs wgpu/Vulkan compute (SHA-1 only), and the two race on disjoint counter ranges. |
| `package.nix` | The two joined on one `bin/`. |

Flake outputs: `Git-CommitMiner` (use this one), `Git-CommitMiner-Git`, `Git-CommitMiner-Miner`.

## Use

```nix
# home-manager
programs.git.package = inputs.hypernix.packages.${system}.Git-CommitMiner;
programs.git.settings.mine.prefix = "0000000";
```

| Config / env | Meaning |
|---|---|
| `mine.prefix` | Lowercase hex, `_` matches any digit. Unset or empty means off, and the patched git then behaves like stock git. |
| `mine.program` | Miner command, run through the shell so it may carry options. Default `git-mine-commit` on `PATH`. For example `git-mine-commit --backend cpu --threads 4`. |
| `mine.timeout` | Seconds before the miner gives up. The miner's own default is 60. |
| `mine.fallbackPrefix` | What the miner settles for once half the timeout has passed without a full match. Default: `mine.prefix` minus its last digit, which matches 16× more often. Empty means no fallback. |
| `GIT_MINE=0` | Skip mining for one command, e.g. a long rebase. |

On any failure (timeout, missing miner, bad output) git warns and writes the
commit **without** a nonce. A commit is never lost to mining.

`git-mine-commit --benchmark [--backend cpu|gpu|all]` prints hash rates.
The rate is set by hash blocks per attempt, and the benchmark uses a 2-block commit.
Real messages are longer: a 1.2 KB message costs about 19 blocks, and 3.7 KB about 59.
Measured on a 7950X3D in a 15-CPU container with only the iGPU (2 CUs):

| | Blocks/s | 2-block commit | 1.2 KB message |
|---|---|---|---|
| CPU, default 7 threads | ~260 M | ~105 MH/s | ~14 MH/s |
| iGPU | ~430 M | ~160 MH/s | ~22 MH/s |

A 7-digit prefix takes about 2.7e8 attempts on average.
With both backends that is about 1 s for a 2-block commit, 8 s for a 1.2 KB message and 23 s for 3.7 KB.
A discrete GPU does SHA-1 two orders of magnitude faster.

## Miner protocol

git writes the whole object body, without the `commit <len>\0` header, to
stdin, with a 16-digit placeholder nonce in place, and passes:

    --algo sha1|sha256 --prefix <p> --offset=<nonce byte offset in body> --width=16 [--timeout <s>] [--fallback <p>]

The miner prints the nonce digits and exits 0, or exits non-zero.
git re-hashes the result with its own code before accepting it,
and accepts a match on either the prefix or the fallback.

The miner keeps the first fallback match it meets in reserve. It returns that
match at `--fallback-after` seconds (half the timeout by default), or as soon
as one turns up after that point. A full match returns immediately at any time.

## Limits

- **Signed commits are skipped** with a warning. The signature covers every
  header, so the nonce has to go inside the `gpgsig` value as a trailing
  continuation line. That is what git-facade and lucky-commit do; not done here yet.
- Repos with `compatObjectFormat` are skipped: both object names would have to match.
- The GPU kernel handles SHA-1 only; SHA-256 repos mine on the CPU.
- Each attempt re-hashes from the nonce to the end of the message, because
  the header sits before the message. That costs one block per 64 bytes of
  message, where a message-tail nonce such as lucky-commit's whitespace costs 1–2 blocks.
- The GPU kernel is the same for every commit and takes the commit as data.
  Its first compile is cached by the driver (Mesa keeps it in ~/.cache/mesa_shader_cache),
  so GPU setup takes about 150 ms.
- The GPU loads the host's Vulkan driver into the miner process. A miner built
  from an older nixpkgs than the host's Mesa fails to load it, with `GLIBC_2.44 not found` for example.
  It then mines on the CPU without saying so; `--verbose` shows the error.
  Build it from the same nixpkgs as the system, as home-manager does.
- A shared prefix on every commit makes 7-digit short hashes useless.
  git lengthens abbreviations on its own, but `--oneline` becomes a wall of zeros.
  Prefer a short tag such as `c0ffee`, or a pattern like `_______0`.
- Other tools keep the header when they rewrite the commit (`--amend` copies
  extra headers). Only the patched git re-mines, and it replaces the old nonce.
- `git fsck --strict` accepts the header.
- Stash and notes commits are mined too, since they go through the same path.

## Prior art

git-facade (wgpu, `facadesalt` header), gitc0ffee, lucky-commit (OpenCL,
whitespace), bradfitz/gitbrute (timestamps). None of them hooks into git
itself; they rewrite HEAD after the fact.
