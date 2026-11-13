#Requires -Version 7.0
<#
.SYNOPSIS
  Every inventory id of the selected analyzers needs an explicit action in the ruleset; every ruleset id must be in the inventory.
.PARAMETER Analyzers
  Inventory keys to check (string[]). Omitted = all keys. Ruleset ids belonging to no inventory key at all are reported either way.
.NOTES
  Exit 0 = ok, exit 1 = problems (ids listed on stdout).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $RulesetPath,
    [Parameter(Mandatory)] [string] $InventoryPath,
    [string[]] $Analyzers
)
$ErrorActionPreference = 'Stop'
$ruleset = Get-Content -Raw -LiteralPath $RulesetPath | ConvertFrom-Json
$inventory = Get-Content -Raw -LiteralPath $InventoryPath | ConvertFrom-Json
# `pwsh -File ... -Analyzers a,b` arrives as one string
if ($Analyzers) { $Analyzers = @($Analyzers | ForEach-Object { $_ -split ',' } | Where-Object { $_ }) }

$all = @{}
foreach ($p in $inventory.analyzers.PSObject.Properties) { foreach ($d in $p.Value) { $all[$d.id] = $true } }
$selected = [ordered]@{}
foreach ($p in $inventory.analyzers.PSObject.Properties) {
    if ($Analyzers -and $Analyzers.Count -gt 0 -and $p.Name -notin $Analyzers) { continue }
    foreach ($d in $p.Value) { $selected[$d.id] = $p.Name }
}
if ($Analyzers) {
    foreach ($a in $Analyzers) {
        if (-not ($inventory.analyzers.PSObject.Properties.Name -contains $a)) { Write-Output "Unknown analyzer '$a' (not an inventory key)"; exit 1 }
    }
}

$actions = @{}
foreach ($r in @($ruleset.rules)) {
    if ($null -eq $r) { continue }
    $actions[[string]$r.id] = [string]$r.action
}
$missing = @($selected.Keys | Where-Object { -not $actions.ContainsKey($_) -or [string]::IsNullOrWhiteSpace($actions[$_]) } | Sort-Object { $_ } -CaseSensitive)
$unknown = @($actions.Keys | Where-Object { -not $all.ContainsKey($_) } | Sort-Object { $_ } -CaseSensitive)

if ($missing.Count -gt 0) {
    Write-Output "Ids without an action ($($missing.Count)):"
    foreach ($m in $missing) { Write-Output "  $m ($($selected[$m]))" }
}
if ($unknown.Count -gt 0) {
    Write-Output "Ids not in the inventory ($($unknown.Count)):"
    foreach ($u in $unknown) { Write-Output "  $u" }
}
if ($missing.Count -gt 0 -or $unknown.Count -gt 0) { exit 1 }
Write-Output "Coverage ok: $($selected.Count) inventory ids, $($actions.Count) ruleset ids."
exit 0
