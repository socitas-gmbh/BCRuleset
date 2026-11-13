#Requires -Version 7.0
<#
.SYNOPSIS
  Generates v2/SOCITAS.test.ruleset.v2.json = v2 app ruleset + kept/remapped test relaxations + test-only rules (ST*).
.NOTES
  Deterministic, LF line endings. Never hand-edit the output.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $AppRulesetPath,
    [Parameter(Mandatory)] [string] $RelaxationsPath,
    [string] $TestRulesPath,
    [Parameter(Mandatory)] [string] $OutPath
)
$ErrorActionPreference = 'Stop'
if (-not $TestRulesPath) {
    $default = Join-Path (Split-Path -Parent $RelaxationsPath) 'test-rules.json'
    if (Test-Path -LiteralPath $default) { $TestRulesPath = $default }
}
$app = Get-Content -Raw -LiteralPath $AppRulesetPath | ConvertFrom-Json
$relax = Get-Content -Raw -LiteralPath $RelaxationsPath | ConvertFrom-Json
$testRules = if ($TestRulesPath) { @((Get-Content -Raw -LiteralPath $TestRulesPath | ConvertFrom-Json).rules) } else { @() }

$rules = [System.Collections.Generic.List[object]]::new()
$index = @{}
foreach ($r in @($app.rules)) {
    $o = [ordered]@{ id = [string]$r.id; action = [string]$r.action; justification = [string]$r.justification }
    $index[$o.id] = $o
    $rules.Add($o)
}
function Set-Rule([string] $Id, [string] $Action, [string] $Justification) {
    if ($index.ContainsKey($Id)) {
        $index[$Id].action = $Action
        $index[$Id].justification = $Justification
    }
    else {
        $o = [ordered]@{ id = $Id; action = $Action; justification = $Justification }
        $index[$Id] = $o
        $rules.Add($o)
    }
}
foreach ($rec in @($relax)) {
    if ($rec.decision -notin 'kept', 'remapped') { continue }
    foreach ($id in @($rec.v2Ids)) { Set-Rule $id ([string]$rec.v1TestAction) ("Test relaxation (v1 $($rec.id)): " + $rec.reason) }
}
foreach ($t in $testRules) { Set-Rule ([string]$t.id) ([string]$t.action) ([string]$t.justification) }

$name = ([string]$app.name) -replace 'Ruleset v2', 'Test Ruleset v2'
$json = [ordered]@{ name = $name; rules = $rules.ToArray() } | ConvertTo-Json -Depth 6
$dir = Split-Path -Parent $OutPath
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($OutPath, ($json -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
