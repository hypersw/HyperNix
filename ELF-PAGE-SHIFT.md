# ELF page-shift surgery for 16 KiB-page kernels

> Forensic write-up of how the Epson V330 scanner came back to life on
> GhostHome (Raspberry Pi 5, nvmd's vendor kernel) and the reusable
> ELF-shifter package that fell out of it.
>
> Lives at [Modules/PrintersScanners/ElfPageShift](Modules/PrintersScanners/ElfPageShift/),
> consumed by [Modules/PrintersScanners/EpkowaScanner](Modules/PrintersScanners/EpkowaScanner/default.nix).
> Intended to be extracted to its own flake later — the package
> directory is structured so the move is mechanical.

## The setup

GhostHome is a Raspberry Pi 5 running NixOS via nvmd's `nixos-raspberrypi`
fork. That fork ships **only** a vendor 16 KiB-page kernel
(`CONFIG_PAGE_SHIFT=14`). The mainline 4 KiB-page kernel is not packaged,
and rolling our own from source would take ~3 hours per rebuild with no
cache hits — operationally painful for incremental changes.

We want to scan from the Epson Perfection V33/V330 over USB. The SANE
backend is `epkowa` — Epson's proprietary backend wrapping their
proprietary `libesci-interpreter-perfection-v330.so` plugin. The plugin
is x86_64-only, so we already had an [`EpkowaStubX64`](Modules/PrintersScanners/EpkowaStubX64/)
shim running under qemu-user with [Unix-socket IPC](Modules/PrintersScanners/EpkowaStubX64/PROTOCOL.md)
back to the native aarch64 SANE process. That part has worked since
the Pi 4 days.

Then the Pi 5 + 16K kernel happened, and `dlopen` started failing:

```
error while loading shared libraries:
…libesci-interpreter-perfection-v330.so.0…:
failed to map segment from shared object
```

## Diagnosis

`readelf -l` on the proprietary blob shows two PT_LOAD segments:

```
Type        Offset    VirtAddr   FileSiz   Flg Align
LOAD        0x000000  0x000000   0x049f10  R E 0x1000
LOAD        0x04a000  0x24a000   0x000dd8  RW  0x1000
```

`p_align = 0x1000` says "4 KiB pages assumed". `p_offset = 0x4a000` is
divisible by 4 KiB but **not** by 16 KiB. `mmap(2)` requires the
offset argument to be a multiple of the host page size, and Linux's
ELF loader enforces this. Hence the failure.

`readelf -h` on the kernel package confirmed `CONFIG_PAGE_SHIFT=14`
(2^14 = 16384 = 16 KiB), and `getconf PAGESIZE` agreed.

### Paths considered and rejected

| Path | Why not |
|------|---------|
| Custom 4K kernel build | ~3 h per rebuild, no binary cache available from nvmd or upstream |
| Mainline aarch64 kernel | Pi 5 boot path is non-trivial via the Pi vendor firmware; SD-card boot reliability concerns |
| muvm / FEX-Emu microVM | Heavy, would require running scanning inside a separate microVM with USB pass-through |
| Box64 instead of qemu-user | Same 4K-page assumption in the loader; box64 doesn't paper over kernel page size |
| Alternative SANE backend | `genesys`/`epson2` lack the proprietary calibration tables; output is mis-coloured / unusable |
| `patchelf --page-size 16384` | Only rewrites `p_align` — the actual segment offset is unchanged, mmap still fails |
| Android's 16KB-compat tools | Same problem — they trust the linker to have placed segments correctly, not true for older / proprietary blobs |

### The plan

Rewrite the ELF in place: shift all VAs and all referencing metadata so
that segment file offsets land on 16 KiB boundaries.

The non-obvious choice: shift **both** PT_LOAD segments by the **same**
delta, not just the misaligned one. The reason is PIC x86_64 code.

```asm
  ; in seg 1 (R+E), referencing data in seg 2 (R+W)
  mov rax, [rip + 0x23ad82]   ; disp32 = (target_vaddr - next_insn_vaddr)
```

`disp32` is computed at link time as `target_vaddr - next_insn_vaddr`
and baked into the instruction encoding. There is no relocation
covering it. If seg 2 moves but seg 1 stays, every such instruction is
silently broken — there are thousands of them in a typical interpreter
plugin, and no symbol table tells you which.

If both segments shift by the same delta, the difference stays constant
and every RIP-relative reference still resolves correctly. The only
fixups needed are on **absolute** addresses, all of which are listed
in well-defined ELF metadata tables.

### How to shift segment 1

We can't insert padding before the ELF header at file offset 0 (its
position is mandatory). We insert padding **after** the ELF header, at
file offset 0x40 (sizeof(Elf64_Ehdr)):

```
BEFORE:                       AFTER:
+--- offset 0 ---+            +--- offset 0     ---+
|  ELF header    |            |  ELF header (updated e_phoff/e_shoff/e_entry)
+--- offset 0x40-+            +--- offset 0x40  ---+
|  PHDR          |            |  0x00 …             |
|                |            |     padding         |
|                |            |     (=shift bytes)  |
+--- offset 0x190+            +--- offset shift+0x40+
|  segment 1     |            |  PHDR               |
|  content       |            +--- offset shift+0x190
|                |            |  segment 1 content  |
|                |            |  (unchanged bytes,  |
…                              …  shifted location)
```

PT_LOAD#1's `p_offset` becomes `shift`, its `p_vaddr` becomes `shift`
— congruent mod page_size, which is the `mmap(2)` invariant. The kernel
aligns both down to the page boundary internally; the resulting mapping
covers the (now zeroed-out) ELF-header region of memory, then the PHDR
at its new location, then the segment content as expected.

PHDR moves to file offset `shift + 0x40`, which is INSIDE PT_LOAD#1's
new file range `[shift, shift + filesz_1]`. The kernel's AT_PHDR
calculation `load_addr + p_vaddr + (e_phoff - p_offset)` therefore
yields the correct runtime PHDR address. `ld.so` finds the PHDR and
proceeds normally.

## The bugs, in the order they were uncovered

Each line below was a separate SIGSEGV / SIGILL. Each took ~30 minutes
of `qemu -d in_asm` + `LD_DEBUG=all` to localize before the next layer
emerged from the wreckage. The list is the most useful artifact in
this doc; if you ever touch ELF surgery again, work through it
deliberately.

| # | Layer | What goes wrong if you miss it |
|---|-------|-------------------------------|
| 1 | `e_entry` (ELF header, byte 24) | `ld.so prog.so` jumps to `l_addr + old_e_entry`, which is now inside `.rela.plt`. SIGILL on the first random opcode. (Irrelevant for pure `dlopen`, critical for `ld.so prog.so` invocation; glibc may take that path internally.) |
| 2 | `e_phoff` (byte 32) | Wrong PHDR location → kernel/dl can't find program headers → mmap garbage. |
| 3 | `e_shoff` (byte 40) | Cosmetic at runtime (only used by `readelf`/`objdump`/debuggers), but a stale value confuses everything inspecting the file. Always shift. |
| 4 | All program headers | `p_offset`, `p_vaddr`, `p_paddr` for every entry. **Skip PT_GNU_STACK** — it has `p_offset = p_vaddr = 0` and just carries the W^X stack flags; shifting those zeros mints a bogus mapping header. |
| 5 | All section headers | `sh_addr` (if non-zero) and `sh_offset` (if non-zero). The NULL section at index 0 has both zero; leave it. |
| 6 | All symbol-table entries | `st_value` for every symbol with `st_value > 0`. UND symbols (`st_value = 0`, e.g. external `__cxa_atexit`) stay zero — the dynamic linker fills them in at load time. |
| 7 | All relocations: `r_offset` | Every reloc's target address shifts. |
| 8 | Relocations: `r_addend` (ONLY for `R_X86_64_RELATIVE`) | **This was bug-fix #2.** Symbol-bearing reloc types (`R_X86_64_64`, `R_X86_64_GLOB_DAT`, `R_X86_64_JUMP_SLOT`) have `r_addend` = "fixed delta added to the symbol's value", which is a struct-member offset, NOT a standalone VA. Shifting them silently corrupts struct-field access. The cxxabi class_type_info reloc with addend `0x10` (vtable member) would become `0x2010`, dereferencing into garbage on first virtual call. **Only RELATIVE has no symbol → addend IS the VA → shift only those.** |
| 9 | Dynamic section `d_un` for VA-tagged entries | DT_PLTGOT (3), DT_HASH (4), DT_STRTAB (5), DT_SYMTAB (6), DT_RELA (7), DT_INIT (12), DT_FINI (13), DT_JMPREL (23), DT_INIT_ARRAY (25), DT_FINI_ARRAY (26), DT_PREINIT_ARRAY (32), DT_GNU_HASH (0x6ffffef5), DT_VERSYM (0x6ffffff0), DT_VERNEED (0x6ffffffe), DT_VERDEF (0x6ffffffc). Every other DT_* tag holds a size/count/string-index/offset and must be left alone. |
| 10 | **`.got.plt[3..N]` — the killer** | `.got.plt[0]` holds `&DT_DYNAMIC` (linker-baked, easy to remember to shift). `.got.plt[1]` and `[2]` are dl-managed (link_map and resolver) — leave alone. The non-obvious part: `.got.plt[3..N]` hold **link-time-baked `PLT[i] + 6` addresses** used by lazy PLT binding. The dynamic linker does NOT touch them until the first call to each PLT entry — it just lets the existing value drive control back into the PLT to invoke `_dl_runtime_resolve`. If the PLT moved by `+shift` but these slots didn't, every first PLT call jumps to where the PLT used to be (now inside `.rela.plt` junk). SIGSEGV with a PC at the pre-shift PLT location — almost impossible to localize without manual binary dumps. |

The chronological journey through these:

```
v1  Shifted only PT_LOAD#2.
    → SIGSEGV in _init. Broke RIP-relative addressing between segs.

v2  Shift both segs equally + insert padding at file offset 0x40.
    → SIGSEGV. Wrong addend handling for symbol-bearing relocs.

v2b Restrict r_addend shift to R_X86_64_RELATIVE only.
    → SIGILL — jumped into .rela.plt bytes. e_entry not updated.

v2c Also shift e_entry.
    → SIGSEGV — first PLT call jumped to pre-shift PLT location.
       .got.plt[3..N] lazy-binding stubs not updated.

v2d Also shift every .got.plt[N] for N >= 3.
    → Scanner produces a valid PNM. ✓
```

## The architecture in this flake

```
Modules/PrintersScanners/
├── ElfPageShift/                ← the reusable package & lib
│   ├── elf-page-shift.py        ← the tool itself
│   ├── package.nix              ← `elf-page-shift` executable derivation
│   └── lib.nix                  ← exposes pageShiftElfBundle helper
│
├── EpkowaScanner/               ← scanner module, consumer
│   └── default.nix              ← maps pkgsX86.epkowa.plugins.* through
│                                  pageShiftElfBundle before joining into
│                                  the stub's LD_LIBRARY_PATH
│
└── EpkowaStubX64/               ← the x86_64 IPC shim (unchanged)
```

`ElfPageShift/lib.nix` is structured so that lifting the directory into
its own flake later is mechanical: it takes `pkgs` as its only input,
exposes `{ elf-page-shift, pageShiftElfBundle }`, and has no
HyperNix-specific dependencies.

### Usage from another module

```nix
let
  pageShift = import ../ElfPageShift/lib.nix { inherit pkgs; };
in
  someDerivationProducingSos = pageShift.pageShiftElfBundle {
    src = someUpstreamPackage;
    # `name` is optional; defaults to "${src.name}-pageshifted"
  };
```

The helper:

- copies the source bundle tree verbatim,
- finds every regular `*.so` / `*.so.*` file (symlinks are preserved
  as-is and re-resolve correctly to the now-shifted regular file),
- runs `elf-page-shift INPUT TMP && mv TMP INPUT` on each one,
- exposes the unshifted original via `.passthru.unshifted`.

It is idempotent: if a `.so` is already 16K-aligned, the tool
byte-copies it through. Safe to apply unconditionally, including on
hosts whose page size is already 4 KiB — the shifted output is
backwards-compatible (16K-aligned ⇒ 4K-aligned).

### Direct tool use

```bash
nix run .#elf-page-shift -- input.so output.so   # once exposed in flake.nix
# or
nix-shell -p python3Packages.pyelftools \
  --run "python3 Modules/PrintersScanners/ElfPageShift/elf-page-shift.py in.so out.so"
```

## Scope and limitations

- **ELF64, x86_64 only.** The relocation-type table is hard-coded for
  x86_64. ELF32 and aarch64 work by the same algorithm but with
  different field sizes and reloc semantics — implementation effort is
  mechanical, not theoretical.
- **Assumes a single misaligned PT_LOAD pair** with a shared shift
  delta. ELFs with three+ load segments at arbitrary misaligned offsets
  would need a more sophisticated shift policy (e.g. multiple pad
  insertions at different offsets). Not in scope for the iscan use
  case.
- **No support for `DT_GNU_RELA`** style packed relocations or for
  `DT_RELR` (Android compact relocations). Add when needed.
- **Doesn't update `.eh_frame_hdr` content,** which contains its own
  pcrel pointers. Those happen to use FDE-encoded pcrel deltas that
  are preserved by shift-both, so it works out for the iscan blob.
  An ELF using DW_EH_PE_absptr encoding would need additional work.

## Related reading

- glibc `elf/dl-load.c` — `_dl_map_object_from_fd` is the canonical
  reference for what the dynamic linker reads from the ELF.
- System V ABI x86_64 supplement § "Procedure Linkage Table" — the
  authoritative description of `.got.plt`'s layout and the lazy PLT
  binding sequence.
- [glibc — How programs get run: ELF binaries](https://lwn.net/Articles/631631/)
  — LWN's high-level walk-through of the same.
- [Android Developer Documentation — 16 KB page sizes](https://developer.android.com/guide/practices/page-sizes)
  — the only mainstream platform shipping 16K-page user-space, useful
  context but their tooling stops at `p_align`.

## Co-authored-by

Co-authored-by: Claude <noreply@anthropic.com>
