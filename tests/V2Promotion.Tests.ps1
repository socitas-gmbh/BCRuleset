# AC10 (M6) - tools/Test-V2Promotion.ps1 -BaseRef <ref> [-RepoRoot <dir>]: the PR gate for non-next v2 files.
#
# Contract assumptions (beyond the task contract):
#  - The compared state is BaseRef vs HEAD (the tests commit the change, so the working tree equals HEAD).
#  - "Equals next as of BaseRef" = content of <name>.v2.json at HEAD == content of <name>.v2.next.json at BaseRef,
#    compared per pair (ruleset, test ruleset, analyzers); a next file changed in the same PR does not count.
#  - Offending file names are printed on stdout/stderr (exit 1); exit 0 otherwise.
#  - Only the 5 governed files matter; any other changed file is irrelevant.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $script:Tool = Join-Path $script:Root 'tools/Test-V2Promotion.ps1'

    $script:Pairs = @('SOCITAS.ruleset', 'SOCITAS.test.ruleset', 'SOCITAS.analyzers')
    function Invoke-G($repo, [string[]]$a) {
        $o = & git -C $repo -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false @a 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "git $($a -join ' ') failed: $o" }
    }
    function Put($repo, $name, $text) { $p = Join-Path $repo $name; [void][IO.Directory]::CreateDirectory((Split-Path -Parent $p)); [IO.File]::WriteAllText($p, "$text`n") }
    function Get-Text($repo, $name) { Get-Content -Raw (Join-Path $repo $name) }
    # Base state: v1 frozen, v2 = 'cur', next = 'proposal' (a proposal merged earlier), tagged 'base'.
    function New-Repo {
        $repo = Join-Path $TestDrive ('repo-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $repo | Out-Null
        Invoke-G $repo @('init', '-q', '-b', 'main')
        Put $repo 'README.md' 'readme'
        Put $repo 'SOCITAS.ruleset.json' 'v1 app'
        Put $repo 'SOCITAS.test.ruleset.json' 'v1 test'
        foreach ($p in $script:Pairs) {
            Put $repo "v2/$p.v2.json" "$p current"
            Put $repo "v2/next/$p.v2.next.json" "$p proposal"
        }
        Invoke-G $repo @('add', '-A'); Invoke-G $repo @('commit', '-q', '-m', 'base'); Invoke-G $repo @('tag', 'base')
        $repo
    }
    function Invoke-Gate($repo) {
        Invoke-G $repo @('add', '-A'); Invoke-G $repo @('commit', '-q', '--allow-empty', '-m', 'change')
        Invoke-Tool -Script $script:Tool -Arguments @{ BaseRef = 'base'; RepoRoot = $repo }
    }
}

Describe 'Test-V2Promotion - passes' {
    It 'exits 0 when no v1/v2 file changed' {
        $repo = New-Repo; Put $repo 'README.md' 'changed'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'exits 0 when nothing changed at all' {
        $r = Invoke-Gate (New-Repo)
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'exits 0 for a proposal: only *.v2.next.json changed (<p>)' -ForEach @(
        @{ p = 'SOCITAS.ruleset' }, @{ p = 'SOCITAS.test.ruleset' }, @{ p = 'SOCITAS.analyzers' }) {
        $repo = New-Repo; Put $repo "v2/next/$p.v2.next.json" "$p proposal 2"
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'exits 0 for a promotion: <p>.v2.json now equals <p>.v2.next.json of the base' -ForEach @(
        @{ p = 'SOCITAS.ruleset' }, @{ p = 'SOCITAS.test.ruleset' }, @{ p = 'SOCITAS.analyzers' }) {
        $repo = New-Repo; Put $repo "v2/$p.v2.json" (Get-Text $repo "v2/next/$p.v2.next.json").TrimEnd()
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'exits 0 for a promotion of all three files at once' {
        $repo = New-Repo
        foreach ($p in $script:Pairs) { Put $repo "v2/$p.v2.json" (Get-Text $repo "v2/next/$p.v2.next.json").TrimEnd() }
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
    It 'exits 0 for a promotion that also proposes a new next in the same PR (compared as of BaseRef)' {
        $repo = New-Repo
        Put $repo 'v2/SOCITAS.ruleset.v2.json' (Get-Text $repo 'v2/next/SOCITAS.ruleset.v2.next.json').TrimEnd()
        Put $repo 'v2/next/SOCITAS.ruleset.v2.next.json' 'SOCITAS.ruleset proposal 3'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
}

Describe 'Test-V2Promotion - direct edits fail' {
    It 'exits 1 naming <f> when it is changed to something that is not the base next' -ForEach @(
        @{ f = 'v2/SOCITAS.ruleset.v2.json'; p = 'SOCITAS.ruleset' },
        @{ f = 'v2/SOCITAS.test.ruleset.v2.json'; p = 'SOCITAS.test.ruleset' },
        @{ f = 'v2/SOCITAS.analyzers.v2.json'; p = 'SOCITAS.analyzers' }) {
        $repo = New-Repo; Put $repo $f 'hand edit'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match ([regex]::Escape($f))
    }
    It 'exits 1 when v2 equals a next that was changed in the same PR (not the base next)' {
        $repo = New-Repo
        Put $repo 'v2/next/SOCITAS.ruleset.v2.next.json' 'sneaky'
        Put $repo 'v2/SOCITAS.ruleset.v2.json' 'sneaky'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match ([regex]::Escape('v2/SOCITAS.ruleset.v2.json'))
    }
    It 'exits 1 when v2 equals the next of a DIFFERENT pair' {
        $repo = New-Repo
        Put $repo 'v2/SOCITAS.ruleset.v2.json' (Get-Text $repo 'v2/next/SOCITAS.analyzers.v2.next.json').TrimEnd()
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
    }
    It 'exits 1 for the direct edit even when a valid promotion of another file is in the same PR, naming only the edited one' {
        $repo = New-Repo
        Put $repo 'v2/SOCITAS.analyzers.v2.json' (Get-Text $repo 'v2/next/SOCITAS.analyzers.v2.next.json').TrimEnd()
        Put $repo 'v2/SOCITAS.test.ruleset.v2.json' 'hand edit'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match ([regex]::Escape('v2/SOCITAS.test.ruleset.v2.json'))
        $r.Output | Should -Not -Match ([regex]::Escape('v2/SOCITAS.analyzers.v2.json'))
    }
}

Describe 'Test-V2Promotion - v1 is frozen' {
    It 'exits 1 naming <f> when it changed' -ForEach @(
        @{ f = 'SOCITAS.ruleset.json' }, @{ f = 'SOCITAS.test.ruleset.json' }) {
        $repo = New-Repo; Put $repo $f 'v1 changed'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
        $r.Output | Should -Match ([regex]::Escape($f))
    }
    It 'exits 1 when a v1 change rides along with an otherwise valid proposal' {
        $repo = New-Repo
        Put $repo 'v2/next/SOCITAS.ruleset.v2.next.json' 'proposal 2'
        Put $repo 'SOCITAS.ruleset.json' 'v1 changed'
        $r = Invoke-Gate $repo
        $r.ExitCode | Should -Be 1 -Because $r.Output
    }
}
