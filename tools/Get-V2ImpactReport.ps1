#Requires -Version 7.0
<#
.SYNOPSIS
  Per v2 app/kind/branch: would the latest main/stage/dev build fail under the proposed (next) v2 rules?
.PARAMETER WorkspaceId
  Log Analytics workspace id; queried with `az monitor log-analytics query` (needs `az login`).
.PARAMETER RowsPath
  JSON array of rows (offline alternative): TimeGenerated, appName, appKind, sourceBranch, analyzerStack, previewRuleset,
  rulesetHash, status, wouldFailBuild.
.PARAMETER CandidateHash
  Hash(es) of the candidate rulesets (app and test rows carry different hashes: pass both); rows whose rulesetHash is not in the set are 'not evaluated (stale)'.
.NOTES
  Exit 1 on missing/invalid input, 0 otherwise (also for an empty result).
#>
[CmdletBinding()]
param(
    [string] $WorkspaceId,
    [string] $RowsPath,
    [string[]] $CandidateHash,
    [string] $OutPath
)

function Get-V2ImpactVerdicts {
    [CmdletBinding()]
    param([object[]] $Rows, [string[]] $CandidateHash)
    $branches = 'main', 'stage', 'dev'
    $rows = @($Rows | Where-Object { $null -ne $_ })
    $norm = foreach ($r in $rows) {
        # Rows come flat (the KQL projection) or AppTraces-shaped with the custom dimensions in a Properties bag
        # (object or JSON string); read the dimensions from wherever they are.
        $p = $r
        $bag = $r.PSObject.Properties['Properties']
        if ($null -ne $bag -and $null -ne $bag.Value) {
            $p = $bag.Value
            if ($p -is [string]) { $p = $p | ConvertFrom-Json }
        }
        $b = [string]$p.sourceBranch -replace '^refs/heads/', ''
        [pscustomobject]@{
            T = [datetime]::Parse([string]$r.TimeGenerated, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            App = [string]$p.appName; Kind = [string]$p.appKind; Branch = $b
            Stack = [string]$p.analyzerStack; Mode = [string]$p.previewRuleset
            Hash = [string]$p.rulesetHash; Status = [string]$p.status; Fail = [string]$p.wouldFailBuild
        }
    }
    $norm = @($norm)
    $v2Apps = @($norm | Where-Object { $_.Stack -eq 'v2' } | Select-Object -ExpandProperty App -Unique)
    $evidence = @($norm | Where-Object { $_.Mode -eq 'v2.next' })
    # every v2 app+kind seen (any row of a v2 app)
    $targets = @($norm | Where-Object { $_.App -in $v2Apps } | ForEach-Object { "$($_.App)`t$($_.Kind)" } | Sort-Object -Unique)
    $out = foreach ($t in $targets) {
        $app, $kind = $t -split "`t", 2
        foreach ($br in $branches) {
            $latest = $evidence | Where-Object { $_.App -eq $app -and $_.Kind -eq $kind -and $_.Branch -eq $br } |
                Sort-Object T -Descending | Select-Object -First 1
            $verdict = if (-not $latest) { 'not evaluated' }
            elseif (@($CandidateHash | Where-Object { $_ }).Count -gt 0 -and $latest.Hash -notin $CandidateHash) { 'not evaluated (stale)' }
            elseif ($latest.Status -eq 'identical') { 'identical' }
            elseif ($latest.Status -in 'timeout', 'skipped') { 'not evaluated' }
            elseif ($latest.Fail -eq 'true') { 'fail' }
            elseif ($latest.Fail -eq 'false') { 'pass' }
            else { 'not evaluated' }
            [pscustomobject]@{ appName = $app; appKind = $kind; branch = $br; verdict = $verdict }
        }
    }
    , @($out)
}

if ($MyInvocation.InvocationName -eq '.') { return }   # dot-sourced by tests: functions only

function Stop-Report([string] $m) { [Console]::Error.WriteLine($m); exit 1 }
$ErrorActionPreference = 'Stop'
try {
    if ([bool]$WorkspaceId -eq [bool]$RowsPath) { Stop-Report 'Pass exactly one of -WorkspaceId or -RowsPath' }
    if ($RowsPath) {
        if (-not (Test-Path -LiteralPath $RowsPath)) { Stop-Report "Rows file not found: $RowsPath" }
        $parsed = Get-Content -Raw -LiteralPath $RowsPath | ConvertFrom-Json -NoEnumerate
        if ($parsed -isnot [System.Collections.IEnumerable] -or $parsed -is [string]) { Stop-Report 'Rows file must hold a JSON array' }
        $rows = @($parsed)
    }
    else {
        $kql = @'
AppTraces
| where OperationName == "CI Preview Compile" and TimeGenerated > ago(14d)
| extend P = todynamic(Properties)
| project TimeGenerated, appName = tostring(P.appName), appKind = tostring(P.appKind), sourceBranch = tostring(P.sourceBranch),
          analyzerStack = tostring(P.analyzerStack), previewRuleset = tostring(P.previewRuleset), rulesetHash = tostring(P.rulesetHash),
          status = tostring(P.status), wouldFailBuild = tostring(P.wouldFailBuild)
'@
        $raw = az monitor log-analytics query -w $WorkspaceId --analytics-query $kql -o json
        if ($LASTEXITCODE -ne 0) { Stop-Report 'az monitor log-analytics query failed' }
        # az returns an array of row objects keyed by column name (TimeGenerated included)
        $rows = @(($raw -join "`n") | ConvertFrom-Json -NoEnumerate)
    }
    $result = Get-V2ImpactVerdicts -Rows $rows -CandidateHash $CandidateHash
}
catch { Stop-Report $_.Exception.Message }

"| App | Kind | Branch | Verdict |"
"|---|---|---|---|"
foreach ($r in $result) { "| $($r.appName) | $($r.appKind) | $($r.branch) | $($r.verdict) |" }
if ($OutPath) { ConvertTo-Json -InputObject @($result) -Depth 4 | Set-Content -LiteralPath $OutPath -Encoding utf8 }
exit 0
