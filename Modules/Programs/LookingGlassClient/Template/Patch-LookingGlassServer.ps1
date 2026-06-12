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
