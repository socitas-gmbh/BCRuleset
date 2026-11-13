# Shared helpers for the BCRuleset tool tests (dot-sourced in BeforeAll).
# Tools are run as child pwsh processes so `exit 1` and output can be asserted without killing Pester.
function Invoke-Tool {
    param([Parameter(Mandatory)][string]$Script, [hashtable]$Arguments = @{})
    if (-not (Test-Path -LiteralPath $Script)) { return [pscustomobject]@{ ExitCode = 127; Output = "tool not found: $Script" } }
    $parts = foreach ($k in $Arguments.Keys) {
        $v = $Arguments[$k]
        $val = if ($v -is [array]) { ($v | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ',' }
               else { "'" + ([string]$v -replace "'", "''") + "'" }
        "-$k $val"
    }
    $cmd = "& '" + ($Script -replace "'", "''") + "' " + ($parts -join ' ') + "; exit `$LASTEXITCODE"
    $out = & pwsh -NoProfile -NonInteractive -Command $cmd 2>&1 | Out-String
    [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
}
function Write-Json { param($Object, [string]$Path) $Object | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8 }
