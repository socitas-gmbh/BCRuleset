# Unit tests for tools/Test-RulesetCoverage.ps1 (AC6, AC8).
#
# Assumed contracts (plan 1.1):
#   Invocation : Test-RulesetCoverage.ps1 -RulesetPath <file> -InventoryPath <file> [-Analyzers <string[]>]
#                exit 0 = covered exactly; exit 1 = problems, ids named in the output (stdout/stderr/any stream).
#   Inventory  : { "analyzers": { "<AnalyzerName>": [ { "id", "defaultSeverity", "title" }, ... ], ... } }
#   Ruleset    : { "name", "rules": [ { "id", "action", "justification" } ] }
#   -Analyzers : restricts which inventory analyzers are expected (names = keys of "analyzers");
#                omitted = all analyzers in the inventory.
#   "Missing an action" = inventory id with no rule entry, or a rule entry with no/empty "action".

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Tool = Join-Path $PSScriptRoot '../tools/Test-RulesetCoverage.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures'
    $script:Inv = Join-Path $Fx 'inventory.json'
    $script:Complete = Join-Path $Fx 'ruleset-complete.json'
    function Run([string]$Ruleset, [string[]]$Analyzers) {
        $a = @{ RulesetPath = $Ruleset; InventoryPath = $script:Inv }
        if ($Analyzers) { $a.Analyzers = $Analyzers }
        Invoke-Tool -Script $script:Tool -Arguments $a
    }
    function New-Variant([scriptblock]$Mutate, [string]$Name) {
        $r = Get-Content -Raw $script:Complete | ConvertFrom-Json
        & $Mutate $r
        $p = Join-Path $TestDrive $Name
        Write-Json $r $p
        $p
    }
}

Describe 'Test-RulesetCoverage.ps1' {
    It 'tool script exists' {
        $script:Tool | Should -Exist
    }

    It 'passes (exit 0) when ruleset ids equal inventory ids exactly' {
        $r = Run $script:Complete
        $r.ExitCode | Should -Be 0
    }

    It 'fails and names an inventory id that has no rule' {
        $p = New-Variant { param($r) $r.rules = @($r.rules | Where-Object id -ne 'AA0002') } 'missing-rule.json'
        $script:Tool | Should -Exist
        $r = Run $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'AA0002'
        $r.Output | Should -Not -Match 'SC0001'
    }

    It 'fails and names an id whose rule has an empty action' {
        $p = New-Variant { param($r) ($r.rules | Where-Object id -eq 'SC0001').action = '' } 'empty-action.json'
        $script:Tool | Should -Exist
        $r = Run $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'SC0001'
    }

    It 'fails and names a ruleset id that is not in the inventory' {
        $p = New-Variant { param($r) $r.rules += [pscustomobject]@{ id = 'XX9999'; action = 'Warning'; justification = 'x' } } 'extra-rule.json'
        $script:Tool | Should -Exist
        $r = Run $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'XX9999'
    }

    It 'reports every problem, not just the first' {
        $p = New-Variant {
            param($r)
            $r.rules = @($r.rules | Where-Object id -ne 'AA0001')
            $r.rules += [pscustomobject]@{ id = 'XX9998'; action = 'Warning'; justification = 'x' }
        } 'both.json'
        $script:Tool | Should -Exist
        $r = Run $p
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'AA0001'
        $r.Output | Should -Match 'XX9998'
    }

    Context '-Analyzers filter' {
        It 'ignores analyzers that are not selected (TestCop id absent, app analyzers only)' {
            $p = New-Variant { param($r) $r.rules = @($r.rules | Where-Object id -ne 'ST0001') } 'no-st.json'
            (Run $p @('CodeCop', 'SocitasCopV2')).ExitCode | Should -Be 0
        }

        It 'still fails for the same ruleset when the omitted analyzer is selected' {
            $p = New-Variant { param($r) $r.rules = @($r.rules | Where-Object id -ne 'ST0001') } 'no-st2.json'
            $script:Tool | Should -Exist
            $r = Run $p @('CodeCop', 'SocitasCopV2', 'TestCop')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'ST0001'
        }

        It 'does not report a missing id of a non-selected analyzer' {
            $p = New-Variant { param($r) $r.rules = @($r.rules | Where-Object { $_.id -notin 'SC0001', 'AA0002' }) } 'no-sc.json'
            $script:Tool | Should -Exist
            $r = Run $p @('CodeCop')
            $r.ExitCode | Should -Be 1
            $r.Output | Should -Match 'AA0002'
            $r.Output | Should -Not -Match 'SC0001'
        }
    }
}
