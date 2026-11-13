# AC17: one announcement covering what v2 is, how to migrate, the local setup and how to propose a severity change.
# German, like the rest of the SOCITAS developer docs. Section titles are free; the checks look for the content anchors.
BeforeAll {
    $script:path = Join-Path $PSScriptRoot '..\docs\v2.md'
    $script:text = if (Test-Path $script:path) { Get-Content -Raw $script:path } else { '' }
    $script:headings = @($script:text -split "`n" | Where-Object { $_ -match '^#{1,3}\s' })
}

Describe 'AC17 - v2 announcement (docs/v2.md)' {
    It 'exists' { $script:path | Should -Exist }

    It 'has a section on what v2 is, naming the v2 stack (ALCops, SocitasCopV2, TestCop) and the pinned versions' {
        ($script:headings -join "`n") | Should -Match '(?i)was ist|überblick|worum'
        foreach ($t in 'ALCops', 'SocitasCopV2', 'TestCop', 'SOCITAS.ruleset.v2.json', 'SOCITAS.analyzers.v2.json') { $script:text | Should -Match ([regex]::Escape($t)) }
        $script:text | Should -Match '(?i)v1.*(eingefroren|bleibt)'
    }

    It 'has a migration section pointing at Convert-RepoToV2.ps1 and saying diagnostics are the developer''s to fix' {
        ($script:headings -join "`n") | Should -Match '(?i)migration|umstell|migrier'
        $script:text | Should -Match 'Convert-RepoToV2\.ps1'
        $script:text | Should -Match '(?i)-WhatIf'
        $script:text | Should -Match '(?i)erste[nrs]? PR|ersten Pull Request'
    }

    It 'has a local-setup section naming the SocitasAL command and parity with CI' {
        ($script:headings -join "`n") | Should -Match '(?i)lokal|vs ?code'
        $script:text | Should -Match 'Download v2 Analyzers'
        $script:text | Should -Match '(?i)gleich\w* .*CI|wie (die|der|in der) CI|identisch'
    }

    It 'has a section on proposing a severity change, pointing at the next files / v2-aenderungen.md' {
        ($script:headings -join "`n") | Should -Match '(?i)schweregrad|regel.*änder|änderung.*vorschlag|vorschlagen'
        $script:text | Should -Match 'SOCITAS\.ruleset\.v2\.next\.json|v2-aenderungen\.md'
    }
}
