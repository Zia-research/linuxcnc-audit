# verify-citations.ps1 — machine-check every citation backing LINUXCNC-FINDINGS.md
#
# Usage:
#   powershell -File tools\verify-citations.ps1
#   powershell -File tools\verify-citations.ps1 -LinuxcncPath C:\src\linuxcnc -LcecPath C:\src\linuxcnc-ethercat
#
# By default the two repositories are expected as siblings of this repository:
#   <parent>\linuxcnc            https://github.com/LinuxCNC/linuxcnc
#   <parent>\linuxcnc-ethercat   https://github.com/linuxcnc-ethercat/linuxcnc-ethercat
#
# Reads tools\citations-manifest.json, opens each cited file at the cited line,
# and matches the line against the manifest regex.
#
# Exit code 0 = all pass. Non-zero = at least one FAIL; each FAIL prints the
# line actually found so the citation in LINUXCNC-FINDINGS.md can be
# re-anchored.
#
# A FAIL after `git pull` usually means upstream moved the line, not that the
# finding is wrong. Fix the manifest and the .md together, and record the new
# HEAD in the manifest's _verified_against block.

param(
    [string]$LinuxcncPath,
    [string]$LcecPath
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
$parent   = Split-Path -Parent $repoRoot

if (-not $LinuxcncPath) { $LinuxcncPath = Join-Path $parent "linuxcnc" }
if (-not $LcecPath)     { $LcecPath     = Join-Path $parent "linuxcnc-ethercat" }

$repos = @{ linuxcnc = $LinuxcncPath; lcec = $LcecPath }

$manifest = Get-Content (Join-Path $PSScriptRoot "citations-manifest.json") -Raw |
            ConvertFrom-Json

$git = Get-Command git -ErrorAction SilentlyContinue
foreach ($k in $repos.Keys) {
    if (Test-Path $repos[$k]) {
        if ($git) {
            $head = & $git.Source -C $repos[$k] log -1 --format="%h %ad" --date=short 2>$null
            Write-Host ("repo {0,-9} : HEAD {1}" -f $k, $head)
        } else {
            Write-Host ("repo {0,-9} : {1}" -f $k, $repos[$k])
        }
    } else {
        Write-Host ("repo {0,-9} : MISSING at {1}" -f $k, $repos[$k]) -ForegroundColor Red
        Write-Host "  clone it there, or pass -LinuxcncPath / -LcecPath" -ForegroundColor Red
    }
}
Write-Host ""

$pass = 0; $fail = 0
$fileCache = @{}

foreach ($c in $manifest.checks) {
    $repoPath = $repos[$c.repo]
    $path = Join-Path $repoPath ($c.file -replace '/', '\')

    if (-not (Test-Path $path)) {
        Write-Host ("FAIL {0}:{1}  FILE MISSING  [{2}]" -f $c.file, $c.line, $c.claim) -ForegroundColor Red
        $fail++
        continue
    }

    if (-not $fileCache.ContainsKey($path)) {
        $fileCache[$path] = Get-Content $path
    }
    $lines = $fileCache[$path]

    if ($c.line -gt $lines.Count) {
        Write-Host ("FAIL {0}:{1}  LINE BEYOND EOF ({2} lines)  [{3}]" -f $c.file, $c.line, $lines.Count, $c.claim) -ForegroundColor Red
        $fail++
        continue
    }

    $text = $lines[$c.line - 1]
    if ($text -match $c.match) {
        $pass++
    } else {
        $shown = $text.Trim()
        if ($shown.Length -gt 70) { $shown = $shown.Substring(0, 70) + "…" }
        Write-Host ("FAIL {0}:{1}  expected /{2}/" -f $c.file, $c.line, $c.match) -ForegroundColor Red
        Write-Host ("     found: {0}" -f $shown) -ForegroundColor DarkYellow
        Write-Host ("     claim: {0}" -f $c.claim) -ForegroundColor DarkGray
        $fail++
    }
}

Write-Host ""
Write-Host ("{0} pass, {1} fail, {2} total" -f $pass, $fail, ($pass + $fail)) `
    -ForegroundColor $(if ($fail -eq 0) { "Green" } else { "Red" })

exit $(if ($fail -eq 0) { 0 } else { 1 })
