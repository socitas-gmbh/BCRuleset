#Requires -Version 7.0
<#
.SYNOPSIS
  Promotion guard: a changed v2 file must equal its own *.next.json as of the base ref; v1 files must not change.
.NOTES
  Exit 0 = ok, exit 1 = offending files named on stdout. Next files may change freely (proposal).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $BaseRef,
    [string] $RepoRoot = (Get-Location).Path
)
$ErrorActionPreference = 'Stop'
Push-Location -LiteralPath $RepoRoot
try {
    $pairs = [ordered]@{
        'SOCITAS.ruleset.v2.json'      = 'SOCITAS.ruleset.v2.next.json'
        'SOCITAS.test.ruleset.v2.json' = 'SOCITAS.test.ruleset.v2.next.json'
        'SOCITAS.analyzers.v2.json'    = 'SOCITAS.analyzers.v2.next.json'
    }
    $frozen = @('SOCITAS.ruleset.json', 'SOCITAS.test.ruleset.json')

    $changed = @(git diff --name-only $BaseRef HEAD)
    if ($LASTEXITCODE -ne 0) { Write-Output "git diff against '$BaseRef' failed"; exit 1 }
    $changed = @($changed | ForEach-Object { $_.Trim() } | Where-Object { $_ })

    function Get-BaseText([string] $file) {
        $t = git show "${BaseRef}:$file" 2>$null
        if ($LASTEXITCODE -ne 0) { return $null }
        return ((@($t) -join "`n") -replace "`r`n", "`n").TrimEnd("`n")
    }

    $bad = [System.Collections.Generic.List[string]]::new()
    foreach ($f in $frozen) {
        if ($changed -contains $f) { $bad.Add("$f is frozen (v1) and must not change") }
    }
    foreach ($cur in $pairs.Keys) {
        if ($changed -notcontains $cur) { continue }
        $nextBase = Get-BaseText $pairs[$cur]
        if ($null -eq $nextBase) { $bad.Add("$cur changed but $($pairs[$cur]) does not exist on $BaseRef"); continue }
        if (-not (Test-Path -LiteralPath $cur)) { $bad.Add("$cur was deleted"); continue }
        $new = ((Get-Content -Raw -LiteralPath $cur) -replace "`r`n", "`n").TrimEnd("`n")
        if ($new -ne $nextBase) { $bad.Add("$cur does not equal $($pairs[$cur]) as of $BaseRef (promote the next file first)") }
    }
    if ($bad.Count -gt 0) { $bad | ForEach-Object { Write-Output $_ }; exit 1 }
    Write-Output 'v2 promotion check ok'
    exit 0
}
finally { Pop-Location }
