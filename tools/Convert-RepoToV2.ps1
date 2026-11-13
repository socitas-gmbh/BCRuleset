<#
.SYNOPSIS
  Migrates a SOCITAS AL repo from the v1 analyzer list / ruleset to v2 (ALCops + SocitasCopV2). AC14.

.DESCRIPTION
  For every project under -RepoRoot (a folder with .vscode/settings.json that still carries v1 markers):
    1. al.codeAnalyzers: drops BusinessCentral.LinterCop.dll / BusinessCentral.SocitasCop.dll, keeps ${...Cop}
       markers and unknown entries, appends the canonical v2 list (appAnalyzers, testAnalyzers for test projects).
    2. al.ruleSetPath ruleset: includedRuleSets SOCITAS.ruleset.json -> v2/SOCITAS.ruleset.v2.json and
       SOCITAS.test.ruleset.json -> v2/SOCITAS.test.ruleset.v2.json; local rules[].id mapped via LinterCop-to-ALCops.json
       (one-to-many -> one rule per target, zero targets -> kept and reported).
       The container path compiles with scripts/settings.json `rulesetFile` (top level and inside versions[] / any nested
       object), which may differ from al.ruleSetPath: every ruleset it names that still carries the v1 include (or, when the
       run migrated a v1 project, no v2 include) gets the same ruleset rewrite. settings.json itself is never changed.
    3. .al files: ids inside '#pragma warning disable|restore <ids>' lists are mapped; every other byte is untouched.

  Idempotent: a project that carries no v1 marker (already v2) is left alone, so a rerun changes nothing.
  Never touches anything outside -RepoRoot. Unmapped ids are reported ("left for the developer"), exit stays 0.
  Exit 1 only on real errors (unreadable JSON, unreadable map/pins, missing RepoRoot).

  Test project = folder named test/tests, OR app.json depends on a test framework (Test Runner, Library Assert, Any,
  Library Variable Storage, Permissions Mock, Tests-*), OR its ruleset/ruleSetPath references the v1 test ruleset,
  OR its analyzer list already holds BusinessCentral.TestCop.dll.

  PS 5.1 compatible.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)][string]$RepoRoot,
    [string]$MapPath,
    [string]$PinsPath
)

$ErrorActionPreference = 'Stop'
$BaseUrl = 'https://socitas-gmbh.github.io/BCRuleset'
$ExcludedDirs = @('.git', 'node_modules', '.alpackages', '.netpackages')

$script:Changed = New-Object System.Collections.Generic.List[string]
$script:Unchanged = New-Object System.Collections.Generic.List[string]
$script:Unmapped = New-Object System.Collections.Generic.List[string]
$script:Errors = New-Object System.Collections.Generic.List[string]
$script:Notes = New-Object System.Collections.Generic.List[string]

# ---------------------------------------------------------------- pure helpers

function Read-TextFile {
    param([string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $bom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $start = 0
    if ($bom) { $start = 3 }
    $enc = 'utf8'
    try {
        $strict = New-Object System.Text.UTF8Encoding($false, $true)
        $text = $strict.GetString($bytes, $start, $bytes.Length - $start)
    }
    catch {
        $enc = 'latin1'
        $text = [System.Text.Encoding]::GetEncoding(28591).GetString($bytes, $start, $bytes.Length - $start)
    }
    return [pscustomobject]@{ Text = $text; Bom = $bom; Encoding = $enc }
}

function Write-TextFile {
    param([string]$Path, [string]$Text, [bool]$Bom, [string]$Encoding)
    if ($Encoding -eq 'latin1') { $enc = [System.Text.Encoding]::GetEncoding(28591) }
    else { $enc = New-Object System.Text.UTF8Encoding($false) }
    $body = $enc.GetBytes($Text)
    if ($Bom) { $body = [byte[]](@(0xEF, 0xBB, 0xBF) + $body) }
    [System.IO.File]::WriteAllBytes($Path, $body)
}

function ConvertTo-JsonString {
    param([string]$s)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $s.ToCharArray()) {
        switch ($c) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            "`n" { [void]$sb.Append('\n') }
            "`r" { [void]$sb.Append('\r') }
            "`t" { [void]$sb.Append('\t') }
            "`b" { [void]$sb.Append('\b') }
            "`f" { [void]$sb.Append('\f') }
            default {
                if ([int]$c -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int]$c)) } else { [void]$sb.Append($c) }
            }
        }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Own serializer: ConvertTo-Json differs between PS 5.1 and 7 (indent, ' escapes). LF output, key order kept.
function ConvertTo-JsonText {
    param($Value, [string]$Indent, [int]$Level = 0)
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [string]) { return (ConvertTo-JsonString $Value) }
    if ($Value -is [bool]) { if ($Value) { return 'true' } else { return 'false' } }
    if ($Value -is [datetime]) { return (ConvertTo-JsonString $Value.ToString('o')) }
    if ($Value -is [System.Array]) {
        if ($Value.Count -eq 0) { return '[]' }
        $pad = $Indent * ($Level + 1)
        $items = foreach ($i in $Value) { $pad + (ConvertTo-JsonText -Value $i -Indent $Indent -Level ($Level + 1)) }
        return "[`n" + ($items -join ",`n") + "`n" + ($Indent * $Level) + ']'
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $props = @($Value.PSObject.Properties)
        if ($props.Count -eq 0) { return '{}' }
        $pad = $Indent * ($Level + 1)
        $items = foreach ($p in $props) {
            $pad + (ConvertTo-JsonString $p.Name) + ': ' + (ConvertTo-JsonText -Value $p.Value -Indent $Indent -Level ($Level + 1))
        }
        return "{`n" + ($items -join ",`n") + "`n" + ($Indent * $Level) + '}'
    }
    if ($Value -is [System.ValueType]) {
        return [string]([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
    }
    return (ConvertTo-JsonString ([string]$Value))
}

function Get-LeafName {
    param([string]$Path)
    return [System.IO.Path]::GetFileName(($Path -replace '\\', '/'))
}

function Get-JsonIndentUnit {
    param([string]$Text)
    $m = [regex]::Match($Text, '(?m)^([ \t]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return '  '
}

function Read-JsonFile {
    param([string]$Path)
    $f = Read-TextFile -Path $Path
    try { $obj = ConvertFrom-Json -InputObject $f.Text }
    catch { throw "unreadable JSON '$Path': $($_.Exception.Message)" }
    return [pscustomobject]@{
        Obj = $obj; Bom = $f.Bom; Encoding = $f.Encoding
        Crlf = ($f.Text.Contains("`r`n")); FinalNewline = ($f.Text.EndsWith("`n"))
        Indent = (Get-JsonIndentUnit $f.Text)
    }
}

function Save-JsonFile {
    param([string]$Path, $Doc)
    $text = ConvertTo-JsonText -Value $Doc.Obj -Indent $Doc.Indent
    if ($Doc.FinalNewline) { $text += "`n" }
    if ($Doc.Crlf) { $text = $text -replace "`n", "`r`n" }
    Write-TextFile -Path $Path -Text $text -Bom $Doc.Bom -Encoding $Doc.Encoding
}

function Convert-PragmaIdList {
    param([string]$List, $Map, $Unmapped)
    $parts = $List -split ','
    $modified = $false
    $tokens = New-Object System.Collections.Generic.List[string]
    foreach ($part in $parts) {
        $trimmed = $part.Trim()
        $key = $trimmed.ToUpperInvariant()
        $lead = $part.Substring(0, $part.Length - $part.TrimStart().Length)
        $trail = $part.Substring($part.TrimEnd().Length)
        if ($trimmed -ne '' -and $Map.ContainsKey($key)) {
            $targets = @($Map[$key])
            if ($targets.Count -eq 0) {
                [void]$Unmapped.Add($trimmed)
            }
            elseif (-not ($targets.Count -eq 1 -and $targets[0] -ieq $trimmed)) {
                $sep = $lead
                if ($sep -eq '') { $sep = ' ' }
                $new = @()
                for ($i = 0; $i -lt $targets.Count; $i++) {
                    if ($i -eq 0) { $new += ($lead + $targets[$i]) } else { $new += ($sep + $targets[$i]) }
                }
                [void]$tokens.Add(($new -join ',') + $trail)
                $modified = $true
                continue
            }
        }
        [void]$tokens.Add($part)
    }
    if (-not $modified) { return $List }
    # dedupe by id (case-insensitive) only when this line was rewritten
    $seen = @{}
    $final = New-Object System.Collections.Generic.List[string]
    foreach ($tok in $tokens) {
        foreach ($sub in ($tok -split ',')) {
            $id = $sub.Trim().ToUpperInvariant()
            if ($id -ne '' -and $seen.ContainsKey($id)) { continue }
            if ($id -ne '') { $seen[$id] = $true }
            [void]$final.Add($sub)
        }
    }
    return ($final -join ',')
}

function Convert-PragmaText {
    param([string]$Text, $Map, $Unmapped)
    $rx = [regex]'(?i)(?<=^|\n)([ \t]*#pragma[ \t]+warning[ \t]+(?:disable|restore)[ \t]+)([^\r\n]*)(?=\r?\n|\z)'
    $eval = {
        param($m)
        $rest = $m.Groups[2].Value
        $ci = $rest.IndexOf('//')
        if ($ci -ge 0) { $list = $rest.Substring(0, $ci); $tail = $rest.Substring($ci) }
        else { $list = $rest; $tail = '' }
        $newList = Convert-PragmaIdList -List $list -Map $Map -Unmapped $Unmapped
        return $m.Groups[1].Value + $newList + $tail
    }
    return $rx.Replace($Text, [System.Text.RegularExpressions.MatchEvaluator]$eval)
}

function Test-TestFrameworkDependency {
    param($AppJson)
    if ($null -eq $AppJson) { return $false }
    $deps = $AppJson.PSObject.Properties['dependencies']
    if ($null -eq $deps -or $null -eq $deps.Value) { return $false }
    $testNames = @('Test Runner', 'Library Assert', 'Any', 'Library Variable Storage', 'Permissions Mock',
        'Library - Variable Storage', 'Test Framework')
    foreach ($d in @($deps.Value)) {
        $n = ''
        $p = $d.PSObject.Properties['name']
        if ($p) { $n = [string]$p.Value }
        if ($testNames -contains $n) { return $true }
        if ($n -match '^Tests?-') { return $true }
    }
    return $false
}

# ---------------------------------------------------------------- inputs

function Get-SourceJson {
    param([string]$Path, [string]$Name)
    if ($Path -and (Test-Path -LiteralPath $Path)) { return (Read-JsonFile -Path $Path).Obj }
    if ($Path -and $Path -match '^https?://') { $url = $Path }
    else {
        $local = Join-Path (Join-Path $PSScriptRoot '..') $Name
        if (-not $Path -and (Test-Path -LiteralPath $local)) { return (Read-JsonFile -Path $local).Obj }
        if ($Path) { throw "file not found: $Path" }
        $url = "$BaseUrl/$Name"
    }
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [System.Text.Encoding]::UTF8
        return (ConvertFrom-Json -InputObject $wc.DownloadString($url))
    }
    catch { throw "cannot load '$url': $($_.Exception.Message)" }
}

try {
    if (-not (Test-Path -LiteralPath $RepoRoot -PathType Container)) { throw "RepoRoot not found: $RepoRoot" }
    $root = (Resolve-Path -LiteralPath $RepoRoot).ProviderPath.TrimEnd('\', '/')
    $mapDoc = Get-SourceJson -Path $MapPath -Name 'LinterCop-to-ALCops.json'
    $pins = Get-SourceJson -Path $PinsPath -Name 'v2/SOCITAS.analyzers.v2.json'
    $Map = @{}
    foreach ($p in $mapDoc.map.PSObject.Properties) { $Map[$p.Name.ToUpperInvariant()] = @($p.Value | ForEach-Object { [string]$_ }) }
    $appAnalyzers = @($pins.appAnalyzers | ForEach-Object { [string]$_ })
    $testAnalyzers = @($pins.testAnalyzers | ForEach-Object { [string]$_ })
    if ($appAnalyzers.Count -eq 0 -or $testAnalyzers.Count -eq 0) { throw 'pins file has no appAnalyzers/testAnalyzers' }
}
catch {
    Write-Output "ERROR: $($_.Exception.Message)"
    exit 1
}

function Test-InsideRoot {
    param([string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    $sep = [System.IO.Path]::DirectorySeparatorChar
    return ($full -eq $root -or $full.StartsWith($root + $sep) -or $full.StartsWith($root + '/'))
}

function Find-ProjectFolders {
    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        if (Test-Path -LiteralPath (Join-Path (Join-Path $dir '.vscode') 'settings.json') -PathType Leaf) { [void]$found.Add($dir) }
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            $name = [System.IO.Path]::GetFileName($sub)
            if ($ExcludedDirs -contains $name) { continue }
            if ($name -eq '.vscode') { continue }
            $stack.Push($sub)
        }
    }
    return @($found | Sort-Object)
}

function Find-AlFiles {
    param([string]$Dir)
    $files = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($Dir)
    while ($stack.Count -gt 0) {
        $d = $stack.Pop()
        foreach ($f in [System.IO.Directory]::GetFiles($d, '*.al')) { [void]$files.Add($f) }
        foreach ($sub in [System.IO.Directory]::GetDirectories($d)) {
            if ($ExcludedDirs -contains [System.IO.Path]::GetFileName($sub)) { continue }
            $stack.Push($sub)
        }
    }
    return @($files | Sort-Object)
}

function Complete-Change {
    param([string]$Path, [scriptblock]$Write, [string]$What)
    $rel = $Path
    if ($Path.StartsWith($root)) { $rel = $Path.Substring($root.Length).TrimStart('\', '/') }
    if (-not (Test-InsideRoot $Path)) { throw "refusing to write outside RepoRoot: $Path" }
    if ($PSCmdlet.ShouldProcess($Path, $What)) {
        & $Write
        [void]$script:Changed.Add("changed: $rel ($What)")
    }
    else {
        [void]$script:Changed.Add("would change: $rel ($What)")
    }
}

function Get-ExpandedPath {
    param([string]$Value, [string]$ProjectDir)
    $v = $Value -replace '\$\{workspaceFolder\}', $ProjectDir
    if ([System.IO.Path]::IsPathRooted($v)) { return [System.IO.Path]::GetFullPath($v) }
    return [System.IO.Path]::GetFullPath((Join-Path $ProjectDir $v))
}

function Get-RulesetState {
    # Reads a local ruleset, reports v1/v2 include state. Cached per file.
    param([string]$Path)
    $doc = Read-JsonFile -Path $Path
    $hasV1 = $false; $hasV2 = $false
    $inc = $doc.Obj.PSObject.Properties['includedRuleSets']
    if ($inc -and $inc.Value) {
        foreach ($i in @($inc.Value)) {
            $pp = [string]$i.path
            if ($pp -match '(?i)SOCITAS\.(test\.)?ruleset\.json$') { $hasV1 = $true }
            if ($pp -match '(?i)SOCITAS\.(test\.)?ruleset\.v2\.json$') { $hasV2 = $true }
        }
    }
    return [pscustomobject]@{ Doc = $doc; HasV1 = $hasV1; HasV2 = $hasV2 }
}

function Convert-Ruleset {
    param([string]$Path, $State, [bool]$MapIds)
    $doc = $State.Doc
    $obj = $doc.Obj
    $dirty = $false
    $rel = $Path.Substring($root.Length).TrimStart('\', '/')

    $inc = $obj.PSObject.Properties['includedRuleSets']
    if ($inc -and $inc.Value) {
        foreach ($i in @($inc.Value)) {
            $old = [string]$i.path
            $new = $old -replace '(?i)SOCITAS\.test\.ruleset\.json$', 'v2/SOCITAS.test.ruleset.v2.json'
            $new = $new -replace '(?i)SOCITAS\.ruleset\.json$', 'v2/SOCITAS.ruleset.v2.json'
            if ($new -ne $old) { $i.path = $new; $dirty = $true }
        }
    }

    $rulesProp = $obj.PSObject.Properties['rules']
    if ($MapIds -and $rulesProp -and $rulesProp.Value) {
        $out = New-Object System.Collections.Generic.List[object]
        $seen = @{}
        $rulesChanged = $false
        foreach ($r in @($rulesProp.Value)) {
            $id = [string]$r.id
            $key = $id.ToUpperInvariant()
            if (-not $Map.ContainsKey($key)) {
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$out.Add($r) } else { $rulesChanged = $true }
                continue
            }
            $targets = @($Map[$key])
            if ($targets.Count -eq 0) {
                [void]$script:Unmapped.Add("${rel}: rule $id has no ALCops counterpart (left for the developer)")
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$out.Add($r) }
                continue
            }
            if ($targets.Count -eq 1 -and $targets[0] -ieq $id) {
                if (-not $seen.ContainsKey($key)) { $seen[$key] = $true; [void]$out.Add($r) } else { $rulesChanged = $true }
                continue
            }
            $rulesChanged = $true
            foreach ($t in $targets) {
                $tk = $t.ToUpperInvariant()
                if ($seen.ContainsKey($tk)) { continue }
                $seen[$tk] = $true
                $clone = New-Object PSObject
                foreach ($p in $r.PSObject.Properties) {
                    if ($p.Name -eq 'id') { $clone | Add-Member -NotePropertyName 'id' -NotePropertyValue $t }
                    else { $clone | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
                }
                [void]$out.Add($clone)
            }
        }
        if ($rulesChanged) {
            $obj.rules = $out.ToArray()
            $dirty = $true
        }
    }

    if ($dirty) {
        $State.Doc = $doc
        Complete-Change -Path $Path -What 'ruleset: v2 include + rule ids' -Write { Save-JsonFile -Path $Path -Doc $doc }
    }
    else {
        [void]$script:Unchanged.Add("unchanged: $rel")
    }
}

function Get-RulesetFileValues {
    # Every string property named 'rulesetFile' anywhere in a parsed scripts/settings.json (top level, versions[], nested objects).
    param($Node)
    $vals = New-Object System.Collections.Generic.List[string]
    if ($null -eq $Node -or $Node -is [string]) { return @() }
    if ($Node -is [System.Array]) {
        foreach ($i in $Node) { foreach ($v in @(Get-RulesetFileValues $i)) { [void]$vals.Add($v) } }
    }
    elseif ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($p in $Node.PSObject.Properties) {
            if ($p.Name -eq 'rulesetFile' -and $p.Value -is [string] -and $p.Value) { [void]$vals.Add([string]$p.Value) }
            else { foreach ($v in @(Get-RulesetFileValues $p.Value)) { [void]$vals.Add($v) } }
        }
    }
    return @($vals)
}

function Find-ScriptsSettings {
    $found = New-Object System.Collections.Generic.List[string]
    $stack = New-Object System.Collections.Generic.Stack[string]
    $stack.Push($root)
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        $f = Join-Path (Join-Path $dir 'scripts') 'settings.json'
        if (Test-Path -LiteralPath $f -PathType Leaf) { [void]$found.Add($f) }
        foreach ($sub in [System.IO.Directory]::GetDirectories($dir)) {
            if ($ExcludedDirs -contains [System.IO.Path]::GetFileName($sub) -or [System.IO.Path]::GetFileName($sub) -eq '.vscode') { continue }
            $stack.Push($sub)
        }
    }
    return @($found | Sort-Object)
}

# ---------------------------------------------------------------- main

$rulesetCache = @{}
$seenAl = @{}
$anyV1Project = $false
$projects = Find-ProjectFolders
# deepest first so nested projects own their files
$ordered = @($projects | Sort-Object { $_.Length } -Descending)

foreach ($proj in $ordered) {
    $settingsPath = Join-Path (Join-Path $proj '.vscode') 'settings.json'
    $projRel = $proj.Substring($root.Length).TrimStart('\', '/')
    if ($projRel -eq '') { $projRel = '.' }
    try {
        $sdoc = Read-JsonFile -Path $settingsPath
        $settings = $sdoc.Obj
        if ($null -eq $settings -or -not ($settings -is [System.Management.Automation.PSCustomObject])) { continue }

        $appJson = $null
        $appJsonPath = Join-Path $proj 'app.json'
        if (Test-Path -LiteralPath $appJsonPath -PathType Leaf) {
            try { $appJson = (Read-JsonFile -Path $appJsonPath).Obj } catch { throw "unreadable app.json in '$projRel': $($_.Exception.Message)" }
        }

        # ruleset resolution
        $rsSetting = $settings.PSObject.Properties['al.ruleSetPath']
        $rsPath = $null
        $rsState = $null
        $rsIsV1Url = $false
        if ($rsSetting -and $rsSetting.Value) {
            $rsValue = [string]$rsSetting.Value
            if ($rsValue -match '^https?://') {
                if ($rsValue -match '(?i)SOCITAS\.(test\.)?ruleset\.json$') { $rsIsV1Url = $true }
            }
            else {
                $rsPath = Get-ExpandedPath -Value $rsValue -ProjectDir $proj
                if (-not (Test-InsideRoot $rsPath)) {
                    [void]$script:Notes.Add("${projRel}: ruleset '$rsValue' is outside RepoRoot, skipped")
                    $rsPath = $null
                }
                elseif (-not (Test-Path -LiteralPath $rsPath -PathType Leaf)) {
                    [void]$script:Notes.Add("${projRel}: ruleset '$rsValue' not found, skipped")
                    $rsPath = $null
                }
                else {
                    if (-not $rulesetCache.ContainsKey($rsPath)) { $rulesetCache[$rsPath] = Get-RulesetState -Path $rsPath }
                    $rsState = $rulesetCache[$rsPath]
                }
            }
        }

        $list = @()
        $caProp = $settings.PSObject.Properties['al.codeAnalyzers']
        if ($caProp -and $caProp.Value) { $list = @($caProp.Value | ForEach-Object { [string]$_ }) }
        $hasV1Dll = $false
        foreach ($e in $list) { if ($e -match '(?i)BusinessCentral\.(LinterCop|SocitasCop)\.dll\s*$') { $hasV1Dll = $true } }

        $isV1 = ($hasV1Dll -or $rsIsV1Url -or ($rsState -and $rsState.HasV1))
        if (-not $isV1) {
            [void]$script:Unchanged.Add("unchanged: $projRel (no v1 markers; already v2 or not an AL analyzer project)")
            continue
        }

        # test project?
        $leaf = [System.IO.Path]::GetFileName($proj)
        $isTest = ($leaf -match '^(?i)tests?$') -or (Test-TestFrameworkDependency $appJson) -or `
        ($rsIsV1Url -and ([string]$rsSetting.Value) -match '(?i)\.test\.ruleset') -or `
        ($rsState -and (@($rsState.Doc.Obj.includedRuleSets) | Where-Object { $_ -and ([string]$_.path) -match '(?i)SOCITAS\.test\.ruleset' })) -or `
        ($list | Where-Object { $_ -match '(?i)BusinessCentral\.TestCop\.dll\s*$' })
        $isTest = [bool]$isTest
        $kind = 'app'
        if ($isTest) { $kind = 'test' }
        $anyV1Project = $true
        [void]$script:Notes.Add("${projRel}: v1 project, treated as $kind project")

        # 1. analyzers
        $canon = $appAnalyzers
        if ($isTest) { $canon = $testAnalyzers }
        $canonNames = @($canon | ForEach-Object { (Get-LeafName $_).ToUpperInvariant() })
        $new = New-Object System.Collections.Generic.List[string]
        $seenNames = @{}
        foreach ($e in $list) {
            if ($e -match '(?i)BusinessCentral\.(LinterCop|SocitasCop)\.dll\s*$') { continue }
            $nm = (Get-LeafName $e).ToUpperInvariant()
            if ($seenNames.ContainsKey($e.ToUpperInvariant())) { continue }
            $seenNames[$e.ToUpperInvariant()] = $true
            if ($canonNames -contains $nm) { $seenNames[$nm] = $true }
            [void]$new.Add($e)
        }
        foreach ($c in $canon) {
            $nm = (Get-LeafName $c).ToUpperInvariant()
            if ($seenNames.ContainsKey($nm) -or $seenNames.ContainsKey($c.ToUpperInvariant())) { continue }
            $seenNames[$nm] = $true
            [void]$new.Add($c)
        }
        $same = ($new.Count -eq $list.Count)
        if ($same) { for ($i = 0; $i -lt $new.Count; $i++) { if ($new[$i] -cne $list[$i]) { $same = $false } } }
        $settingsDirty = $false
        if (-not $same) {
            if ($caProp) { $settings.'al.codeAnalyzers' = $new.ToArray() }
            else { $settings | Add-Member -NotePropertyName 'al.codeAnalyzers' -NotePropertyValue $new.ToArray() }
            $settingsDirty = $true
        }
        if ($rsIsV1Url) {
            $old = [string]$rsSetting.Value
            $nv = $old -replace '(?i)SOCITAS\.test\.ruleset\.json$', 'v2/SOCITAS.test.ruleset.v2.json'
            $nv = $nv -replace '(?i)SOCITAS\.ruleset\.json$', 'v2/SOCITAS.ruleset.v2.json'
            $settings.'al.ruleSetPath' = $nv
            $settingsDirty = $true
        }
        if ($settingsDirty) {
            Complete-Change -Path $settingsPath -What 'settings: v2 analyzers' -Write { Save-JsonFile -Path $settingsPath -Doc $sdoc }
        }
        else { [void]$script:Unchanged.Add("unchanged: $projRel/.vscode/settings.json") }

        # 3. ruleset (once per file)
        if ($rsState -and -not $rsState.Done) {
            $mapIds = ($rsState.HasV1 -or -not $rsState.HasV2)
            Convert-Ruleset -Path $rsPath -State $rsState -MapIds $mapIds
            $rsState | Add-Member -NotePropertyName Done -NotePropertyValue $true -Force
        }

        # 4. pragmas
        foreach ($al in (Find-AlFiles -Dir $proj)) {
            $k = $al.ToUpperInvariant()
            if ($seenAl.ContainsKey($k)) { continue }
            $seenAl[$k] = $true
            $f = Read-TextFile -Path $al
            if ($f.Text.IndexOf('pragma', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
            $un = New-Object System.Collections.Generic.List[string]
            $newText = Convert-PragmaText -Text $f.Text -Map $Map -Unmapped $un
            $alRel = $al.Substring($root.Length).TrimStart('\', '/')
            foreach ($u in ($un | Select-Object -Unique)) {
                [void]$script:Unmapped.Add("${alRel}: pragma id $u has no ALCops counterpart (left for the developer)")
            }
            if ($newText -cne $f.Text) {
                $bom = $f.Bom; $encn = $f.Encoding; $alp = $al; $nt = $newText
                Complete-Change -Path $al -What 'pragma ids' -Write { Write-TextFile -Path $alp -Text $nt -Bom $bom -Encoding $encn }
            }
        }
    }
    catch {
        [void]$script:Errors.Add("ERROR: ${projRel}: $($_.Exception.Message)")
    }
}

# 5. container path: rulesets named by scripts/settings.json `rulesetFile` (may differ from al.ruleSetPath)
foreach ($ss in (Find-ScriptsSettings)) {
    $ssRel = $ss.Substring($root.Length).TrimStart('\', '/')
    try {
        $ssDoc = Read-JsonFile -Path $ss
        $repoDir = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($ss))
        foreach ($val in @(Get-RulesetFileValues $ssDoc.Obj | Select-Object -Unique)) {
            if ($val -match '^https?://') { continue }
            # the pipeline resolves it as Join-Path <repo root> <rulesetFile>; also accept <root>/app and <root>/test relative paths
            $cands = @((Get-ExpandedPath -Value $val -ProjectDir $repoDir), (Get-ExpandedPath -Value $val -ProjectDir (Join-Path $repoDir 'app')), (Get-ExpandedPath -Value $val -ProjectDir (Join-Path $repoDir 'test')))
            $hit = $null
            foreach ($c in $cands) { if ((Test-InsideRoot $c) -and (Test-Path -LiteralPath $c -PathType Leaf)) { $hit = $c; break } }
            if (-not $hit) { [void]$script:Notes.Add("${ssRel}: rulesetFile '$val' not found inside RepoRoot, skipped"); continue }
            if (-not $rulesetCache.ContainsKey($hit)) { $rulesetCache[$hit] = Get-RulesetState -Path $hit }
            $st = $rulesetCache[$hit]
            if ($st.Done) { continue }
            if (-not ($st.HasV1 -or ($anyV1Project -and -not $st.HasV2))) { continue }
            [void]$script:Notes.Add("${ssRel}: rulesetFile '$val' migrated as app ruleset")
            Convert-Ruleset -Path $hit -State $st -MapIds ($st.HasV1 -or -not $st.HasV2)
            $st | Add-Member -NotePropertyName Done -NotePropertyValue $true -Force
        }
    }
    catch { [void]$script:Errors.Add("ERROR: ${ssRel}: $($_.Exception.Message)") }
}

# ---------------------------------------------------------------- report

foreach ($n in $script:Notes) { Write-Output "note: $n" }
foreach ($c in $script:Changed) { Write-Output $c }
foreach ($u in $script:Unchanged) { Write-Output $u }
foreach ($u in $script:Unmapped) { Write-Output "unmapped: $u" }
foreach ($e in $script:Errors) { Write-Output $e }
$verb = 'changed'
if ($WhatIfPreference) { $verb = 'would change' }
Write-Output ("summary: {0} file(s) {1}, {2} unmapped id(s) left for the developer, {3} error(s)" -f $script:Changed.Count, $verb, $script:Unmapped.Count, $script:Errors.Count)
if ($script:Errors.Count -gt 0) { exit 1 }
exit 0
