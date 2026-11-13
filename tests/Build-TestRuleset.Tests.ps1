# Unit tests for tools/Build-TestRuleset.ps1 (AC13).
#
# Assumed contract (plan 1.1):
#   Build-TestRuleset.ps1 -AppRulesetPath <v2 app ruleset> -RelaxationsPath <v2/test-relaxations.json> -OutPath <file>
#   Output : { "name", "rules": [ { id, action, justification } ] } (same shape as the app ruleset).
#   Records: { id, v1TestAction, v1AppAction, decision: kept|dropped|remapped, v2Ids[], reason }
#     kept     -> every id in v2Ids (fixtures use v2Ids = [id]) gets v1TestAction
#     remapped -> every id in v2Ids gets v1TestAction (id itself is a v1-only id, not in the app ruleset)
#     dropped  -> no effect, the app action stands
#   The generator may additionally add TestCop (ST*) actions; tests tolerate extra ST* ids only.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Tool = Join-Path $PSScriptRoot '../tools/Build-TestRuleset.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures'
    $script:App = Join-Path $Fx 'v2-app.json'
    $script:Rel = Join-Path $Fx 'relaxations-complete.json'
    function Build([string]$Out, [string]$Rel = $script:Rel, [string]$App = $script:App) {
        Invoke-Tool -Script $script:Tool -Arguments @{ AppRulesetPath = $App; RelaxationsPath = $Rel; OutPath = $Out }
    }
    function Actions($Path) {
        $h = @{}
        foreach ($r in (Get-Content -Raw $Path | ConvertFrom-Json).rules) { $h[$r.id] = $r.action }
        $h
    }
}

Describe 'Build-TestRuleset.ps1' {
    It 'tool script exists' { $script:Tool | Should -Exist }

    It 'exits 0 and writes the output file' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        $out | Should -Exist
    }

    It 'contains every app v2 rule' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        $act = Actions $out
        foreach ($id in 'A1', 'A2', 'A3', 'A4', 'B1') { $act.ContainsKey($id) | Should -BeTrue -Because "app rule $id must be carried over" }
    }

    It 'applies a kept relaxation (A2: app Warning -> test None)' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        (Actions $out)['A2'] | Should -Be 'None'
    }

    It 'applies a remapped relaxation to the v2 id (B1: app Error -> test Warning)' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        (Actions $out)['B1'] | Should -Be 'Warning'
    }

    It 'does not apply a dropped relaxation (A4 keeps the app action Warning, not Info)' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        (Actions $out)['A4'] | Should -Be 'Warning'
    }

    It 'leaves rules without a relaxation untouched' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        $act = Actions $out
        $act['A1'] | Should -Be 'Error'
        $act['A3'] | Should -Be 'None'
    }

    It 'does not introduce the v1-only id of a remapped record (T9)' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        (Actions $out).ContainsKey('T9') | Should -BeFalse
    }

    It 'adds no ids beyond app rules (apart from TestCop ST* ids)' {
        $out = Join-Path $TestDrive 'out.json'
        (Build $out).ExitCode | Should -Be 0
        $extra = (Actions $out).Keys | Where-Object { $_ -notin 'A1', 'A2', 'A3', 'A4', 'B1' -and $_ -notmatch '^ST\d{4}$' }
        @($extra) | Should -BeNullOrEmpty
    }

    It 'with only dropped relaxations the app actions are unchanged' {
        $rel = Join-Path $TestDrive 'rel-dropped.json'
        Write-Json @([pscustomobject]@{ id = 'A2'; v1TestAction = 'None'; v1AppAction = 'Warning'; decision = 'dropped'; v2Ids = @(); reason = 'r' }) $rel
        $out = Join-Path $TestDrive 'out-dropped.json'
        (Build $out $rel).ExitCode | Should -Be 0
        (Actions $out)['A2'] | Should -Be 'Warning'
    }

    It 'is deterministic: same input yields byte-identical output' {
        $o1 = Join-Path $TestDrive 'd1.json'; $o2 = Join-Path $TestDrive 'd2.json'
        (Build $o1).ExitCode | Should -Be 0
        (Build $o2).ExitCode | Should -Be 0
        (Get-FileHash $o1).Hash | Should -Be (Get-FileHash $o2).Hash
    }

    It 'fails (non-zero) when the relaxations file is missing' {
        $script:Tool | Should -Exist
        $out = Join-Path $TestDrive 'none.json'
        $r = Build $out (Join-Path $TestDrive 'does-not-exist.json')
        $r.ExitCode | Should -Not -Be 0
        $out | Should -Not -Exist
    }
}
