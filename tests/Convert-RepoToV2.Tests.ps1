# Tests for tools/Convert-RepoToV2.ps1 (AC14, M3, M11, AC3).
#
# Assumed contract (plan 1.1/1.2), in addition to the task statement:
#   Convert-RepoToV2.ps1 -RepoRoot <dir> [-WhatIf]; run as child pwsh; exit 0 = ok, 1 = problems.
#   Layout: <root>/app and optional <root>/test, each with .vscode/settings.json and .codeanalyzer/*.ruleset.json.
#   - Maps come from LinterCop-to-ALCops.json (repo root of BCRuleset); canonical lists from v2/SOCITAS.analyzers.v2.json.
#   - A one-to-many mapping yields one rule per target id (same action/justification); ids are de-duplicated,
#     so LC0010 -> LC0008,LC0010 stays stable on re-run (idempotence).
#   - Ruleset path in app/.vscode/settings.json stays the local file; only includedRuleSets[].path is rewritten
#     (https://socitas-gmbh.github.io/BCRuleset/SOCITAS[.test].ruleset.json -> ...ruleset.v2.json).
#   - Pragma lines: only the id list of '#pragma warning disable|restore' is mapped; ids are compared as sets here,
#     separator style is the implementer's choice. Comments and other lines are byte-for-byte unchanged.
#   - Unmapped ids (map is [] or id absent from the map, but an LC/SO id) are REPORTED in the output (id named),
#     left as-is, and the exit code stays 0: they are the developer's to fix, the script never edits code beyond ids.
#   - scripts/settings.json (rulesetFile) is a pointer to the local ruleset file, which keeps its name: file unchanged.
#   - -WhatIf: no file changes; output names each file that would change (by file name).

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Tool = Join-Path $PSScriptRoot '../tools/Convert-RepoToV2.ps1'
    $script:Fx = Join-Path $PSScriptRoot 'fixtures/v1repo'
    $script:Canon = Get-Content -Raw (Join-Path $PSScriptRoot '../v2/SOCITAS.analyzers.v2.json') | ConvertFrom-Json

    function New-Repo([switch]$NoTest) {
        $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -Recurse -Path $script:Fx -Destination $d
        if ($NoTest) { Remove-Item -Recurse -Force (Join-Path $d 'test') }
        $d
    }
    function Convert-Repo([string]$Root, [switch]$WhatIf) {
        # Invoke-Tool cannot pass a bare switch, so -WhatIf is invoked directly.
        if ($WhatIf) {
            $out = & pwsh -NoProfile -NonInteractive -Command "& '$($script:Tool -replace "'","''")' -RepoRoot '$($Root -replace "'","''")' -WhatIf; exit `$LASTEXITCODE" 2>&1 | Out-String
            return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
        }
        Invoke-Tool -Script $script:Tool -Arguments @{ RepoRoot = $Root }
    }
    function Get-Hashes([string]$Root) {
        $h = @{}
        Get-ChildItem -Recurse -File -Force $Root | ForEach-Object {
            $h[$_.FullName.Substring($Root.Length)] = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        }
        $h
    }
    function Read-Json([string]$Path) { Get-Content -Raw $Path | ConvertFrom-Json }
    function Pragma-Ids([string]$File, [string]$Kind) {
        $ids = foreach ($l in (Get-Content $File)) {
            if ($l -match "^\s*#pragma warning $Kind\s+(.+?)\s*$") { ($Matches[1] -split '[,\s]+' | Where-Object { $_ }) ; '|' }
        }
        # returns array of per-line id arrays
        $lines = @(); $cur = @()
        foreach ($i in $ids) { if ($i -eq '|') { $lines += , $cur; $cur = @() } else { $cur += $i } }
        , $lines
    }
}

Describe 'Convert-RepoToV2.ps1' {
    It 'tool script exists' { $script:Tool | Should -Exist }

    Context 'full app + test migration' {
        BeforeEach {
            $script:R = New-Repo
            $script:Res = Convert-Repo $script:R
        }

        It 'exits 0' { $script:Res.ExitCode | Should -Be 0 }

        It 'app analyzers = MS markers kept + canonical appAnalyzers, no v1 cops' {
            $s = Read-Json (Join-Path $script:R 'app/.vscode/settings.json')
            $list = @($s.'al.codeAnalyzers')
            $list | Should -Contain '${CodeCop}'
            $list | Should -Contain '${UICop}'
            $list | Should -Not -Contain '${analyzerFolder}BusinessCentral.LinterCop.dll'
            $list | Should -Not -Contain '${analyzerFolder}BusinessCentral.SocitasCop.dll'
            $rest = @($list | Where-Object { $_ -notin @('${CodeCop}', '${UICop}') })
            ($rest | Sort-Object) | Should -Be (@($script:Canon.appAnalyzers) | Sort-Object)
            $s.'al.enableCodeAnalysis' | Should -BeTrue
            $s.'al.ruleSetPath' | Should -Be '.codeanalyzer/SOCITAS.ruleset.json'
        }

        It 'test analyzers = marker kept + canonical testAnalyzers' {
            $s = Read-Json (Join-Path $script:R 'test/.vscode/settings.json')
            $list = @($s.'al.codeAnalyzers')
            $list | Should -Contain '${CodeCop}'
            $list | Should -Not -Contain '${analyzerFolder}BusinessCentral.SocitasCop.dll'
            $rest = @($list | Where-Object { $_ -ne '${CodeCop}' })
            ($rest | Sort-Object) | Should -Be (@($script:Canon.testAnalyzers) | Sort-Object)
            $list | Should -Contain '${analyzerFolder}BusinessCentral.TestCop.dll'
        }

        It 'app ruleset include points at v2, other include and its action kept' {
            $rs = Read-Json (Join-Path $script:R 'app/.codeanalyzer/SOCITAS.ruleset.json')
            $paths = @($rs.includedRuleSets | ForEach-Object { $_.path })
            $paths | Should -Contain 'https://socitas-gmbh.github.io/BCRuleset/v2/SOCITAS.ruleset.v2.json'
            $paths | Should -Not -Contain 'https://socitas-gmbh.github.io/BCRuleset/SOCITAS.ruleset.json'
            $other = $rs.includedRuleSets | Where-Object { $_.path -eq 'https://example.com/other.ruleset.json' }
            $other | Should -Not -BeNullOrEmpty
            $other.action | Should -Be 'Warning'
            ($rs.includedRuleSets | Where-Object { $_.path -like '*v2/SOCITAS.ruleset.v2.json' }).action | Should -Be 'Default'
        }

        It 'test ruleset include points at the test v2 ruleset' {
            $rs = Read-Json (Join-Path $script:R 'test/.codeanalyzer/SOCITAS.test.ruleset.json')
            $paths = @($rs.includedRuleSets | ForEach-Object { $_.path })
            $paths | Should -Contain 'https://socitas-gmbh.github.io/BCRuleset/v2/SOCITAS.test.ruleset.v2.json'
            $paths | Should -Not -Contain 'https://socitas-gmbh.github.io/BCRuleset/SOCITAS.test.ruleset.json'
        }

        It 'result is detected as v2 (path matches SOCITAS.(test.)ruleset.v2.json)' {
            foreach ($f in 'app/.codeanalyzer/SOCITAS.ruleset.json', 'test/.codeanalyzer/SOCITAS.test.ruleset.json') {
                $rs = Read-Json (Join-Path $script:R $f)
                @($rs.includedRuleSets | Where-Object { $_.path -match 'SOCITAS\.(test\.)?ruleset\.v2\.json$' }).Count | Should -BeGreaterThan 0
            }
        }

        It 'local app rules: one-to-many LC0010 -> LC0008 + LC0010 with same action, SO0001 -> SC0044, AA untouched' {
            $rs = Read-Json (Join-Path $script:R 'app/.codeanalyzer/SOCITAS.ruleset.json')
            $by = @{}; foreach ($r in $rs.rules) { $by[$r.id] = $r }
            $by['LC0008'].action | Should -Be 'Warning'
            $by['LC0010'].action | Should -Be 'Warning'
            $by.ContainsKey('SO0001') | Should -BeFalse
            $by['SC0044'].action | Should -Be 'None'
            $by['AA0137'].action | Should -Be 'Info'
            @($rs.rules | Where-Object { $_.id -eq 'LC0010' }).Count | Should -Be 1
        }

        It 'unmapped LC id (no counterpart) is left as-is in the ruleset' {
            $rs = Read-Json (Join-Path $script:R 'app/.codeanalyzer/SOCITAS.ruleset.json')
            ($rs.rules | Where-Object { $_.id -eq 'LC0029' }).action | Should -Be 'None'
        }

        It 'local test rules mapped (LC0009 -> LC0007 + LC0009)' {
            $rs = Read-Json (Join-Path $script:R 'test/.codeanalyzer/SOCITAS.test.ruleset.json')
            $by = @{}; foreach ($r in $rs.rules) { $by[$r.id] = $r.action }
            $by['LC0007'] | Should -Be 'Info'
            $by['LC0009'] | Should -Be 'Info'
        }

        It 'app pragma id lists are mapped, restore too' {
            $f = Join-Path $script:R 'app/src/Cust.Codeunit.al'
            $dis = Pragma-Ids $f 'disable'
            ($dis[0] | Sort-Object -Unique) | Should -Be @('AA0137', 'LC0008', 'LC0010')
            $res = Pragma-Ids $f 'restore'
            ($res[0] | Sort-Object -Unique) | Should -Be @('LC0008', 'LC0010')
        }

        It 'test pragma ids mapped (LC0009 -> LC0007,LC0009; SO0002 -> SC0045)' {
            $dis = Pragma-Ids (Join-Path $script:R 'test/src/CustTest.Codeunit.al') 'disable'
            ($dis[0] | Sort-Object -Unique) | Should -Be @('LC0007', 'LC0009', 'SC0045')
        }

        It 'ordinary comments and all other code lines are untouched' {
            $new = Get-Content (Join-Path $script:R 'app/src/Cust.Codeunit.al')
            $new | Should -Contain '    // Mentions LC0010 in an ordinary comment, must stay untouched.'
            $old = Get-Content (Join-Path $script:Fx 'app/src/Cust.Codeunit.al')
            $strip = { param($l) @($l | Where-Object { $_ -notmatch '^\s*#pragma warning' }) }
            (& $strip $new) | Should -Be (& $strip $old)
            $tnew = Get-Content (Join-Path $script:R 'test/src/CustTest.Codeunit.al')
            $tnew | Should -Contain '    // Test file, comment mentions LC0009 only here.'
        }

        It 'unmapped id LC0029 is reported in the output, exit stays 0, pragma left as-is' {
            $script:Res.Output | Should -Match 'LC0029'
            $script:Res.ExitCode | Should -Be 0
            ((Get-Content (Join-Path $script:R 'app/src/Cust.Codeunit.al')) -join "`n") | Should -Match '#pragma warning disable LC0029'
        }

        It 'scripts/settings.json is not broken (still valid, ruleset file still exists)' {
            $s = Read-Json (Join-Path $script:R 'scripts/settings.json')
            Join-Path $script:R 'app' $s.rulesetFile | Should -Exist
        }
    }

    Context 'idempotence' {
        It 'a second run changes no file and exits 0' {
            $r = New-Repo
            (Convert-Repo $r).ExitCode | Should -Be 0
            $h1 = Get-Hashes $r
            $res2 = Convert-Repo $r
            $res2.ExitCode | Should -Be 0
            $h2 = Get-Hashes $r
            $h2.Keys.Count | Should -Be $h1.Keys.Count
            foreach ($k in $h1.Keys) { $h2[$k] | Should -Be $h1[$k] -Because $k }
        }

        It 'first run really changed something (guards the hash comparison)' {
            $r = New-Repo
            $before = Get-Hashes $r
            Convert-Repo $r | Out-Null
            $after = Get-Hashes $r
            @($before.Keys | Where-Object { $before[$_] -ne $after[$_] }).Count | Should -BeGreaterThan 3
        }
    }

    Context '-WhatIf' {
        It 'changes no file and lists the files it would change' {
            $r = New-Repo
            $before = Get-Hashes $r
            $res = Convert-Repo $r -WhatIf
            $res.ExitCode | Should -Be 0
            $after = Get-Hashes $r
            foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because $k }
            $after.Keys.Count | Should -Be $before.Keys.Count
            foreach ($n in 'settings.json', 'SOCITAS.ruleset.json', 'SOCITAS.test.ruleset.json', 'Cust.Codeunit.al', 'CustTest.Codeunit.al') {
                $res.Output | Should -Match ([regex]::Escape($n))
            }
        }
    }

    Context 'repo without test/' {
        It 'app-only migration succeeds' {
            $r = New-Repo -NoTest
            $res = Convert-Repo $r
            $res.ExitCode | Should -Be 0
            $rs = Read-Json (Join-Path $r 'app/.codeanalyzer/SOCITAS.ruleset.json')
            @($rs.includedRuleSets | Where-Object { $_.path -match 'SOCITAS\.(test\.)?ruleset\.v2\.json$' }).Count | Should -Be 1
            (Test-Path (Join-Path $r 'test')) | Should -BeFalse
        }
    }

    Context 'PS 5.1 compatibility' {
        It 'source has no ??, ?., ternary, ?[] or -AsHashtable' {
            $script:Tool | Should -Exist
            $tokens = $null; $errs = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($script:Tool, [ref]$tokens, [ref]$errs)
            $errs | Should -BeNullOrEmpty
            $bad = @($tokens | Where-Object { $_.Kind.ToString() -in 'QuestionQuestion', 'QuestionQuestionEquals', 'QuestionDot', 'QuestionMark', 'QuestionLBracket' })
            $bad.Count | Should -Be 0
            @($ast.FindAll({ param($n) $n.GetType().Name -eq 'TernaryExpressionAst' }, $true)).Count | Should -Be 0
            (Get-Content -Raw $script:Tool) | Should -Not -Match '-AsHashtable'
        }
    }
}

# M3/AC3 container path: scripts/settings.json `rulesetFile` (top level and inside versions[]) can point at a ruleset that is NOT
# al.ruleSetPath. The container path compiles with that file (Join-Path <repo root> <rulesetFile>), so it must be migrated too.
Describe 'Convert-RepoToV2.ps1 - scripts/settings.json rulesetFile' {
    BeforeAll {
        function New-ContainerRepo {
            $d = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            Copy-Item -Recurse -Path (Join-Path $PSScriptRoot 'fixtures/v1repo') -Destination $d
            $rs = @'
{
  "name": "container ruleset",
  "includedRuleSets": [
    { "action": "Default", "path": "https://socitas-gmbh.github.io/BCRuleset/SOCITAS.ruleset.json" }
  ],
  "rules": [
    { "id": "LC0010", "action": "Warning", "justification": "container one-to-many" }
  ]
}
'@
            Set-Content -LiteralPath (Join-Path $d 'app/.codeanalyzer/ci.ruleset.json') -Value $rs -Encoding utf8
            Set-Content -LiteralPath (Join-Path $d 'app/.codeanalyzer/ci-next.ruleset.json') -Value $rs -Encoding utf8
            $st = '{ "rulesetFile": "app/.codeanalyzer/ci.ruleset.json", "versions": [ { "version": "ci", "rulesetFile": "app/.codeanalyzer/ci-next.ruleset.json" } ] }'
            Set-Content -LiteralPath (Join-Path $d 'scripts/settings.json') -Value $st -Encoding utf8
            $d
        }
    }

    It 'migrates the rulesetFile rulesets (top level and versions[]) although al.ruleSetPath points elsewhere' {
        $r = New-ContainerRepo
        $res = Invoke-Tool -Script $script:Tool -Arguments @{ RepoRoot = $r }
        $res.ExitCode | Should -Be 0 -Because $res.Output
        foreach ($n in 'ci', 'ci-next') {
            $j = Get-Content -Raw (Join-Path $r "app/.codeanalyzer/$n.ruleset.json") | ConvertFrom-Json
            @($j.includedRuleSets)[0].path | Should -Match '/v2/SOCITAS\.ruleset\.v2\.json$' -Because $n
            @($j.rules.id) | Should -Contain 'LC0008' -Because $n
        }
    }

    It 'leaves scripts/settings.json itself unchanged and is idempotent' {
        $r = New-ContainerRepo
        $sh = (Get-FileHash (Join-Path $r 'scripts/settings.json')).Hash
        (Invoke-Tool -Script $script:Tool -Arguments @{ RepoRoot = $r }).ExitCode | Should -Be 0
        (Get-FileHash (Join-Path $r 'scripts/settings.json')).Hash | Should -Be $sh
        $h1 = @{}; Get-ChildItem -Recurse -File -Force $r | ForEach-Object { $h1[$_.FullName] = (Get-FileHash $_.FullName).Hash }
        $res2 = Invoke-Tool -Script $script:Tool -Arguments @{ RepoRoot = $r }
        $res2.ExitCode | Should -Be 0 -Because $res2.Output
        foreach ($k in $h1.Keys) { (Get-FileHash $k).Hash | Should -Be $h1[$k] -Because $k }
    }

    It '-WhatIf names the rulesetFile ruleset and writes nothing' {
        $r = New-ContainerRepo
        $before = (Get-FileHash (Join-Path $r 'app/.codeanalyzer/ci.ruleset.json')).Hash
        $out = & pwsh -NoProfile -NonInteractive -Command "& '$($script:Tool -replace "'","''")' -RepoRoot '$($r -replace "'","''")' -WhatIf; exit `$LASTEXITCODE" 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'ci\.ruleset\.json'
        (Get-FileHash (Join-Path $r 'app/.codeanalyzer/ci.ruleset.json')).Hash | Should -Be $before
    }
}
