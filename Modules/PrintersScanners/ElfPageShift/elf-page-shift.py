#!/usr/bin/env python3
"""
elf-page-shift — re-align an ELF64 shared object's PT_LOAD segments
to a larger page size by shifting all VAs (and all the absolute-address
metadata that references them) by the same delta.

Use case
========
A `.so` linked with `-z max-page-size=4096` (or no flag at all on
older toolchains) places its second PT_LOAD's p_offset on a 4 KiB
boundary that isn't necessarily a 16 KiB boundary. On a host kernel
configured with `CONFIG_PAGE_SHIFT=14` (16 KiB pages — Raspberry Pi 5
vendor kernel, Asahi Linux on Apple Silicon, etc.) the loader fails:

    error while loading shared libraries: …libfoo.so…:
    failed to map segment from shared object

because `mmap(2)` requires its `offset` argument to be page-aligned.

There is no public tool that re-pages a closed-source ELF .so. The
Android 16KB-compat tools (e.g. `android-16kb-fix`, `patchelf
--page-size`) only rewrite the `p_align` header field; they assume
the linker placed segments at 16K-aligned offsets and just declared
the wrong alignment in the header — true for NDK r28+, NOT true for
older / proprietary blobs.

Approach: shift BOTH PT_LOAD segments by the same delta
========================================================
Strategy: pad the file just after the ELF header so that everything
following shifts up by `delta` bytes. Set every VA in the binary
(symbols, relocations, dynamic section entries, .got.plt slots, the
ELF entry point) to its new shifted value. PT_LOAD#1's p_vaddr and
p_offset both become `delta` — congruent mod page_size — and PT_LOAD#2
inherits its same +delta shift in lockstep.

Crucially: shifting BOTH segments by the SAME delta preserves the
inter-segment distance the linker emitted. RIP-relative addressing
in PIC x86_64 code (`mov rax, [rip + disp32]`) bakes that distance
directly into the instruction encoding — there is no relocation
table covering it — so shifting both segments equally is the only
way to avoid disassembling every instruction.

The trick is HOW to shift seg 1 in the file. We can't pad before the
ELF header at file offset 0 (its position is mandatory). We pad
immediately AFTER the ELF header (at file offset 0x40 in ELF64),
pushing the PHDR table and seg 1's content down by `delta`. That
makes PT_LOAD#1's p_offset = delta — congruent mod page_size with
its new p_vaddr = delta. The kernel's mmap aligns both down to the
page boundary internally; the resulting mapping covers the ELF-header
region of memory with zeros, then the PHDR, then the segment content
as expected.

PHDR moves to file offset delta + 0x40, which is INSIDE PT_LOAD#1's
new file range [delta, delta + filesz_1]. The kernel's AT_PHDR
calculation (`load_addr + p_vaddr + (e_phoff - p_offset)`) therefore
yields the correct runtime PHDR address. ld.so finds the PHDR and
proceeds normally.

What gets updated
=================
EVERY absolute address in the file is shifted by `delta`:

  - ELF header: e_entry, e_phoff, e_shoff
  - All PHDR entries: p_offset, p_vaddr, p_paddr
                      (skip PT_GNU_STACK — pure flags, no mapping)
  - All section headers: sh_addr (if non-zero), sh_offset (if non-zero)
  - All symbol table entries: st_value (if non-zero)
  - All relocations: r_offset always; r_addend ONLY for
                     R_X86_64_RELATIVE (other reloc types' addends
                     are struct-member offsets, not VAs)
  - Dynamic section entries with VA d_un: DT_PLTGOT, DT_HASH,
    DT_STRTAB, DT_SYMTAB, DT_RELA, DT_INIT, DT_FINI, DT_JMPREL,
    DT_INIT_ARRAY, DT_FINI_ARRAY, DT_PREINIT_ARRAY, DT_GNU_HASH,
    DT_VERSYM, DT_VERNEED, DT_VERDEF
  - .got.plt slots: ALL except indices [1] and [2] (which the
    dynamic linker fills in at load time). The link-time-baked
    PLT-trampoline pointers in [3..N] would otherwise still point
    at the pre-shift PLT location and SIGSEGV on the first lazy
    PLT call.

The discovery of that last item (lazy-binding stubs in .got.plt[3..])
was the most painful debugging episode in writing this tool — the
.so loads cleanly, runs its constructors, and crashes only on the
first external function call.

Idempotence
===========
If the input is already aligned for the target page size, the tool
copies the input to the output byte-for-byte. The output is always
written, so this is safe to use as a build step in a Nix derivation
that unconditionally page-shifts every .so it finds.

Universality
============
A 16K-aligned segment is also 4K-aligned (16K = 4 × 4K). The shifted
output therefore loads cleanly on BOTH 4K-page and 16K-page kernels.
No conditional dispatch is needed at the build / deploy layer; the
shifted blob is a drop-in replacement.

Scope
=====
ELF64, x86_64 only. Adding x86 (ELF32) or aarch64 support is mostly
mechanical (different header sizes, different relocation type codes
and addend semantics). Patches welcome if you have a use case.

Usage
=====
    elf-page-shift <input.so> <output.so>

Requires `pyelftools` for the read-side structural parse. All writes
are manual `struct.pack` into a bytearray — pyelftools' write side
isn't comprehensive enough to cover everything we need to update.
"""

import struct
import sys
import io

try:
    from elftools.elf.elffile import ELFFile
    from elftools.elf.sections import SymbolTableSection
    from elftools.elf.relocation import RelocationSection
except ImportError:
    print("error: pyelftools not installed. "
          "Try: nix-shell -p python3Packages.pyelftools --run "
          "'python3 elf-page-shift.py ...'", file=sys.stderr)
    sys.exit(1)


PAGE = 0x4000  # 16 KiB target page size.

# Where in the file we insert the padding. Immediately after the ELF
# header (which must remain at file offset 0). All bytes from this
# offset onwards in the original file move to (original_offset + shift)
# in the new file.
PADDING_AT = 0x40  # sizeof(Elf64_Ehdr)


# x86_64 relocation type constants. Match elf.h.
R_X86_64_64         = 1
R_X86_64_GLOB_DAT   = 6
R_X86_64_JUMP_SLOT  = 7
R_X86_64_RELATIVE   = 8

# Relocation types whose r_addend is itself a VA that may need
# shifting. For symbol-bearing relocs (R_X86_64_64, R_X86_64_GLOB_DAT,
# R_X86_64_JUMP_SLOT), the addend is the "fixed delta added to the
# symbol's value" — typically a struct-member offset, NOT a standalone
# VA. Shifting them would corrupt struct-field access (e.g. the
# cxxabi class_type_info vtable's `+0x10` member-offset addend would
# become `+0x2010`, dereferencing into garbage).
# Only R_X86_64_RELATIVE has no symbol — its addend IS the absolute
# target VA, and that's the only one we should shift.
ADDEND_IS_VA = {R_X86_64_RELATIVE}

# Dynamic section tags whose d_un is a VA (and therefore needs shift).
# Tags NOT in this set hold sizes/counts/strings/offsets and are left
# alone. Reference: elf.h DT_* names.
DT_VA_TAGS = {
    3,           # DT_PLTGOT
    4,           # DT_HASH
    5,           # DT_STRTAB     (string table — VA)
    6,           # DT_SYMTAB
    7,           # DT_RELA
    12,          # DT_INIT
    13,          # DT_FINI
    23,          # DT_JMPREL
    25,          # DT_INIT_ARRAY
    26,          # DT_FINI_ARRAY
    32,          # DT_PREINIT_ARRAY
    0x6ffffef5,  # DT_GNU_HASH
    0x6ffffff0,  # DT_VERSYM
    0x6ffffffe,  # DT_VERNEED
    0x6ffffffc,  # DT_VERDEF
}

# Program-header types where p_offset/p_vaddr ARE meaningful (i.e.
# refer to a file/memory region). PT_GNU_STACK has p_offset=0,
# p_vaddr=0 and only carries the W^X stack flags; shifting them would
# produce a bogus PT_GNU_STACK header.
PT_GNU_STACK_TYPE = 0x6474e551


def get64(buf, off):
    return struct.unpack_from('<Q', buf, off)[0]

def set64(buf, off, val):
    struct.pack_into('<Q', buf, off, val & 0xFFFFFFFFFFFFFFFF)

def get_s64(buf, off):
    return struct.unpack_from('<q', buf, off)[0]

def set_s64(buf, off, val):
    struct.pack_into('<q', buf, off, val)


def shift_elf(input_path, output_path):
    with open(input_path, 'rb') as f:
        data = bytearray(f.read())

    # Snapshot for the parser so subsequent in-place edits don't trip
    # pyelftools (it caches header reads).
    elf = ELFFile(io.BytesIO(bytes(data)))

    if elf.elfclass != 64:
        raise SystemExit("only ELF64 supported")

    # Find the first PT_LOAD whose file offset is not aligned to the
    # target page, to derive the shift amount.
    misaligned = None
    for seg in elf.iter_segments():
        if seg['p_type'] != 'PT_LOAD':
            continue
        if seg['p_offset'] % PAGE != 0:
            misaligned = seg
            break

    if misaligned is None:
        # Already aligned for the target page size — copy through
        # unchanged so callers (e.g. Nix derivations) get a uniform
        # input/output contract. The output is byte-identical to the
        # input in this case.
        print(f"{input_path}: already {PAGE:#x}-aligned; passing through")
        with open(output_path, 'wb') as f:
            f.write(bytes(data))
        return

    shift = PAGE - (misaligned['p_offset'] % PAGE)
    print(f"{input_path}: misaligned PT_LOAD at file_offset="
          f"{misaligned['p_offset']:#x} (vaddr={misaligned['p_vaddr']:#x})")
    print(f"  shift = {shift:#x}; everything from file offset "
          f"{PADDING_AT:#x} onwards moves by +{shift:#x}; every VA in "
          f"the binary increases by +{shift:#x}")

    # ── 1. ELF header: e_entry, e_phoff, e_shoff all shift ─────────
    # e_entry (byte 24) is a VA, e_phoff (byte 32) and e_shoff
    # (byte 40) are file offsets — all increase by the same shift.
    #
    # NB: For .so loaded via dlopen, e_entry is unused. But when the
    # dynamic linker is asked to run the .so directly (`ld.so foo.so`,
    # which some glibc versions reach via dlopen+symbol-lookup),
    # an unshifted e_entry sends control to `l_addr + old_entry`
    # which now points INSIDE .rela.plt — random relocation bytes
    # interpreted as code, hitting SIGILL on the first invalid
    # opcode. Always shift e_entry to be safe.
    e_entry_orig = elf.header['e_entry']
    e_phoff_orig = elf.header['e_phoff']
    e_shoff_orig = elf.header['e_shoff']
    if e_entry_orig != 0:
        set64(data, 24, e_entry_orig + shift)
    set64(data, 32, e_phoff_orig + shift)
    set64(data, 40, e_shoff_orig + shift)
    print(f"  e_entry: {e_entry_orig:#x} -> "
          f"{e_entry_orig + shift if e_entry_orig else 0:#x}")

    # ── 2. Program headers: shift every entry's offset/vaddr/paddr ─
    # Skip PT_GNU_STACK which has p_offset=p_vaddr=0 and just carries
    # the stack-exec flags — shifting those zeros would mint a fake
    # mapping. All other entries (PT_LOAD, PT_DYNAMIC, PT_NOTE,
    # PT_GNU_EH_FRAME, and a hypothetical PT_PHDR) get the same
    # +shift in both file offset and vaddr.
    e_phentsize = elf.header['e_phentsize']
    e_phnum = elf.header['e_phnum']
    n_phdr_shifted = 0
    for i in range(e_phnum):
        ph_off = e_phoff_orig + i * e_phentsize
        p_type = struct.unpack_from('<I', data, ph_off)[0]
        if p_type == PT_GNU_STACK_TYPE:
            continue
        p_offset = get64(data, ph_off + 8)
        p_vaddr  = get64(data, ph_off + 16)
        p_paddr  = get64(data, ph_off + 24)
        set64(data, ph_off + 8,  p_offset + shift)
        set64(data, ph_off + 16, p_vaddr  + shift)
        set64(data, ph_off + 24, p_paddr  + shift)
        n_phdr_shifted += 1
    print(f"  phdrs shifted: {n_phdr_shifted}")

    # ── 3. Section headers ────────────────────────────────────────
    # Non-zero sh_addr → shift (sections with no VA, like .shstrtab,
    # have sh_addr == 0). Non-zero sh_offset → shift (the NULL section
    # at index 0 has sh_offset == 0).
    e_shentsize = elf.header['e_shentsize']
    e_shnum = elf.header['e_shnum']
    n_shdr_shifted = 0
    for i in range(e_shnum):
        sh_off = e_shoff_orig + i * e_shentsize
        sh_addr   = get64(data, sh_off + 16)
        sh_offset = get64(data, sh_off + 24)
        touched = False
        if sh_addr != 0:
            set64(data, sh_off + 16, sh_addr + shift)
            touched = True
        if sh_offset != 0:
            set64(data, sh_off + 24, sh_offset + shift)
            touched = True
        if touched:
            n_shdr_shifted += 1
    print(f"  shdrs shifted: {n_shdr_shifted}")

    # ── 4. Symbol tables (.dynsym + .symtab if present) ────────────
    n_syms_shifted = 0
    for section in elf.iter_sections():
        if not isinstance(section, SymbolTableSection):
            continue
        sym_offset = section['sh_offset']
        sym_entsize = section['sh_entsize']
        for j in range(section.num_symbols()):
            entry_off = sym_offset + j * sym_entsize
            st_value = get64(data, entry_off + 8)
            if st_value != 0:
                set64(data, entry_off + 8, st_value + shift)
                n_syms_shifted += 1
    print(f"  symbols shifted: {n_syms_shifted}")

    # ── 5/6. Relocation tables (RELA: .rela.dyn + .rela.plt) ───────
    n_relocs_off_shifted = 0
    n_relocs_add_shifted = 0
    for section in elf.iter_sections():
        if not isinstance(section, RelocationSection):
            continue
        if not section.is_RELA():
            continue
        rela_offset = section['sh_offset']
        rela_entsize = section['sh_entsize']
        for j in range(section.num_relocations()):
            entry_off = rela_offset + j * rela_entsize
            r_offset = get64(data, entry_off + 0)
            r_info   = get64(data, entry_off + 8)
            r_addend = get_s64(data, entry_off + 16)
            r_type = r_info & 0xFFFFFFFF
            if r_offset != 0:
                set64(data, entry_off + 0, r_offset + shift)
                n_relocs_off_shifted += 1
            if r_type in ADDEND_IS_VA and r_addend != 0:
                set_s64(data, entry_off + 16, r_addend + shift)
                n_relocs_add_shifted += 1
    print(f"  reloc r_offsets shifted: {n_relocs_off_shifted}")
    print(f"  reloc r_addends shifted: {n_relocs_add_shifted}")

    # ── 7. Dynamic section ─────────────────────────────────────────
    n_dyn_shifted = 0
    for seg in elf.iter_segments():
        if seg['p_type'] != 'PT_DYNAMIC':
            continue
        dyn_offset = seg['p_offset']  # ORIGINAL offset (pre-splice)
        dyn_size = seg['p_filesz']
        for j in range(dyn_size // 16):
            entry_off = dyn_offset + j * 16
            d_tag = get64(data, entry_off + 0)
            d_un  = get64(data, entry_off + 8)
            if d_tag in DT_VA_TAGS and d_un != 0:
                set64(data, entry_off + 8, d_un + shift)
                n_dyn_shifted += 1
        break
    print(f"  dynamic entries shifted: {n_dyn_shifted}")

    # ── 8. .got.plt entries ───────────────────────────────────────
    # .got.plt layout (System V ABI, x86_64):
    #   [0] -> vaddr of DT_DYNAMIC (linker-baked, dl reads at startup)
    #   [1] -> link_map* of this object (dl writes at load time)
    #   [2] -> _dl_runtime_resolve (dl writes at load time)
    #   [3..N] -> for lazy PLT binding: each entry holds the address
    #             of `PLT[i] + 6` (the `push reloc_index` instruction
    #             just AFTER the `jmp *got` at the start of each PLT
    #             stub). On first call, the entry resolves to this
    #             address, walks back into PLT[i] to push the reloc
    #             index, then jumps to PLT[0] -> dl_runtime_resolve.
    #             After the dl resolves, it OVERWRITES this slot with
    #             the actual function address.
    #
    # The CRITICAL insight: the dl does NOT touch slots [3..N] until
    # the program actually calls the corresponding PLT entry. Until
    # then they hold their LINK-TIME values pointing at PLT[i]+6.
    # Those values are absolute VAs in the .so's address space, and
    # they ALL need to shift by +shift along with the PLT itself.
    #
    # Without this fix, every first PLT call jumps to the PRE-shift
    # PLT location (now inside .rela.plt junk) and SIGSEGV's there.
    # Symptom: crash trace shows execution at low VAs corresponding
    # to where the PLT used to live before we shifted it.
    n_gotplt_shifted = 0
    for section in elf.iter_sections():
        if section.name == '.got.plt':
            gotplt_offset = section['sh_offset']
            gotplt_size = section['sh_size']
            n_entries = gotplt_size // 8
            for idx in range(n_entries):
                # Skip [1] and [2] — dl-managed slots, link-time zero.
                if idx in (1, 2):
                    continue
                slot_off = gotplt_offset + idx * 8
                v = get64(data, slot_off)
                if v != 0:
                    set64(data, slot_off, v + shift)
                    n_gotplt_shifted += 1
            break
    print(f"  .got.plt entries shifted: {n_gotplt_shifted}")

    # ── Splice: insert `shift` zero bytes at file offset PADDING_AT ─
    new_data = (
        bytes(data[:PADDING_AT]) +
        b'\x00' * shift +
        bytes(data[PADDING_AT:])
    )
    with open(output_path, 'wb') as f:
        f.write(new_data)
    print(f"  wrote {output_path}: {len(new_data)} bytes "
          f"(orig {len(data)}, +{shift} pad inserted at offset "
          f"{PADDING_AT:#x})")


def main():
    if len(sys.argv) != 3:
        print("usage: elf-page-shift <input.so> <output.so>",
              file=sys.stderr)
        sys.exit(1)
    shift_elf(sys.argv[1], sys.argv[2])


if __name__ == '__main__':
    main()
