# AC10 (M6) - tools/Get-V2ImpactReport.ps1 turns AppTraces-like rows into a per-app/kind/branch verdict table.
#
# Contract assumptions (beyond the task contract):
#  - Rows: array of { TimeGenerated, OperationName, Properties:{ appId, appName, projectName, pipelineName, sourceBranch,
#    buildId, analyzerStack, appKind, previewRuleset, wouldFailBuild, status, rulesetHash, pinsRevision } }.
#  - sourceBranch may be 'refs/heads/<b>' or '<b>'; only main/stage/dev are reported.
#  - The v2 population = apps with ANY row whose analyzerStack == 'v2' (also rows with previewRuleset 'v2'); a v1 app never appears.
#    Each (app, appKind seen on any row of the app) is reported for ALL three branches; no row for a branch = 'not evaluated'.
#  - Only rows with previewRuleset == 'v2.next' count as evidence; the LATEST by TimeGenerated per app+kind+branch decides.
#  - Verdict precedence: stale hash (only when -CandidateHash given) > status identical > status timeout/skipped >
#    wouldFailBuild true/false/unknown. Verdict strings: fail | pass | identical | not evaluated | not evaluated (stale).
#  - -OutPath = JSON array of objects { appName, appKind, branch, verdict, ... }; stdout = Markdown table with those fields per line.
#  - Exit 0 for report generation, exit 1 on unreadable input (missing file, invalid JSON).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Tool = Join-Path $script:Root 'tools/Get-V2ImpactReport.ps1'
    $script:Rows = Join-Path $PSScriptRoot 'fixtures/impact/rows.json'
    $script:Broken = Join-Path $PSScriptRoot 'fixtures/impact/broken.json'

    function Get-Report([string]$Hash) {
        $out = Join-Path $TestDrive ("report-" + [guid]::NewGuid().ToString('N') + '.json')
        $a = @{ RowsPath = $script:Rows; OutPath = $out }
        if ($Hash) { $a.CandidateHash = $Hash }
        $r = Invoke-Tool -Script $script:Tool -Arguments $a
        $json = if (Test-Path -LiteralPath $out) { @(Get-Content -Raw $out | ConvertFrom-Json) } else { @() }
        [pscustomobject]@{ ExitCode = $r.ExitCode; Output = $r.Output; Items = $json }
    }
    function Verdict($rep, $app, $kind, $branch) {
        $m = @($rep.Items | Where-Object { $_.appName -eq $app -and $_.appKind -eq $kind -and $_.branch -eq $branch })
        $m.Count | Should -Be 1 -Because "exactly one entry for $app/$kind/$branch`n$($rep.Output)"
        $m[0].verdict
    }
}

Describe 'Get-V2ImpactReport - verdicts with -CandidateHash NEWHASH' {
    BeforeAll { $script:Rep = Get-Report 'NEWHASH' }

    It 'exits 0 and writes the JSON' {
        $script:Rep.ExitCode | Should -Be 0 -Because $script:Rep.Output
        $script:Rep.Items.Count | Should -BeGreaterThan 0
    }

    It 'latest row decides, regardless of row order: Alpha app main = fail (older rows were pass)' {
        Verdict $script:Rep 'Alpha' 'app' 'main' | Should -BeExactly 'fail'
    }
    It 'wouldFailBuild false = pass (Alpha app stage)' {
        Verdict $script:Rep 'Alpha' 'app' 'stage' | Should -BeExactly 'pass'
    }
    It 'only v2.next rows count: Alpha app dev has just a previewRuleset v2 row = not evaluated' {
        Verdict $script:Rep 'Alpha' 'app' 'dev' | Should -BeExactly 'not evaluated'
    }
    It 'wouldFailBuild unknown = not evaluated (Alpha test main)' {
        Verdict $script:Rep 'Alpha' 'test' 'main' | Should -BeExactly 'not evaluated'
    }
    It 'status identical = identical (Alpha test stage)' {
        Verdict $script:Rep 'Alpha' 'test' 'stage' | Should -BeExactly 'identical'
    }
    It 'status timeout = not evaluated even though wouldFailBuild is true (Alpha test dev)' {
        Verdict $script:Rep 'Alpha' 'test' 'dev' | Should -BeExactly 'not evaluated'
    }
    It 'status skipped = not evaluated even though wouldFailBuild is false (Beta app main)' {
        Verdict $script:Rep 'Beta' 'app' 'main' | Should -BeExactly 'not evaluated'
    }
    It 'a latest row with another rulesetHash is stale (Beta app stage)' {
        Verdict $script:Rep 'Beta' 'app' 'stage' | Should -BeExactly 'not evaluated (stale)'
    }
    It 'stale is judged on the LATEST row, not on any older matching one (Epsilon app main)' {
        Verdict $script:Rep 'Epsilon' 'app' 'main' | Should -BeExactly 'not evaluated (stale)'
    }
    It 'sourceBranch without refs/heads/ prefix is recognised (Beta test main = pass)' {
        Verdict $script:Rep 'Beta' 'test' 'main' | Should -BeExactly 'pass'
    }
    It 'test and app kind are reported separately (Beta app dev pass, Beta test dev not evaluated)' {
        Verdict $script:Rep 'Beta' 'app' 'dev' | Should -BeExactly 'pass'
        Verdict $script:Rep 'Beta' 'test' 'dev' | Should -BeExactly 'not evaluated'
    }
    It 'an app with no v2.next row at all is listed with every branch not evaluated (Delta)' {
        foreach ($b in 'main', 'stage', 'dev') { Verdict $script:Rep 'Delta' 'app' $b | Should -BeExactly 'not evaluated' }
    }
    It 'lists only main/stage/dev and each reported app+kind on all three' {
        @($script:Rep.Items.branch | Sort-Object -Unique) | Should -Be @('dev', 'main', 'stage')
    }
    It 'does not list repos on v1 (Gamma) while listing the v2 ones' {
        $script:Rep.Items.Count | Should -BeGreaterThan 0
        @($script:Rep.Items | Where-Object appName -eq 'Alpha') | Should -Not -BeNullOrEmpty
        @($script:Rep.Items | Where-Object appName -eq 'Gamma') | Should -BeNullOrEmpty
        $script:Rep.Output | Should -Not -Match 'Gamma'
    }
}

Describe 'Get-V2ImpactReport - without -CandidateHash nothing is stale' {
    BeforeAll { $script:Rep = Get-Report $null }
    It 'Beta app stage uses its (old-hash) row: fail' { Verdict $script:Rep 'Beta' 'app' 'stage' | Should -BeExactly 'fail' }
    It 'Epsilon app main = fail' { Verdict $script:Rep 'Epsilon' 'app' 'main' | Should -BeExactly 'fail' }
    It 'other verdicts are unchanged (Alpha app main fail)' { Verdict $script:Rep 'Alpha' 'app' 'main' | Should -BeExactly 'fail' }
}

Describe 'Get-V2ImpactReport - Markdown output' {
    BeforeAll {
        $script:Run = Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = $script:Rows; CandidateHash = 'NEWHASH' }
        $script:Lines = @($script:Run.Output -split "`r?`n")
    }
    It 'exits 0' { $script:Run.ExitCode | Should -Be 0 -Because $script:Run.Output }
    It 'is a Markdown table (header separator line)' {
        @($script:Lines | Where-Object { $_ -match '^\s*\|?\s*:?-{3,}' }).Count | Should -BeGreaterThan 0
    }
    It 'has a table line per app/kind/branch carrying the verdict' {
        $l = @($script:Lines | Where-Object { $_ -match 'Alpha' -and $_ -match '\bapp\b' -and $_ -match '\bmain\b' })
        $l.Count | Should -Be 1
        $l[0] | Should -Match '\bfail\b'
        $s = @($script:Lines | Where-Object { $_ -match 'Beta' -and $_ -match '\bapp\b' -and $_ -match '\bstage\b' })
        $s.Count | Should -Be 1
        $s[0] | Should -Match 'not evaluated \(stale\)'
        $i = @($script:Lines | Where-Object { $_ -match 'Alpha' -and $_ -match '\btest\b' -and $_ -match '\bstage\b' })
        $i.Count | Should -Be 1
        $i[0] | Should -Match '\bidentical\b'
    }
}

Describe 'Get-V2ImpactReport - unreadable input' {
    It 'exits 1 on a missing rows file' {
        (Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = (Join-Path $TestDrive 'nope.json') }).ExitCode | Should -Be 1
    }
    It 'exits 1 on invalid JSON' {
        (Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = $script:Broken }).ExitCode | Should -Be 1
    }
    It 'exits 0 and reports nothing for an empty row array' {
        $f = Join-Path $TestDrive 'empty.json'; '[]' | Set-Content $f
        $r = Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = $f }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
}

Describe 'Get-V2ImpactReport - app and test rows carry different candidate hashes' {
    BeforeAll {
        function NewRow($kind, $hash, $fail) {
            [ordered]@{ TimeGenerated = '2026-11-12T08:00:00Z'; OperationName = 'CI Preview Compile'
                Properties = [ordered]@{ appName = 'Pair'; appKind = $kind; sourceBranch = 'refs/heads/main'; analyzerStack = 'v2'
                    previewRuleset = 'v2.next'; wouldFailBuild = $fail; status = 'ok'; rulesetHash = $hash } }
        }
        $script:PairRows = Join-Path $TestDrive 'pair-rows.json'
        Write-Json @((NewRow 'app' 'APPHASH' 'true'), (NewRow 'test' 'TESTHASH' 'false')) $script:PairRows
        $out = Join-Path $TestDrive 'pair-report.json'
        $script:PairRun = Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = $script:PairRows; OutPath = $out; CandidateHash = @('APPHASH', 'TESTHASH') }
        $script:PairItems = @(Get-Content -Raw $out | ConvertFrom-Json)
    }
    It 'accepts a hash set: app row (APPHASH) and test row (TESTHASH) are both evaluated, neither stale' {
        $script:PairRun.ExitCode | Should -Be 0 -Because $script:PairRun.Output
        ($script:PairItems | Where-Object { $_.appKind -eq 'app' -and $_.branch -eq 'main' }).verdict | Should -BeExactly 'fail'
        ($script:PairItems | Where-Object { $_.appKind -eq 'test' -and $_.branch -eq 'main' }).verdict | Should -BeExactly 'pass'
    }
    It 'a row whose hash is not in the set is still stale' {
        $out = Join-Path $TestDrive 'pair-report2.json'
        $r = Invoke-Tool -Script $script:Tool -Arguments @{ RowsPath = $script:PairRows; OutPath = $out; CandidateHash = @('APPHASH', 'OTHER') }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $items = @(Get-Content -Raw $out | ConvertFrom-Json)
        ($items | Where-Object { $_.appKind -eq 'app' -and $_.branch -eq 'main' }).verdict | Should -BeExactly 'fail'
        ($items | Where-Object { $_.appKind -eq 'test' -and $_.branch -eq 'main' }).verdict | Should -BeExactly 'not evaluated (stale)'
    }
}
