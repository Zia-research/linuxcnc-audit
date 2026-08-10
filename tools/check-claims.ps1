# check-claims.ps1 -- re-derive the numbers this repository writes in prose.
#
# WHY THIS EXISTS. Every number in these documents was measured once, typed
# once, and then left alone while the thing it measured moved. In August 2026 a
# sweep found ten such statements, three of them live on the published site for
# four days: a viewBox the figure had stopped producing, an export size that
# named a file two commits out of date, and a coverage count three days behind
# its own remeasurement. None was a careless error. Prose does not re-measure
# itself, and nothing here was asking it to.
#
# WHAT IT DOES. tools/claims.json pairs each written number with the NAME of an
# oracle. This script extracts the number from the document, runs the oracle,
# and fails when they disagree.
#
# THREE RULES IT KEEPS, each earned the hard way on this project:
#
#   1. A pattern that no longer matches is a FAILURE, never a pass. If the
#      sentence was rewritten and the anchor moved, the guard has stopped
#      guarding, and a guard that quietly stops guarding is worse than none.
#
#   2. An oracle that cannot run is UNMEASURED, never a pass. Missing the
#      pinned clone means the claim was not checked -- it does not mean the
#      claim is fine.
#
#   3. Every claim must first fail on a deliberately altered document. The
#      script mutates each extracted value and re-runs the comparison; if the
#      mutation still passes, the claim is not testing anything and the script
#      refuses to give a verdict. The same discipline drawio-check.ps1 applies
#      to its rules, and verify-citations.ps1 to its manifest.
#
# NO COMMAND IS READ FROM THE DATA FILE. Oracles are selected by name and
# implemented below: a JSON file whose contents get executed would be a
# code-execution vector in a public repository.
#
# Usage:
#   powershell -File tools\check-claims.ps1
#   powershell -File tools\check-claims.ps1 -LinuxcncPath C:\src\linuxcnc
#
# Exit: 0 all claims hold - 1 a claim diverges or its anchor moved - 2 something
# could not be measured, or a claim cannot fail.
#
# ASCII only.

param(
    [string]$LinuxcncPath,
    [switch]$Verbose
)

$ErrorActionPreference = 'Stop'

$tools = $PSScriptRoot
$repo  = Split-Path $tools -Parent
if (-not $LinuxcncPath) { $LinuxcncPath = Join-Path (Split-Path $repo -Parent) 'linuxcnc' }

$claimsPath = Join-Path $tools 'claims.json'
if (-not (Test-Path -LiteralPath $claimsPath -PathType Leaf)) {
    Write-Output "ERROR: claims.json not found beside this script -- $claimsPath"
    exit 2
}

# ---------- helpers ----------------------------------------------------------

function Read-Doc([string]$name) {
    $p = Join-Path $repo $name
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    return [IO.File]::ReadAllText($p)
}

# Compare on digits alone: "2 786" and "2786" are the same number written two
# ways, and a thousands separator is not a disagreement.
function Norm([string]$s) {
    if ($null -eq $s) { return '' }
    return ($s -replace '[\s\u00a0\u202f]', '')
}

$WORDS = @{
    'one' = 1; 'two' = 2; 'three' = 3; 'four' = 4; 'five' = 5; 'six' = 6;
    'seven' = 7; 'eight' = 8; 'nine' = 9; 'ten' = 10; 'eleven' = 11; 'twelve' = 12
}
function WordToNumber([string]$w) {
    $k = $w.ToLower()
    if ($WORDS.ContainsKey($k)) { return [string]$WORDS[$k] }
    return $null
}

# ---------- oracles ----------------------------------------------------------
# Each returns a string, or $null meaning "could not measure" -- which the
# caller reports as UNMEASURED and never as a pass.

function Get-Citations {
    $t = Read-Doc 'LINUXCNC-FINDINGS.md'
    if ($null -eq $t) { return $null }
    $ext = 'c|cc|h|hh|cpp|py|adoc|in|ps1|js|json|nml|hal|ini|md|txt|sh|am|mk'
    $rx  = '([A-Za-z0-9_.+-]+\.(' + $ext + ')|Makefile):[0-9]+'
    return @([regex]::Matches($t, $rx) | ForEach-Object { $_.Value -replace '.*/', '' } | Sort-Object -Unique)
}

function Get-ManifestKeys {
    $p = Join-Path $tools 'citations-manifest.json'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
    $m = Get-Content $p -Raw | ConvertFrom-Json
    $s = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($e in $m.checks) { [void]$s.Add((Split-Path $e.file -Leaf) + ':' + $e.line) }
    return $s
}

function Count-Exact($cits, $keys) {
    $n = 0
    foreach ($c in $cits) { if ($keys.Contains($c)) { $n++ } }
    return $n
}

function Oracle([string]$name) {
    switch ($name) {

        'sheet-count' {
            $d = Join-Path $repo 'sheets'
            if (-not (Test-Path $d)) { return $null }
            return [string]@(Get-ChildItem $d -Filter *.html -File).Count
        }

        'drawio-lines' {
            $p = Join-Path $repo 'sheets\linuxcnc-system-overview.drawio'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
            return [string]([regex]::Matches([IO.File]::ReadAllText($p), "`n")).Count
        }

        'viewbox' {
            $p = Join-Path $repo 'sheets\linuxcnc-system-overview.svg'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
            $m = [regex]::Match([IO.File]::ReadAllText($p), 'viewBox="([^"]+)"')
            if (-not $m.Success) { return $null }
            return $m.Groups[1].Value
        }

        'citations-distinct' {
            $c = Get-Citations
            if ($null -eq $c) { return $null }
            return [string]$c.Count
        }

        'citations-exact' {
            $c = Get-Citations; $k = Get-ManifestKeys
            if (($null -eq $c) -or ($null -eq $k)) { return $null }
            return [string](Count-Exact $c $k)
        }

        'citations-percent' {
            $c = Get-Citations; $k = Get-ManifestKeys
            if (($null -eq $c) -or ($null -eq $k) -or ($c.Count -eq 0)) { return $null }
            return [string][Math]::Round(100.0 * (Count-Exact $c $k) / $c.Count)
        }

        'motion-commands' {
            $t = Read-Doc 'motion-commands-reference.md'
            if ($null -eq $t) { return $null }
            return [string]([regex]::Matches($t, '(?m)^\|\s*`?EMCMOT_')).Count
        }

        'motion-documented' {
            $t = Read-Doc 'motion-commands-reference.md'
            if ($null -eq $t) { return $null }
            $m = [regex]::Match($t, 'documents (\d+) commands')
            if (-not $m.Success) { return $null }
            return $m.Groups[1].Value
        }

        'gcode-lines' {
            $p = Join-Path $LinuxcncPath 'docs\src\gcode\g-code.adoc'
            if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { return $null }
            return [string]([regex]::Matches([IO.File]::ReadAllText($p), "`n")).Count
        }

        'errata-count' {
            $t = Read-Doc 'LINUXCNC-FINDINGS.md'
            if ($null -eq $t) { return $null }
            # The whole document, not Part 3. Written that way first, and it
            # refused: Part 3 holds 1-25 and 28-38, because errata 26 and 27 are
            # in Part 6, against the G-code reference rather than the Code
            # Notes. The refusal was the right answer to the wrong question --
            # it declined to report 38 from a set that stopped at 36.
            $ids = @([regex]::Matches($t, '(?m)^\|\s*\*{0,2}(\d{1,2})\*{0,2}\s*\|') | ForEach-Object { [int]$_.Groups[1].Value }) | Sort-Object -Unique
            if ($ids.Count -eq 0) { return $null }
            # The claim is a range "1-N": answer N, and only when the range is
            # whole. A gap means the numbering is not what the sentence says,
            # and guessing the endpoint would paper over exactly that.
            if ($ids[0] -ne 1 -or $ids[-1] -ne $ids.Count) { return $null }
            return [string]$ids[-1]
        }

        'ethercat-citations' {
            $t = Read-Doc 'ETHERCAT-NOTES.md'
            if ($null -eq $t) { return $null }
            $ext = 'c|cc|h|hh|cpp|py|adoc|in|ps1|js|json|nml|hal|ini|md|txt|sh|am|mk'
            $rx  = '([A-Za-z0-9_.+-]+\.(' + $ext + ')|Makefile):[0-9]+'
            return [string]@([regex]::Matches($t, $rx) | ForEach-Object { $_.Value -replace '.*/', '' } | Sort-Object -Unique).Count
        }

        'ethercat-uncovered' {
            $t = Read-Doc 'ETHERCAT-NOTES.md'; $k = Get-ManifestKeys
            if (($null -eq $t) -or ($null -eq $k)) { return $null }
            $ext = 'c|cc|h|hh|cpp|py|adoc|in|ps1|js|json|nml|hal|ini|md|txt|sh|am|mk'
            $rx  = '([A-Za-z0-9_.+-]+\.(' + $ext + ')|Makefile):[0-9]+'
            $c = @([regex]::Matches($t, $rx) | ForEach-Object { $_.Value -replace '.*/', '' } | Sort-Object -Unique)
            return [string]@($c | Where-Object { -not $k.Contains($_) }).Count
        }

        default { return $null }
    }
}

# ---------- one claim --------------------------------------------------------
# Returns a verdict object. 'stated' is what the document says, 'measured' what
# the oracle answers, both already normalised for comparison.

function Test-Claim($claim, [string]$docText) {
    if ($null -eq $docText) {
        return @{ id = $claim.id; state = 'UNMEASURED'; why = "document not found: $($claim.file)" }
    }
    $m = [regex]::Match($docText, $claim.pattern)
    if (-not $m.Success) {
        return @{ id = $claim.id; state = 'FAIL'; why = "the sentence this guard watches is gone -- pattern no longer matches in $($claim.file)" }
    }
    $stated = $m.Groups[1].Value
    if ($claim.format -eq 'word') {
        $asNumber = WordToNumber $stated
        if ($null -eq $asNumber) {
            return @{ id = $claim.id; state = 'FAIL'; why = "'$stated' is not a number word this script knows" }
        }
        $stated = $asNumber
    }
    $measured = Oracle $claim.oracle
    if ($null -eq $measured) {
        return @{ id = $claim.id; state = 'UNMEASURED'; why = "oracle '$($claim.oracle)' could not run"; stated = $stated }
    }
    if ((Norm $stated) -ne (Norm $measured)) {
        return @{ id = $claim.id; state = 'FAIL'; why = "document says $stated, measurement says $measured"; stated = $stated; measured = $measured }
    }
    return @{ id = $claim.id; state = 'PASS'; stated = $stated; measured = $measured }
}

# ---------- non-vacuity: every claim must be able to fail ---------------------
# The value the document states is replaced by one that cannot be right, and the
# claim is re-run on the altered text. If it still passes, the claim proves
# nothing -- either the pattern captures the wrong group, or the comparison is
# not comparing. This is the cheapest possible witness and it covers every entry
# rather than a sample.

function Test-CanFail($claim, [string]$docText, [string]$measured) {
    $mutated = $measured + '7'
    if ((Norm $mutated) -eq (Norm $measured)) { return 'mutation did not change the value' }
    $m = [regex]::Match($docText, $claim.pattern)
    if (-not $m.Success) { return 'pattern does not match, nothing to mutate' }
    $g = $m.Groups[1]
    $altered = $docText.Substring(0, $g.Index) + $mutated + $docText.Substring($g.Index + $g.Length)
    $r = Test-Claim $claim $altered
    if ($r.state -eq 'PASS') { return 'the claim still passes on an altered document' }
    return $null
}

# ---------- run --------------------------------------------------------------

$data = Get-Content $claimsPath -Raw | ConvertFrom-Json
$claims = @($data.claims)
if ($claims.Count -eq 0) {
    Write-Output 'REFUSED: claims.json holds no claim. An empty check passes everything.'
    exit 2
}

$docs = @{}
foreach ($c in $claims) { if (-not $docs.ContainsKey($c.file)) { $docs[$c.file] = Read-Doc $c.file } }

# Witnesses first, as everywhere in this repository: a verdict from a check that
# cannot fail is worth less than no verdict at all.
$cannotFail = @()
foreach ($c in $claims) {
    $r = Test-Claim $c $docs[$c.file]
    if ($r.state -ne 'PASS') { continue }   # only a passing claim can be mutated meaningfully
    $bad = Test-CanFail $c $docs[$c.file] $r.measured
    if ($bad) { $cannotFail += ("{0}: {1}" -f $c.id, $bad) }
}

# The mutation above exercises one branch -- disagreement -- twelve times a run.
# The other two branches decide whether a guard that has quietly stopped working
# is caught, and nothing else would ever reach them, so they get standing
# witnesses of their own.
$anchorGone = Test-Claim ([pscustomobject]@{
        id = '(witness)'; file = $claims[0].file
        pattern = 'a-sentence-this-repository-does-not-contain-(\d+)'; oracle = 'sheet-count'
    }) $docs[$claims[0].file]
if ($anchorGone.state -ne 'FAIL') {
    $cannotFail += "(witness): a pattern that matches nothing is reported as '$($anchorGone.state)' instead of FAIL -- a guard whose sentence was rewritten would go silent"
}

$noOracle = Test-Claim ([pscustomobject]@{
        id = '(witness)'; file = $claims[0].file
        pattern = $claims[0].pattern; format = $claims[0].format; oracle = 'no-such-oracle'
    }) $docs[$claims[0].file]
if ($noOracle.state -ne 'UNMEASURED') {
    $cannotFail += "(witness): an oracle that cannot run is reported as '$($noOracle.state)' instead of UNMEASURED"
}
if ($cannotFail.Count) {
    Write-Output 'REFUSED: a claim cannot fail, so this run proves nothing.'
    $cannotFail | ForEach-Object { Write-Output ("   " + $_) }
    exit 2
}

$pass = 0; $fail = 0; $unmeasured = 0
$lines = @()
foreach ($c in $claims) {
    $r = Test-Claim $c $docs[$c.file]
    switch ($r.state) {
        'PASS'       { $pass++;       $lines += ("  OK         {0,-20} {1} = {2}" -f $c.id, $c.file, $r.measured) }
        'FAIL'       { $fail++;       $lines += ("  DIVERGES   {0,-20} {1}" -f $c.id, $r.why) }
        'UNMEASURED' { $unmeasured++; $lines += ("  UNMEASURED {0,-20} {1}" -f $c.id, $r.why) }
    }
}

Write-Output ("claims : " + $claims.Count + " watched, each first mutated to prove it can fail;")
Write-Output ("         a vanished sentence and a dead oracle each have a standing witness too")
Write-Output ''
$lines | ForEach-Object { Write-Output $_ }
Write-Output ''
Write-Output ("$pass pass, $fail diverging, $unmeasured unmeasured")
if ($unmeasured -gt 0) {
    Write-Output 'An unmeasured claim is NOT a passing claim: nothing checked it this run.'
}
Write-Output ''
Write-Output 'Out of reach here: whether the numbers describe LinuxCNC correctly. This'
Write-Output 'script only checks that what the prose says matches what the repository'
Write-Output 'measures. verify-citations.ps1 is what holds the prose against the source.'

if ($fail -gt 0) { exit 1 }
if ($unmeasured -gt 0) { exit 2 }
exit 0
