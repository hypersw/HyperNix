#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
  Binary-patch the Looking Glass server (host) executable to disable
  the "Microsoft Basic Render Driver" adapter filter, allowing LG to
  capture from WARP/MBRD-only Windows guests (no real or passed-
  through GPU available).

.DESCRIPTION
  LG's source contains a hardcoded check that refuses any adapter
  whose WDDM description is "Microsoft Basic Render Driver" (the
  name for WARP, Microsoft's software D3D renderer). The check
  compares against a UTF-16 LE literal embedded in the binary. By
  flipping the first byte of that literal (M -> X), the comparison
  can never match a real adapter description, and the filter passes
  every adapter through. Performance with WARP is CPU-bound but
  usable for desktop testing (Mica, acrylic, IDE work).

  The script is idempotent: it detects an already-patched binary
  and exits cleanly. It backs the original up to a timestamped
  copy before writing. It stops the LG service before patching
  (so the EXE isn't locked) and restarts it after, if it was
  running at the start.

  Run from an elevated PowerShell:

      Set-ExecutionPolicy -Scope Process Bypass
      .\Patch-LookingGlassServer.ps1

  Re-applying after an LG version upgrade is safe (the next install
  overwrites the patched EXE with a fresh original; the script
  detects the unpatched state and patches again).

.PARAMETER ExePath
  Path to the LG server executable. Defaults to the standard
  install location.

.PARAMETER ServiceName
  Name of the Windows service. Defaults to "Looking Glass (host)".

.NOTES
  Affects only the LG server inside this guest. Does NOT touch the
  LG client on the hypervisor or any other LG component. To revert,
  rename one of the .unpatched.<timestamp>.bak files back over the
  EXE.
#>

[CmdletBinding()]
param(
    [string]$ExePath     = 'C:\Program Files\Looking Glass (host)\looking-glass-host.exe',
    [string]$ServiceName = 'Looking Glass (host)'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Target strings, encoded as UTF-16 LE byte arrays. ─────────────────
# The unpatched form is the literal LG compares against; the patched
# form mutates one byte (first 'M' -> 'X') so the comparison fails on
# all real adapter descriptions while leaving the bytes as a readable
# string in any future strings dump.
$enc      = [System.Text.Encoding]::Unicode
$original = $enc.GetBytes('Microsoft Basic Render Driver')
$patched  = $enc.GetBytes('Xicrosoft Basic Render Driver')

# ── Helpers ───────────────────────────────────────────────────────────

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
    return $hits.ToArray()
}

# ── Pre-flight ────────────────────────────────────────────────────────

if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
    throw "LG server executable not found: $ExePath"
}

Write-Host "Reading $ExePath ..."
$bytes = [System.IO.File]::ReadAllBytes($ExePath)
Write-Host ("  File size: {0:N0} bytes" -f $bytes.Length)

# Idempotency check: bail out if we already patched this EXE.
$patchedHits = Find-ByteSequence -Haystack $bytes -Needle $patched
if ($patchedHits.Length -gt 0) {
    Write-Host "Already patched. Found $($patchedHits.Length) occurrence(s) of the patched marker at offsets:"
    foreach ($o in $patchedHits) { Write-Host ("  0x{0:X8}" -f $o) }
    Write-Host "Nothing to do."
    return
}

# Locate the unpatched target.
$originalHits = Find-ByteSequence -Haystack $bytes -Needle $original
if ($originalHits.Length -eq 0) {
    throw @"
Could not find the target string 'Microsoft Basic Render Driver'
(UTF-16 LE) anywhere in $ExePath. Possible causes:
  - Wrong file path.
  - An LG version that has refactored or removed the filter
    (unlikely without a release note, but possible).
  - The EXE is already patched but via a different byte substitution.
Aborting without changes.
"@
}

Write-Host "Found $($originalHits.Length) occurrence(s) of the target string at offsets:"
foreach ($o in $originalHits) { Write-Host ("  0x{0:X8}" -f $o) }

# ── Stop the service if it's running (releases the file lock) ─────────

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

# ── Backup the original ───────────────────────────────────────────────

$timestamp  = (Get-Date).ToString('yyyyMMdd-HHmmss')
$backupPath = "$ExePath.unpatched.$timestamp.bak"

# Defensive: the timestamp gives 1-second resolution; if for some reason
# a backup of the same name exists, suffix a counter so we never
# overwrite a previous backup.
$counter = 0
while (Test-Path -LiteralPath $backupPath) {
    $counter++
    $backupPath = "$ExePath.unpatched.$timestamp.$counter.bak"
}

Copy-Item -LiteralPath $ExePath -Destination $backupPath
Write-Host "Backup: $backupPath"

# ── Patch and write ───────────────────────────────────────────────────

foreach ($offset in $originalHits) {
    for ($j = 0; $j -lt $patched.Length; $j++) {
        $bytes[$offset + $j] = $patched[$j]
    }
}

[System.IO.File]::WriteAllBytes($ExePath, $bytes)
Write-Host "Patched $($originalHits.Length) occurrence(s) in $ExePath."

# ── Restart the service if we stopped it ──────────────────────────────

if ($wasRunning) {
    Write-Host "Starting service '$ServiceName' ..."
    Start-Service -Name $ServiceName
    Write-Host "Service restarted. Check the LG server log for"
    Write-Host "  'capture method D12 started' (or DXGI)"
    Write-Host "with the WARP/MBRD adapter now accepted."
} else {
    Write-Host "Done. Start '$ServiceName' yourself when ready."
}
