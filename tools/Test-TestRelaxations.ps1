#Requires -Version 7.0
<#
.SYNOPSIS
  Every v1 test relaxation (test action differs from the app action, or id absent in the app ruleset)
  has a record in v2/test-relaxations.json with a decision and a non-empty reason; records match the v1 files.
.NOTES
  Exit 0 = ok, exit 1 = problems (listed on stdout).
#>
[CmdletBinding()]
param(
    [string] $V1AppRulesetPath,
    [string] $V1TestRulesetPath,
    [string] $RelaxationsPath
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if (-not $V1AppRulesetPath) { $V1AppRulesetPath = Join-Path $root 'SOCITAS.ruleset.json' }
if (-not $V1TestRulesetPath) { $V1TestRulesetPath = Join-Path $root 'SOCITAS.test.ruleset.json' }
if (-not $RelaxationsPath) { $RelaxationsPath = Join-Path $root 'v2/test-relaxations.json' }

$app = @{}
foreach ($r in @((Get-Content -Raw -LiteralPath $V1AppRulesetPath | ConvertFrom-Json).rules)) { $app[[string]$r.id] = [string]$r.action }
$test = @{}
foreach ($r in @((Get-Content -Raw -LiteralPath $V1TestRulesetPath | ConvertFrom-Json).rules)) { $test[[string]$r.id] = [string]$r.action }
$records = @{}
$problems = [System.Collections.Generic.List[string]]::new()
foreach ($rec in @((Get-Content -Raw -LiteralPath $RelaxationsPath | ConvertFrom-Json))) {
    if ($records.ContainsKey([string]$rec.id)) { $problems.Add("$($rec.id): duplicate record") }
    $records[[string]$rec.id] = $rec
}

$expected = @($test.Keys | Where-Object { -not $app.ContainsKey($_) -or $app[$_] -ne $test[$_] } | Sort-Object { $_ } -CaseSensitive)
foreach ($id in $expected) {
    if (-not $records.ContainsKey($id)) { $problems.Add("${id}: v1 test relaxation has no record"); continue }
    $rec = $records[$id]
    if ($rec.decision -notin 'kept', 'dropped', 'remapped') { $problems.Add("${id}: decision '$($rec.decision)' is not kept|dropped|remapped") }
    if ([string]::IsNullOrWhiteSpace([string]$rec.reason)) { $problems.Add("${id}: reason is empty") }
    if ([string]$rec.v1TestAction -ne $test[$id]) { $problems.Add("${id}: v1TestAction '$($rec.v1TestAction)' differs from the v1 test ruleset '$($test[$id])'") }
    $appAction = if ($app.ContainsKey($id)) { $app[$id] } else { $null }
    if ($null -ne $appAction -and [string]$rec.v1AppAction -ne $appAction) { $problems.Add("${id}: v1AppAction '$($rec.v1AppAction)' differs from the v1 app ruleset '$appAction'") }
    if ($rec.decision -in 'kept', 'remapped' -and @($rec.v2Ids).Count -eq 0) { $problems.Add("${id}: $($rec.decision) needs at least one v2Id") }
}
foreach ($id in ($records.Keys | Sort-Object { $_ } -CaseSensitive)) {
    if ($id -notin $expected) { $problems.Add("${id}: record without a v1 test relaxation") }
}
if ($problems.Count -gt 0) {
    Write-Output "Test relaxation problems ($($problems.Count)):"
    foreach ($p in $problems) { Write-Output "  $p" }
    exit 1
}
Write-Output "Relaxations ok: $($expected.Count) v1 relaxations, all recorded."
exit 0
