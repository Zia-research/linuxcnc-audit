# verify-citations.ps1 — machine-check the manifest's citations backing LINUXCNC-FINDINGS.md
#
# IT IS A CURATED SET, NOT AN INDEX, and that is what a green run means: every
# citation IN THE MANIFEST was re-read against the source at the pinned commits.
# It does not mean every citation in LINUXCNC-FINDINGS.md was. This header once
# said "every citation", which was untrue and invited exactly that inference.
#
# The coverage figures are deliberately NOT repeated here. They live in ONE place,
# README.md, in the paragraph beginning "The manifest is a curated set" — together
# with the method, so the measurement can be redone rather than believed, and with
# the reason the citations left out are a decision rather than a backlog. A number
# kept in two files is a number that will drift: this header carried a stale one
# for a day after the manifest grew, which is why it now points instead of counts.
# The script enforces the same discipline from the other side, at the bottom of
# this file: it refuses to pass while any document in the repository states an
# expected count the manifest no longer holds.
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

# ---------------------------------------------------------------------------
# Self-consistency: does every document that tells a reader what to expect
# still name the right number?
#
# This exists because it went wrong twice. The manifest grew from 111 to 126 to
# 134 to 139, and each time the count was updated where it was remembered and
# left stale where it was not — once in a README that ships to readers, who
# would run this script, get one number and read another.
#
# Only forward-looking statements are checked: "Expected: `N pass". Changelog
# entries record what was true at the time and are left alone deliberately.
# ---------------------------------------------------------------------------

$total = $pass + $fail
$claims = @()
Get-ChildItem $repoRoot -Recurse -Include *.md -File |
    Where-Object { $_.FullName -notmatch '\\\.git\\' } | ForEach-Object {
        $rel = $_.FullName.Substring($repoRoot.Length + 1)
        $n = 0
        foreach ($line in (Get-Content $_.FullName)) {
            $n++
            foreach ($m in [regex]::Matches($line, 'Expected:\s*`?(\d+)\s+pass')) {
                $claims += [pscustomobject]@{
                    File = $rel; Line = $n; Claimed = [int]$m.Groups[1].Value
                }
            }
        }
    }

$stale = @($claims | Where-Object { $_.Claimed -ne $total })

Write-Host ""
if ($claims.Count -eq 0) {
    Write-Host "no document states an expected count" -ForegroundColor DarkGray
} elseif ($stale.Count -eq 0) {
    Write-Host ("{0} document(s) state an expected count, all agree with {1}" -f $claims.Count, $total) `
        -ForegroundColor Green
} else {
    foreach ($s in $stale) {
        Write-Host ("STALE COUNT {0}:{1}  says {2}, actual is {3}" -f $s.File, $s.Line, $s.Claimed, $total) `
            -ForegroundColor Red
    }
    Write-Host "  a reader running this script would get a number the docs deny" -ForegroundColor DarkYellow
}

exit $(if ($fail -eq 0 -and $stale.Count -eq 0) { 0 } else { 1 })
