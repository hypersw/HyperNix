#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
  Binary-patch the Looking Glass server (host) executable so it stops
  rejecting the WARP / "Microsoft Basic Render Driver" adapter, letting
  LG capture from a Windows guest that has no real or passed-through GPU.

.DESCRIPTION
  LG's capture backends (D12 and DXGI) enumerate DXGI adapters and refuse
  a hardcoded set of "unsupported" virtual adapters. The refusal is NOT a
  string comparison against "Microsoft Basic Render Driver" -- that phrase
  exists in LG's source only as a // comment and is never compiled into the
  binary. The actual test is a numeric PCI ID match:

      // Microsoft Basic Render Driver
      adapterDesc.VendorId == 0x1414 && adapterDesc.DeviceId == 0x008c

  When it matches the live adapter, LG logs
  "Not using unsupported adapter: %ls" and skips it.

  In LG version B7 (a MinGW/GCC build) this compiles to three sites, all
  keyed on the Microsoft PCI VendorId 0x1414 (the 4-byte little-endian
  immediate `14 14 00 00`):
    * two merged 64-bit compares  -- movabs r64, 0x0000008C00001414 ; cmp
      (GCC packs the adjacent VendorId/DeviceId fields into one qword)
    * one split 32-bit compare    -- cmp eax, 0x1414 ; ... cmp [..], 0x008c

  This script flips the VendorId immediate 0x1414 -> 0x1415 at every such
  site. WARP's real VendorId is 0x1414, so after the edit it matches none
  of the reject rules and is accepted. 0x1415 (Microsoft's id + 1) is used
  so the edit stays self-documenting in any future disassembly. Capture
  via WARP is CPU-bound but usable for desktop work.

  Only the VendorId byte (one byte per site) is changed; opcodes, operand
  encodings and instruction lengths are untouched, so no branch targets
  shift. Each candidate is validated before patching -- the preceding
  opcode must be a compare/movabs AND the MBRD DeviceId 0x008c must appear
  within a small window -- so the script never edits an unrelated 0x1414.

  The script is idempotent: it detects sites already at 0x1415 and exits.
  It backs the original up to a timestamped copy before writing. It stops
  the LG service before patching (so the EXE isn't locked) and restarts it
  after, if it was running at the start.

  Run from an elevated PowerShell:

      Set-ExecutionPolicy -Scope Process Bypass
      .\Patch-LookingGlassServer.ps1

  Re-applying after an LG version upgrade is safe (the next install
  overwrites the patched EXE with a fresh original; the script detects the
  unpatched state and patches again).

.PARAMETER ExePath
  Path to the LG server executable. Defaults to the standard install path.

.PARAMETER ServiceName
  Name of the Windows service. Defaults to "Looking Glass (host)".

.NOTES
  Affects only the LG server inside this guest. Does NOT touch the LG
  client on the hypervisor or any other LG component. To revert, copy one
  of the .unpatched.<timestamp>.bak files back over the EXE.

  Verified against B7 (looking-glass-host.exe, 309,888 bytes, 3 sites). A
  build that compares the VendorId as a 16-bit immediate (66 3D 14 14) or
  uses a different compiler layout may need the search/validation widened
  -- the script aborts cleanly (no changes) when it can't find a site.
#>

[CmdletBinding()]
param(
    [string]$ExePath     = 'C:\Program Files\Looking Glass (host)\looking-glass-host.exe',
    [string]$ServiceName = 'Looking Glass (host)'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Target: the Microsoft PCI VendorId (0x1414) used in LG's "unsupported
#    adapter" reject test, as a 32-bit little-endian immediate. The patched
#    form bumps it to 0x1415 so the equality can never hold for a real WARP
#    adapter while staying recognisable in a disassembly. ─────────────────
$VendorIdLE        = [byte[]](0x14, 0x14, 0x00, 0x00)   # 0x1414  -> reject
$VendorIdPatchedLE = [byte[]](0x15, 0x14, 0x00, 0x00)   # 0x1415  -> never matches
$ProximityWindow   = 0x200                              # MBRD 0x008c must be this close

# ── Helpers ───────────────────────────────────────────────────────────────

function Find-ByteSequence {
    [OutputType([int[]])]
    param(
        [Parameter(Mandatory)][byte[]]$Haystack,
        [Parameter(Mandatory)][byte[]]$Needle
    )

    $hits = [System.Collections.Generic.List[int]]::new()
    $end  = $Haystack.Length - $Needle.Length
    for ($i = 0; $i -le $end; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) {
                $match = $false
                break
            }
        }
        if ($match) { $hits.Add($i) }
    }
    # Unary comma: emit the array as a single object so PowerShell's pipeline
    # does NOT unwrap it. Without this, a 0-element result becomes $null and a
    # 1-element result becomes a bare [int] -- and the caller's $hits.Length
    # then throws PropertyNotFoundStrict (under Set-StrictMode) or misbehaves.
    return ,$hits.ToArray()
}

# True when $Offset sits on the VendorId immediate of a genuine MBRD reject
# test: the byte(s) just before it form a compare/movabs immediate load, AND
# the MBRD DeviceId 0x008c is encoded within +/-$ProximityWindow bytes.
function Test-MbrdSite {
    param(
        [Parameter(Mandatory)][byte[]]$Bytes,
        [Parameter(Mandatory)][int]$Offset
    )

    if ($Offset -lt 2) { return $false }
    $p1 = $Bytes[$Offset - 1]   # opcode byte directly before the immediate
    $p2 = $Bytes[$Offset - 2]
    # 0x3D            = cmp eax, imm32
    # 0x48/0x49 Bx    = REX.W + (mov r64, imm64), x in B8..BF
    $opcodeOk = ($p1 -eq 0x3D) -or
                (($p2 -eq 0x48 -or $p2 -eq 0x49) -and $p1 -ge 0xB8 -and $p1 -le 0xBF)
    if (-not $opcodeOk) { return $false }

    $lo = [Math]::Max(0, $Offset - $ProximityWindow)
    $hi = [Math]::Min($Bytes.Length - 1, $Offset + $ProximityWindow) - 3
    for ($k = $lo; $k -le $hi; $k++) {
        if ($Bytes[$k]     -eq 0x8C -and $Bytes[$k + 1] -eq 0x00 -and
            $Bytes[$k + 2] -eq 0x00 -and $Bytes[$k + 3] -eq 0x00) { return $true }
    }
    return $false
}

# ── Pre-flight ────────────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "LG server executable not found: $ExePath"
}

Write-Host "Reading $ExePath ..."
$bytes = [System.IO.File]::ReadAllBytes($ExePath)
Write-Host ("  File size: {0:N0} bytes" -f $bytes.Length)

# Classify every VendorId-shaped immediate that sits in a real MBRD test.
$toPatch        = [System.Collections.Generic.List[int]]::new()
$alreadyPatched = [System.Collections.Generic.List[int]]::new()

foreach ($o in (Find-ByteSequence -Haystack $bytes -Needle $VendorIdLE)) {
    if (Test-MbrdSite -Bytes $bytes -Offset $o) { $toPatch.Add($o) }
}
foreach ($o in (Find-ByteSequence -Haystack $bytes -Needle $VendorIdPatchedLE)) {
    if (Test-MbrdSite -Bytes $bytes -Offset $o) { $alreadyPatched.Add($o) }
}

# Idempotency: nothing left at 0x1414 -> either already done, or not found.
if ($toPatch.Count -eq 0) {
    if ($alreadyPatched.Count -gt 0) {
        Write-Host "Already patched. $($alreadyPatched.Count) MBRD reject site(s) at 0x1415:"
        foreach ($o in $alreadyPatched) { Write-Host ("  0x{0:X8}" -f $o) }
        Write-Host "Nothing to do."
        return
    }
    throw @"
Found no MBRD reject site (Microsoft VendorId 0x1414 alongside DeviceId
0x008c) in $ExePath. Possible causes:
  - Wrong file path.
  - An LG build with a different compiler layout (e.g. a 16-bit VendorId
    compare, 66 3D 14 14) -- widen the search/validation in this script.
  - The adapter filter was refactored or removed upstream.
Aborting without changes.
"@
}

Write-Host "Found $($toPatch.Count) MBRD reject site(s) to patch (VendorId 0x1414 -> 0x1415):"
foreach ($o in $toPatch) { Write-Host ("  0x{0:X8}" -f $o) }
if ($alreadyPatched.Count -gt 0) {
    Write-Host "  (plus $($alreadyPatched.Count) site(s) already at 0x1415)"
}

# ── Stop the service if it's running (releases the file lock) ─────────────

$wasRunning = $false
$svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
if ($null -ne $svc) {
    if ($svc.Status -eq 'Running') {
        Write-Host "Stopping service '$ServiceName' to release file lock ..."
        Stop-Service -Name $ServiceName
        $wasRunning = $true
    } else {
        Write-Host "Service '$ServiceName' is $($svc.Status); no stop needed."
    }
} else {
    Write-Host "Service '$ServiceName' not registered; proceeding without service control."
}

# ── Backup the original ───────────────────────────────────────────────────

$timestamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
$backupPath = "$ExePath.unpatched.$timestamp.bak"

# Defensive: the timestamp gives 1-second resolution; if for some reason a
# backup of the same name exists, suffix a counter so we never overwrite a
# previous backup.
$counter = 0
while (Test-Path -LiteralPath $backupPath) {
    $counter++
    $backupPath = "$ExePath.unpatched.$timestamp.$counter.bak"
}

Copy-Item -LiteralPath $ExePath -Destination $backupPath
Write-Host "Backup: $backupPath"

# ── Patch and write (flip the VendorId LSB 0x14 -> 0x15 at each site) ─────

foreach ($offset in $toPatch) { $bytes[$offset] = 0x15 }

[System.IO.File]::WriteAllBytes($ExePath, $bytes)
Write-Host "Patched $($toPatch.Count) site(s) in $ExePath."

# ── Restart the service if we stopped it ──────────────────────────────────

if ($wasRunning) {
    Write-Host "Starting service '$ServiceName' ..."
    Start-Service -Name $ServiceName
    Write-Host "Service restarted. Check the LG host log: the WARP adapter"
    Write-Host "should no longer be rejected ('Not using unsupported adapter'"
    Write-Host "gone) and a 'Capture Method' line should appear (D12 or DXGI)."
} else {
    Write-Host "Done. Start '$ServiceName' yourself when ready."
}

<#
═══════════════════════════════════════════════════════════════════════════════
 HANDOVER  ―  Extend this script with a second patch step
═══════════════════════════════════════════════════════════════════════════════

You are running on the Windows guest VM where looking-glass-host.exe lives
and you have access to disassembly tools (dumpbin, Ghidra, IDA, radare2,
llvm-objdump, whatever the box has — install one if not). This script in
its current form patches the MBRD adapter filter (numeric PCI VendorId
0x1414 → 0x1415, one byte each at validated sites). That bypasses the
"Not using unsupported adapter" rejection — but a *second* gate then
fires: D3D11CreateDevice itself refuses the WARP adapter, because LG
asks for the D3D11_CREATE_DEVICE_VIDEO_SUPPORT capability and WARP has
no hardware video decoder. The observed runtime symptom is:

    Failed to create the D3D11Device: 0x887a0004
      (The specified device interface or feature level is not supported
       on this system.)

YOUR TASK
─────────
Extend this script with a second patch pass that zeroes out the
D3D11_CREATE_DEVICE_VIDEO_SUPPORT bit (0x800) at every D3D11CreateDevice
call site in looking-glass-host.exe, so D3D11 device creation succeeds
on WARP. Stick to the conventions already established here:

  - Idempotent: classify candidate sites into `$toPatch` vs
    `$alreadyPatched` and exit cleanly when nothing's left to do.
  - Pre-flight validation: do NOT edit a byte you can't prove is a
    real call site. The existing MBRD detector uses an opcode-prefix
    check AND a proximity check for the DeviceId 0x008c. Apply the
    same idea with an oracle appropriate to D3D11CreateDevice (see
    "Validation oracles" below).
  - One-byte change per site, same instruction length, no branch-
    target reflow.
  - Fold both passes into one flow: shared service-stop / shared
    backup / shared single ReadAllBytes + WriteAllBytes. Don't write
    the file twice.
  - Update .SYNOPSIS / .DESCRIPTION / .NOTES at the top of this
    script to describe the extended scope.

SOURCE CONTEXT
──────────────
Both D3D11CreateDevice call sites (in dxgi.c and D12/backend/dd.c)
have identical shape:

    D3D11CreateDevice(
      adapter,                                // 1st: rcx
      D3D_DRIVER_TYPE_UNKNOWN,                // 2nd: edx
      NULL,                                   // 3rd: r8
      D3D11_CREATE_DEVICE_VIDEO_SUPPORT |     // 4th: r9d  ← patch HERE
        (debug ? D3D11_CREATE_DEVICE_DEBUG : 0),
      featureLevels,                          // 5th: stack
      ARRAY_LENGTH(featureLevels),            // 6th: stack
      D3D11_SDK_VERSION,                      // 7th: stack ← oracle candidate
      &d11device,
      &featureLevel,
      &d11context);

Relevant constants:
  D3D11_CREATE_DEVICE_VIDEO_SUPPORT = 0x00000800
  D3D11_CREATE_DEVICE_DEBUG         = 0x00000002
  D3D11_SDK_VERSION                 = 7

Goal: make the Flags arg evaluate to a value that does NOT include the
0x800 bit. Easiest is "patch the immediate so it's 0 instead of 0x800";
the surrounding instruction stays the same length, and LG still passes
*some* value (just without VIDEO_SUPPORT). Downstream LG code that tries
to use a D3D11VideoDevice on WARP would fail, but those paths are unused
on a pure-WARP guest anyway, so they don't fire.

`debug` is `option_get("d12", "debug")` — runtime, default false. Two
compilation shapes are likely:

  PATTERN A — debug provably/constant-folded false (release, no debug):
      41 B9 00 08 00 00      mov  r9d, 0x800
                             ↑ patch byte at offset+2 (the 0x08)
    Patched form:   41 B9 00 00 00 00      mov  r9d, 0

  PATTERN B — runtime OR / ADD against `debug<<1`:
      0F B6 ??               movzx eax, byte ptr [debug-field]
      D1 E0                  shl   eax, 1
      0D 00 08 00 00         or    eax, 0x800
                             ↑ patch byte at offset+2 (the 0x08)
      41 89 C1               mov   r9d, eax
    Patched form:   0D 00 00 00 00      or    eax, 0
    (Variant — `add eax, 0x800`: 05 00 08 00 00, same patch at offset+2.)

Single-byte change in both patterns. No length change. Mirror the
MBRD pass's `foreach ($offset in $toPatch) { $bytes[$offset] = 0x00 }`
style — but using the actual immediate-byte offset for whichever
pattern matches.

INVESTIGATION STEPS
───────────────────
1. Locate the D3D11CreateDevice IAT entry:
       dumpbin /imports "$ExePath" | findstr /C:"D3D11CreateDevice"
   Or via PowerShell + Get-PEHeader / ImportTable parsing if dumpbin
   isn't on PATH. Note the IAT slot's RVA.

2. Disassemble a window around every `call qword ptr [<IAT RVA>]` site.
   Whatever tool you've got — dumpbin /disasm, Ghidra headless, an
   `objdump -d -M intel` build, ndisasm-with-PE-offsets, etc. You're
   looking at the 10-30 instructions preceding each indirect call,
   specifically the loading of `r9d` (4th arg).

3. Identify which Pattern (A or B) this build emits. B7's host is a
   MinGW/GCC build; expect A in release. If you see Pattern B,
   document the variant in your output for posterity.

4. Confirm site count = 2 (one per backend: dxgi.c, D12/backend/dd.c).
   If you find ≠ 2, widen the search; if still ≠ 2, abort cleanly
   — do NOT speculatively patch. Better to report "could not find
   N sites in this build, here's what I saw" than to corrupt
   unrelated 0x800 immediates.

VALIDATION ORACLES
──────────────────
Per-site validation similar to Test-MbrdSite. Choose one or two
oracles cheap to check in PowerShell:

  - **IAT call proximity** (strongest signal): within ~80 bytes
    after the candidate immediate, look for `FF 15` followed by a
    4-byte RIP-relative displacement pointing at the D3D11CreateDevice
    IAT slot. This is the indirect call to the function whose 4th arg
    we're setting. If you've resolved the IAT slot's address in step 1
    above, you can compute the expected disp32 exactly. Strongest
    possible oracle; almost no false positives.

  - **D3D11_SDK_VERSION** (literal 7 as 4-byte immediate): within
    ~40 bytes of the candidate, find an instruction loading or
    storing the literal 7. Likely shapes:
        BF 07 00 00 00                   mov edi, 7
        BE 07 00 00 00                   mov esi, 7
        C7 44 24 ?? 07 00 00 00          mov dword ptr [rsp+??], 7
    Weaker than the IAT oracle (literal 7 is more common) but easy
    to grep.

  - **Feature-level array LEA**: an `lea r-, [rip+disp32]` whose
    target hits a .rdata block containing the constants
        00 C1 00 00     (D3D_FEATURE_LEVEL_12_1)
        00 C0 00 00     (D3D_FEATURE_LEVEL_12_0)
        00 B1 00 00     (D3D_FEATURE_LEVEL_11_1)
        00 B0 00 00     (D3D_FEATURE_LEVEL_11_0)
        ... down to 91 00 00 00 (D3D_FEATURE_LEVEL_9_1)
    in sequence. Hardest to validate cheaply but unambiguous.

The MBRD pass got away with a single proximity-based oracle because
the DeviceId 0x008c paired with VendorId 0x1414 is itself a near-unique
combination. The 0x800 immediate doesn't have that natural pairing in
the LG binary, so use the IAT-call oracle as the primary check.

WHAT TO ADD TO THIS SCRIPT
──────────────────────────
  - A `Find-VideoSupportSite` (or similar) validator that takes a
    candidate offset and returns true iff it sits in a real call
    setup as described above.
  - A second pass mirroring the existing classify-then-patch shape:
        $toPatchVideo        = ...
        $alreadyPatchedVideo = ...
    populated from the appropriate byte-pattern search.
  - One unified backup + write. The current flow:
        $bytes = ReadAllBytes
        ...classify & validate MBRD...
        ...classify & validate VIDEO_SUPPORT...     ← add here
        stop service (if needed, once)
        Copy-Item backup (once)
        foreach ($o in $mbrdToPatch)  { $bytes[$o]   = 0x15 }
        foreach ($o in $videoToPatch) { $bytes[$o+2] = 0x00 }  ← or whatever the actual offset is
        WriteAllBytes
        start service (if needed)
  - Idempotency for the unified flow: "nothing to do" iff both passes
    found zero `toPatch` AND their `alreadyPatched` sets are
    non-empty (or both empty *and* MBRD's "no MBRD site found"
    abort fires).
  - Update the script header (.SYNOPSIS / .DESCRIPTION / .NOTES /
    "Verified against B7") to document the second pass, the byte
    signature(s) you matched against in this specific binary, and
    the disassembly snippet of one patched site (before / after) so
    a future reader can verify the patch shape at a glance.

ANTI-PATTERNS
─────────────
  - Don't patch every occurrence of `00 08 00 00` in the binary —
    0x800 appears all over .rdata and elsewhere.
  - Don't change instruction lengths. Bytes match in / bytes match
    out, only the immediate-payload byte(s) differ.
  - Don't touch the DEBUG bit. Only the VIDEO_SUPPORT bit (0x800)
    matters. If you find a `0x802` immediate (debug-on builds), the
    same patch — clear the 0x800 bit — applies, but you'd write
    0x002 instead of 0x000 at offset+2. (Unlikely; this script
    targets release builds.)
  - Don't skip validation. False positives are silent — a misplaced
    patch on an unrelated 0x800 immediate produces subtle runtime
    bugs, not clear errors.
  - Don't write the file twice (once for MBRD, once for VIDEO_SUPPORT).
    Single read, both patches applied to the in-memory byte array,
    single write. Halves the I/O and means a partial-failure leaves
    the file untouched.

VERIFICATION AFTER RUNNING THE EXTENDED SCRIPT
──────────────────────────────────────────────
1. Restart the LG service.
2. Tail %ProgramData%\Looking Glass (host)\looking-glass-host.txt
3. Expected log progression (success):
       Trying           : D12
       Device Name       : \\.\DISPLAY1
       Device Description: Microsoft Basic Render Driver
       Device Vendor ID  : 0x1414                  ← MBRD reaches enum
       Device Device ID  : 0x8c
       Feature Level     : 0xb100 (or 0xa100/0xb000 — depends on WARP cap)
       ==== [ Capture Start ] ====                  ← VIDEO_SUPPORT past
4. From the hypervisor: looking-glass-client connects, shows the
   guest desktop rendered by WARP. Expect ~30-60 fps on desktop
   content with one core busy on the guest side; that's WARP, not
   LG. Mica / acrylic / animations should all be visible.

DELIVERABLE
───────────
Replace this .ps1 with your extended version. In the script's header
.NOTES section, paste:
  - The exact byte signature(s) you matched on this binary.
  - A 5-10 line disassembly snippet of one patched site, before
    and after.
  - The count of VIDEO_SUPPORT sites found (should be 2).
  - Which Pattern (A or B) this build uses.

That way the next time someone has to update the patch (LG B8, a
recompile, a different toolchain), the necessary disassembly context
is right there in the file.

═══════════════════════════════════════════════════════════════════════════════
#>
