# Unit tests for tools/Test-TestRelaxations.ps1 (AC13).
#
# Assumed contract (plan 1.1 gives no parameters; defaults point at the repo files):
#   Test-TestRelaxations.ps1 [-V1AppRulesetPath <file>] [-V1TestRulesetPath <file>] [-RelaxationsPath <file>]
#     defaults: SOCITAS.ruleset.json, SOCITAS.test.ruleset.json, v2/test-relaxations.json (repo root)
#   A v1 relaxation = id in the v1 test ruleset whose action differs from the v1 app action, or which is absent from the v1 app ruleset.
#   Each needs a record { id, ..., decision in kept|dropped|remapped, reason non-empty }.
#   exit 0 = ok; exit 1 = problems, offending ids named in the output.
#   Fixture relaxations: A2 (None vs Warning), A4 (Info vs Warning), T9 (absent from app).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Tool = Join-Path $PSScriptRoot '../tools/Test-TestRelaxations.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures'
    function Check($Records) {
        $p = Join-Path $TestDrive ('rel-' + [guid]::NewGuid().ToString('N') + '.json')
        Write-Json @($Records) $p
        Invoke-Tool -Script $script:Tool -Arguments @{
            V1AppRulesetPath = (Join-Path $script:Fx 'v1-app.json')
            V1TestRulesetPath = (Join-Path $script:Fx 'v1-test.json')
            RelaxationsPath = $p
        }
    }
    function Records { @(Get-Content -Raw (Join-Path $script:Fx 'relaxations-complete.json') | ConvertFrom-Json) }
}

Describe 'Test-TestRelaxations.ps1' {
    It 'tool script exists' { $script:Tool | Should -Exist }

    It 'passes when every v1 relaxation has a complete record' {
        (Check (Records)).ExitCode | Should -Be 0
    }

    It 'fails and names a differing-action relaxation without a record (A2)' {
        $script:Tool | Should -Exist
        $r = Check (Records | Where-Object id -ne 'A2')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'A2'
    }

    It 'fails and names an id absent from the v1 app ruleset without a record (T9)' {
        $script:Tool | Should -Exist
        $r = Check (Records | Where-Object id -ne 'T9')
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'T9'
    }

    It 'fails and names a record with an empty reason' {
        $script:Tool | Should -Exist
        $recs = Records; ($recs | Where-Object id -eq 'A4').reason = '  '
        $r = Check $recs
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'A4'
    }

    It 'fails and names a record with a missing reason' {
        $script:Tool | Should -Exist
        $recs = Records; ($recs | Where-Object id -eq 'A4').PSObject.Properties.Remove('reason')
        $r = Check $recs
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'A4'
    }

    It 'fails and names a record with an invalid decision' {
        $script:Tool | Should -Exist
        $recs = Records; ($recs | Where-Object id -eq 'A2').decision = 'maybe'
        $r = Check $recs
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'A2'
    }

    It 'fails and names a record with no decision' {
        $script:Tool | Should -Exist
        $recs = Records; ($recs | Where-Object id -eq 'T9').PSObject.Properties.Remove('decision')
        $r = Check $recs
        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'T9'
    }

    It 'does not demand a record for an unchanged rule (A1, A3)' {
        $r = Check (Records)
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Not -Match '\bA[13]\b'
    }
}
