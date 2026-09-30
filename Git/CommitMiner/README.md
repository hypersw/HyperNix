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
| `GIT_MINE=0` | Skip mining for one command, e.g. a long rebase. |

On any failure (timeout, missing miner, bad output) git warns and writes the
commit **without** a nonce. A commit is never lost to mining.

`git-mine-commit --benchmark [--backend cpu|gpu|all]` prints hash rates.
Measured on a 7950X3D in a 15-CPU container, iGPU only, 2-block commits:
CPU ~16 MH/s per thread, 190 MH/s on 15 threads; iGPU (2 CUs) ~170 MH/s.
Average wait at the default 7 threads plus the iGPU (~280 MH/s): 7 digits
about 1 s, 8 digits about 15 s. A discrete GPU does SHA-1 two orders of
magnitude faster.

## Miner protocol

git writes the whole object body, without the `commit <len>\0` header, to
stdin, with a 16-digit placeholder nonce in place, and passes:

    --algo sha1|sha256 --prefix <p> --offset=<nonce byte offset in body> --width=16 [--timeout <s>]

The miner prints the nonce digits and exits 0, or exits non-zero.
git re-hashes the result with its own code before accepting it.

## Limits

- **Signed commits are skipped** with a warning. The signature covers every
  header, so the nonce has to go inside the `gpgsig` value as a trailing
  continuation line. That is what git-facade and lucky-commit do; not done here yet.
- Repos with `compatObjectFormat` are skipped: both object names would have to match.
- The GPU kernel handles SHA-1 only, with at most 32 tail blocks; the tail is
  everything from the nonce to the end of the message, roughly 2 KiB. SHA-256
  repos and longer messages mine on the CPU.
- Each attempt re-hashes from the nonce to the end of the message, because
  the header sits before the message. That costs 2–8 blocks for typical
  messages, where a message-tail nonce such as lucky-commit's whitespace costs 1.
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
