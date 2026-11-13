# Acceptance checks on the REAL committed files (AC5 pins, AC6, AC8, AC13).
#
# Assumed inventory shape (plan 1.1): { "analyzers": { "<Name>": [ { id, defaultSeverity, title } ] } }
#   App analyzers = every analyzer key except "TestCop"; the test ruleset covers all keys.
#   SocitasCopV2 is the key whose name matches 'SocitasCopV2'; TestCop the key matching 'TestCop'.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    $script:Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    function P($n) { Join-Path $script:Root $n }
    function Load($n) { Get-Content -Raw (P $n) -ErrorAction Stop | ConvertFrom-Json }
    function RuleIds($n) { @((Load $n).rules | ForEach-Object id) }
    function InvIds([scriptblock]$Filter) {
        $inv = Load 'v2/rule-inventory.json'
        $ids = foreach ($prop in $inv.analyzers.PSObject.Properties) {
            if (& $Filter $prop.Name) { $prop.Value | ForEach-Object id }
        }
        @($ids)
    }
    $script:AppFilter = { param($n) $n -notmatch 'TestCop' }
    $script:AllFilter = { param($n) $true }
}

Describe 'v2 inventory' {
    It 'exists' { P 'v2/rule-inventory.json' | Should -Exist }

    It 'lists exactly the SocitasCopV2 ids of the pinned release (v1.0.0 DiagnosticIds.cs: SC0001..SC0045, next free SC0046)' {
        $inv = Load 'v2/rule-inventory.json'
        $key = $inv.analyzers.PSObject.Properties.Name | Where-Object { $_ -match 'SocitasCopV2' }
        $key | Should -Not -BeNullOrEmpty
        $ids = @($inv.analyzers.$key | ForEach-Object id)
        $expected = 1..45 | ForEach-Object { 'SC{0:D4}' -f $_ }
        @(Compare-Object $expected $ids) | Should -BeNullOrEmpty
    }

    It 'lists TestCop id ST0001' {
        $inv = Load 'v2/rule-inventory.json'
        $key = $inv.analyzers.PSObject.Properties.Name | Where-Object { $_ -match 'TestCop' }
        $key | Should -Not -BeNullOrEmpty
        @($inv.analyzers.$key | ForEach-Object id) | Should -Contain 'ST0001'
    }

    It 'has id, defaultSeverity and title on every entry' {
        $inv = Load 'v2/rule-inventory.json'
        @($inv.analyzers.PSObject.Properties).Count | Should -BeGreaterThan 0
        foreach ($prop in $inv.analyzers.PSObject.Properties) {
            foreach ($e in $prop.Value) {
                $e.id | Should -Not -BeNullOrEmpty
                $e.defaultSeverity | Should -Not -BeNullOrEmpty -Because "$($prop.Name)/$($e.id)"
                $e.PSObject.Properties.Name | Should -Contain 'title'
            }
        }
    }
}

Describe 'AC8 - v2 app ruleset covers exactly the app analyzers' {
    It 'v2/SOCITAS.ruleset.v2.json exists' { P 'v2/SOCITAS.ruleset.v2.json' | Should -Exist }

    It 'has the same id set as the inventory (MS cops, ALCops, SocitasCopV2), no duplicates, every action set' {
        $rules = (Load 'v2/SOCITAS.ruleset.v2.json').rules
        $ids = @($rules | ForEach-Object id)
        @($ids | Group-Object | Where-Object Count -gt 1 | ForEach-Object Name) | Should -BeNullOrEmpty
        $expected = InvIds $script:AppFilter
        $expected.Count | Should -BeGreaterThan 52
        @(Compare-Object ($expected | Sort-Object -Unique) ($ids | Sort-Object -Unique)) | Should -BeNullOrEmpty
        @($rules | Where-Object { -not $_.action }) | Should -BeNullOrEmpty
    }

    It 'the coverage tool exits 0 on it (app analyzers)' {
        $inv = Load 'v2/rule-inventory.json'
        $app = @($inv.analyzers.PSObject.Properties.Name | Where-Object { $_ -notmatch 'TestCop' })
        $r = Invoke-Tool -Script (P 'tools/Test-RulesetCoverage.ps1') -Arguments @{
            RulesetPath = (P 'v2/SOCITAS.ruleset.v2.json'); InventoryPath = (P 'v2/rule-inventory.json'); Analyzers = $app }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
}

Describe 'AC8/AC13 - v2 test ruleset covers app analyzers plus TestCop' {
    It 'v2/SOCITAS.test.ruleset.v2.json exists' { P 'v2/SOCITAS.test.ruleset.v2.json' | Should -Exist }

    It 'has the same id set as the whole inventory incl. ST0001' {
        $ids = RuleIds 'v2/SOCITAS.test.ruleset.v2.json'
        $ids | Should -Contain 'ST0001'
        @($ids | Group-Object | Where-Object Count -gt 1) | Should -BeNullOrEmpty
        @(Compare-Object (InvIds $script:AllFilter | Sort-Object -Unique) ($ids | Sort-Object -Unique)) | Should -BeNullOrEmpty
    }

    It 'the coverage tool exits 0 on it (all analyzers)' {
        $r = Invoke-Tool -Script (P 'tools/Test-RulesetCoverage.ps1') -Arguments @{
            RulesetPath = (P 'v2/SOCITAS.test.ruleset.v2.json'); InventoryPath = (P 'v2/rule-inventory.json') }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'equals the output of Build-TestRuleset.ps1 (never hand-edited)' {
        $out = Join-Path $TestDrive 'generated.test.ruleset.v2.json'
        $r = Invoke-Tool -Script (P 'tools/Build-TestRuleset.ps1') -Arguments @{
            AppRulesetPath = (P 'v2/SOCITAS.ruleset.v2.json'); RelaxationsPath = (P 'v2/test-relaxations.json'); OutPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $norm = { param($f) (Get-Content -Raw $f) -replace "`r`n", "`n" }
        (& $norm $out) | Should -BeExactly (& $norm (P 'v2/SOCITAS.test.ruleset.v2.json'))
    }
}

Describe 'AC13 - test relaxations recorded' {
    It 'v2/test-relaxations.json exists' { P 'v2/test-relaxations.json' | Should -Exist }

    It 'has a record with decision and non-empty reason for every v1 test relaxation' {
        $app = @{}; foreach ($r in (Load 'SOCITAS.ruleset.json').rules) { $app[$r.id] = $r.action }
        $relaxed = foreach ($r in (Load 'SOCITAS.test.ruleset.json').rules) {
            if (-not $app.ContainsKey($r.id) -or $app[$r.id] -ne $r.action) { $r.id }
        }
        @($relaxed).Count | Should -BeGreaterThan 0
        $recs = @(Load 'v2/test-relaxations.json')
        foreach ($id in $relaxed) {
            $rec = @($recs | Where-Object id -eq $id)
            $rec.Count | Should -Be 1 -Because "v1 relaxation $id needs exactly one record"
            $rec[0].decision | Should -BeIn 'kept', 'dropped', 'remapped' -Because $id
            [string]$rec[0].reason | Should -Match '\S' -Because "reason of $id"
        }
    }

    It 'the check tool exits 0 on the real files' {
        $r = Invoke-Tool -Script (P 'tools/Test-TestRelaxations.ps1')
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }
}

Describe 'AC5 - analyzer pins' {
    BeforeAll { $script:Pins = if (Test-Path (P 'v2/SOCITAS.analyzers.v2.json')) { Load 'v2/SOCITAS.analyzers.v2.json' } }

    It 'v2/SOCITAS.analyzers.v2.json exists' { P 'v2/SOCITAS.analyzers.v2.json' | Should -Exist }

    It 'pins alcops 1.3.1, socitasCopV2 1.0.0, testCop 0.1.0 exactly' {
        $script:Pins.alcops | Should -BeExactly '1.3.1'
        $script:Pins.socitasCopV2 | Should -BeExactly '1.0.0'
        $script:Pins.testCop | Should -BeExactly '0.1.0'
    }

    It 'uses plain versions only (no ranges, wildcards or latest)' {
        foreach ($k in 'alcops', 'socitasCopV2', 'testCop') {
            [string]$script:Pins.$k | Should -Match '^\d+\.\d+\.\d+$' -Because $k
        }
    }

    It 'lists analyzers; testAnalyzers = appAnalyzers + TestCop; SocitasCopV2 in app list' {
        @($script:Pins.appAnalyzers) | Should -Contain '${analyzerFolder}BusinessCentral.SocitasCopV2.dll'
        @($script:Pins.testAnalyzers) | Should -Contain '${analyzerFolder}BusinessCentral.TestCop.dll'
        foreach ($a in $script:Pins.appAnalyzers) { @($script:Pins.testAnalyzers) | Should -Contain $a }
        @($script:Pins.appAnalyzers) | Should -Not -Contain '${analyzerFolder}BusinessCentral.TestCop.dll'
    }
}

Describe 'v1 files are frozen (M7)' {
    It '<f> is byte-identical to origin/main' -ForEach @(
        @{ f = 'SOCITAS.ruleset.json' }, @{ f = 'SOCITAS.test.ruleset.json' }) {
        $base = (& git -C $script:Root rev-parse "origin/main:$f" 2>&1 | Out-String).Trim()
        $LASTEXITCODE | Should -Be 0 -Because "origin/main:$f must resolve: $base"
        $now = (& git -C $script:Root hash-object (Join-Path $script:Root $f)).Trim()
        $now | Should -BeExactly $base
    }
}

# ---- AC10 (M6): candidate (next) files -------------------------------------------------------------------------
# Assumptions: the next files sit beside their counterparts; with nothing proposed they are byte-identical (today's state; while a
# proposal is open the identity test is skipped explicitly, the other checks keep applying). The next app ruleset is checked against
# v2/rule-inventory.next.json when it exists (inventory generated for the next pins), else v2/rule-inventory.json.
Describe 'AC10 - candidate files exist and track the current v2 files' {
    BeforeAll {
        $script:NextPairs = @(
            @{ cur = 'v2/SOCITAS.ruleset.v2.json'; next = 'v2/next/SOCITAS.ruleset.v2.next.json' },
            @{ cur = 'v2/SOCITAS.test.ruleset.v2.json'; next = 'v2/next/SOCITAS.test.ruleset.v2.next.json' },
            @{ cur = 'v2/SOCITAS.analyzers.v2.json'; next = 'v2/next/SOCITAS.analyzers.v2.next.json' })
        function NextInventory { if (Test-Path (P 'v2/rule-inventory.next.json')) { 'v2/rule-inventory.next.json' } else { 'v2/rule-inventory.json' } }
    }

    It '<next> exists' -ForEach @(
        @{ next = 'v2/next/SOCITAS.ruleset.v2.next.json' }, @{ next = 'v2/next/SOCITAS.test.ruleset.v2.next.json' }, @{ next = 'v2/next/SOCITAS.analyzers.v2.next.json' }) {
        P $next | Should -Exist
    }

    It '<next> is byte-identical to <cur> when nothing is proposed' -ForEach @(
        @{ cur = 'v2/SOCITAS.ruleset.v2.json'; next = 'v2/next/SOCITAS.ruleset.v2.next.json' },
        @{ cur = 'v2/SOCITAS.test.ruleset.v2.json'; next = 'v2/next/SOCITAS.test.ruleset.v2.next.json' },
        @{ cur = 'v2/SOCITAS.analyzers.v2.json'; next = 'v2/next/SOCITAS.analyzers.v2.next.json' }) {
        P $next | Should -Exist
        $a = (& git hash-object (P $cur)).Trim(); $b = (& git hash-object (P $next)).Trim()
        if ($a -ne $b) { Set-ItResult -Skipped -Because "a proposal is open: $next differs from $cur (promotion gate covers it)"; return }
        $b | Should -BeExactly $a
    }

    It 'the next app ruleset passes the coverage tool against the inventory for the next pins' {
        P 'v2/next/SOCITAS.ruleset.v2.next.json' | Should -Exist
        $invPath = NextInventory
        $inv = Load $invPath
        $app = @($inv.analyzers.PSObject.Properties.Name | Where-Object { $_ -notmatch 'TestCop' })
        $r = Invoke-Tool -Script (P 'tools/Test-RulesetCoverage.ps1') -Arguments @{
            RulesetPath = (P 'v2/next/SOCITAS.ruleset.v2.next.json'); InventoryPath = (P $invPath); Analyzers = $app }
        $r.ExitCode | Should -Be 0 -Because $r.Output
    }

    It 'the next test ruleset equals Build-TestRuleset.ps1 output for the next app ruleset' {
        P 'v2/next/SOCITAS.ruleset.v2.next.json' | Should -Exist
        P 'v2/next/SOCITAS.test.ruleset.v2.next.json' | Should -Exist
        $out = Join-Path $TestDrive 'generated.test.ruleset.v2.next.json'
        $r = Invoke-Tool -Script (P 'tools/Build-TestRuleset.ps1') -Arguments @{
            AppRulesetPath = (P 'v2/next/SOCITAS.ruleset.v2.next.json'); RelaxationsPath = (P 'v2/test-relaxations.json'); OutPath = $out }
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $norm = { param($f) (Get-Content -Raw $f) -replace "`r`n", "`n" }
        (& $norm $out) | Should -BeExactly (& $norm (P 'v2/next/SOCITAS.test.ruleset.v2.next.json'))
    }

    It 'the next analyzers pins keep the canonical shape (plain versions, testAnalyzers = appAnalyzers + TestCop)' {
        P 'v2/next/SOCITAS.analyzers.v2.next.json' | Should -Exist
        $n = Load 'v2/next/SOCITAS.analyzers.v2.next.json'
        foreach ($k in 'alcops', 'socitasCopV2', 'testCop') { [string]$n.$k | Should -Match '^\d+\.\d+\.\d+$' -Because $k }
        foreach ($a in $n.appAnalyzers) { @($n.testAnalyzers) | Should -Contain $a }
        @($n.testAnalyzers) | Should -Contain '${analyzerFolder}BusinessCentral.TestCop.dll'
        @($n.appAnalyzers) | Should -Not -Contain '${analyzerFolder}BusinessCentral.TestCop.dll'
    }
}

# ---- AC6 - the next-inventory check must not pass a pin bump trivially ----------------------------------------
# The inventory records the pins it was generated from ("pins": alCompiler/alcops/socitasCopV2/testCop). The next coverage checks
# use an inventory whose provenance equals the next pins - never the current inventory as a fallback for different pins.
Describe 'AC6 - inventory provenance matches the pins it is used for' {
    BeforeAll {
        $script:PinKeys = 'alCompiler', 'alcops', 'socitasCopV2', 'testCop'
        $script:PinsCur = Load 'v2/SOCITAS.analyzers.v2.json'
        $script:PinsNext = Load 'v2/next/SOCITAS.analyzers.v2.next.json'
        function PinsEqual($a, $b) { foreach ($k in $script:PinKeys) { if ([string]$a.$k -ne [string]$b.$k) { return $false } }; $true }
        function PinsText($o) { ($script:PinKeys | ForEach-Object { "$_=$($o.$_)" }) -join ' ' }
    }

    It 'v2/rule-inventory.json records the pins of v2/SOCITAS.analyzers.v2.json' {
        $inv = Load 'v2/rule-inventory.json'
        $inv.PSObject.Properties.Name | Should -Contain 'pins'
        PinsText $inv.pins | Should -BeExactly (PinsText $script:PinsCur)
    }

    It 'when the next pins differ from the v2 pins, v2/rule-inventory.next.json exists and records exactly the next pins' {
        if (PinsEqual $script:PinsCur $script:PinsNext) { Set-ItResult -Skipped -Because 'next pins equal the v2 pins'; return }
        P 'v2/rule-inventory.next.json' | Should -Exist
        $n = Load 'v2/rule-inventory.next.json'
        $n.PSObject.Properties.Name | Should -Contain 'pins'
        PinsText $n.pins | Should -BeExactly (PinsText $script:PinsNext)
    }

    It 'when the next pins equal the v2 pins, the inventory used for the next coverage records the next pins' {
        if (-not (PinsEqual $script:PinsCur $script:PinsNext)) { Set-ItResult -Skipped -Because 'next pins differ from the v2 pins'; return }
        $inv = Load 'v2/rule-inventory.json'
        $inv.PSObject.Properties.Name | Should -Contain 'pins'
        PinsText $inv.pins | Should -BeExactly (PinsText $script:PinsNext)
    }

    It 'the next-coverage workflow steps always regenerate the inventory from the next pins (no fallback to the current one)' {
        $wf = Get-Content -Raw (P '.github/workflows/validate.yml')
        $wf | Should -Match 'Get-RuleInventory\.ps1 -PinsPath v2/next/SOCITAS\.analyzers\.v2\.next\.json'
        $wf | Should -Not -Match 'if \(Test-Path v2/rule-inventory\.next\.json\)'
    }
}
