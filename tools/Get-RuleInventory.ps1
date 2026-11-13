#Requires -Version 7.0
<#
.SYNOPSIS
  Generates v2/rule-inventory.json: every diagnostic id per analyzer for the pinned versions.
.PARAMETER PinsPath
  SOCITAS.analyzers.v2.json (alCompiler, alcops, socitasCopV2, testCop).
.PARAMETER OutPath
  Inventory file to write.
.PARAMETER CompilerPath
  Folder holding Microsoft.Dynamics.Nav.CodeAnalysis.dll and the MS cops. Omitted = download
  microsoft.dynamics.businesscentral.development.tools at the pinned alCompiler version.
.PARAMETER SocitasCopV2Path / TestCopPath
  Local DLLs. Omitted = `gh release download` (v<pin>) of socitas-gmbh/BusinessCentral.SocitasCopV2 / .TestCop
  (needs GH_TOKEN or GITHUB_TOKEN with read access to those repos in CI).
.PARAMETER AlcopsPath
  Folder with the ALCops DLLs. Omitted = download ALCops.Analyzers at the pinned version from nuget.org.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PinsPath,
    [Parameter(Mandatory)] [string] $OutPath,
    [string] $CompilerPath,
    [string] $AlcopsPath,
    [string] $SocitasCopV2Path,
    [string] $TestCopPath,
    [string] $WorkDir
)
$ErrorActionPreference = 'Stop'
$pins = Get-Content -Raw -LiteralPath $PinsPath | ConvertFrom-Json
if (-not $WorkDir) { $WorkDir = Join-Path ([IO.Path]::GetTempPath()) ("ruleinv-" + [guid]::NewGuid().ToString('N')) }
New-Item -ItemType Directory -Force -Path $WorkDir | Out-Null

function Get-NupkgFromNuget([string] $Id, [string] $Version, [string] $Target, [string] $EntryPattern = '.') {
    $lid = $Id.ToLowerInvariant()
    $url = "https://api.nuget.org/v3-flatcontainer/$lid/$Version/$lid.$Version.nupkg"
    $zip = Join-Path $WorkDir "$lid.$Version.zip"
    Invoke-WebRequest -Uri $url -OutFile $zip -ErrorAction Stop
    # extract only the entries needed (the development tools package is large)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $arc = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        foreach ($e in $arc.Entries) {
            if ($e.FullName.EndsWith('/') -or $e.FullName -notmatch $EntryPattern) { continue }
            $dest = Join-Path $Target $e.FullName
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $dest, $true)
        }
    }
    finally { $arc.Dispose() }
    Remove-Item -LiteralPath $zip -Force
}
function Get-ReleaseDll([string] $Repo, [string] $Tag, [string] $DllName, [string] $Target) {
    New-Item -ItemType Directory -Force -Path $Target | Out-Null
    & gh release download $Tag -R $Repo -p $DllName -D $Target --clobber
    if ($LASTEXITCODE -ne 0) { throw "gh release download $Repo $Tag failed (exit $LASTEXITCODE)" }
    Join-Path $Target $DllName
}

# --- locate inputs -------------------------------------------------------------------------------
if (-not $CompilerPath) {
    $t = Join-Path $WorkDir 'devtools'
    Get-NupkgFromNuget 'microsoft.dynamics.businesscentral.development.tools' $pins.alCompiler $t '^tools/net8\.0/any/'
    $nav = Get-ChildItem -Path $t -Recurse -Filter 'Microsoft.Dynamics.Nav.CodeAnalysis.dll' | Sort-Object FullName | Select-Object -First 1
    if (-not $nav) { throw "Microsoft.Dynamics.Nav.CodeAnalysis.dll not found in development tools $($pins.alCompiler)" }
    $CompilerPath = $nav.DirectoryName
}
if (-not (Test-Path -LiteralPath (Join-Path $CompilerPath 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'))) {
    throw "CompilerPath '$CompilerPath' has no Microsoft.Dynamics.Nav.CodeAnalysis.dll"
}
if (-not $AlcopsPath) {
    $t = Join-Path $WorkDir 'alcops'
    Get-NupkgFromNuget 'ALCops.Analyzers' $pins.alcops $t '^lib/net8\.0/'
    $AlcopsPath = Join-Path $t 'lib/net8.0'
}
if (-not $SocitasCopV2Path) {
    $SocitasCopV2Path = Get-ReleaseDll 'socitas-gmbh/BusinessCentral.SocitasCopV2' "v$($pins.socitasCopV2)" 'BusinessCentral.SocitasCopV2.dll' (Join-Path $WorkDir 'socitascopv2')
}
if (-not $TestCopPath) {
    $TestCopPath = Get-ReleaseDll 'socitas-gmbh/BusinessCentral.TestCop' "v$($pins.testCop)" 'BusinessCentral.TestCop.dll' (Join-Path $WorkDir 'testcop')
}

$dlls = [ordered]@{}
foreach ($n in 'CodeCop', 'UICop', 'PerTenantExtensionCop', 'AppSourceCop') {
    $dlls["Microsoft.Dynamics.Nav.$n"] = Join-Path $CompilerPath "Microsoft.Dynamics.Nav.$n.dll"
}
foreach ($f in Get-ChildItem -LiteralPath $AlcopsPath -Filter 'ALCops.*.dll' | Sort-Object Name) {
    if ($f.Name -eq 'ALCops.Common.dll') { continue }
    $dlls[[IO.Path]::GetFileNameWithoutExtension($f.Name)] = $f.FullName
}
$dlls['BusinessCentral.SocitasCopV2'] = $SocitasCopV2Path
$dlls['BusinessCentral.TestCop'] = $TestCopPath

# --- reflection ----------------------------------------------------------------------------------
$searchDirs = @($CompilerPath, $AlcopsPath, (Split-Path $SocitasCopV2Path), (Split-Path $TestCopPath))
$null = [System.Runtime.Loader.AssemblyLoadContext]::Default.add_Resolving({
        param($ctx, $name)
        foreach ($d in $searchDirs) {
            $p = Join-Path $d "$($name.Name).dll"
            if (Test-Path -LiteralPath $p) { return $ctx.LoadFromAssemblyPath((Resolve-Path $p).Path) }
        }
        return $null
    }.GetNewClosure())
$null = [Reflection.Assembly]::LoadFrom((Join-Path $CompilerPath 'Microsoft.Dynamics.Nav.CodeAnalysis.dll'))

$analyzers = [ordered]@{}
foreach ($name in $dlls.Keys) {
    $path = $dlls[$name]
    if (-not (Test-Path -LiteralPath $path)) { throw "Analyzer '$name': DLL not found at $path" }
    try {
        $asm = [Reflection.Assembly]::LoadFrom($path)
        $types = try { $asm.GetTypes() } catch [Reflection.ReflectionTypeLoadException] { $_.Exception.Types | Where-Object { $_ } }
        $base = [Reflection.Assembly]::LoadFrom((Join-Path $CompilerPath 'Microsoft.Dynamics.Nav.CodeAnalysis.dll')).GetType('Microsoft.Dynamics.Nav.CodeAnalysis.Diagnostics.DiagnosticAnalyzer')
        if (-not $base) { throw 'DiagnosticAnalyzer base type not found' }
        $byId = @{}
        foreach ($t in $types) {
            if ($t.IsAbstract -or -not $base.IsAssignableFrom($t)) { continue }
            $inst = [Activator]::CreateInstance($t)
            foreach ($d in $inst.SupportedDiagnostics) {
                $byId[$d.Id] = [pscustomobject][ordered]@{
                    id              = [string]$d.Id
                    defaultSeverity = [string]$d.DefaultSeverity
                    title           = ([string]$d.Title).Trim()
                }
            }
        }
    }
    catch { throw "Analyzer '$name': cannot enumerate diagnostics: $($_.Exception.Message)" }
    if ($byId.Count -eq 0) { throw "Analyzer '$name': no diagnostics found" }
    $analyzers[$name] = @($byId.Values | Sort-Object { $_.id } -CaseSensitive)
}

$sorted = [ordered]@{}
foreach ($k in ($analyzers.Keys | Sort-Object { $_ } -CaseSensitive)) { $sorted[$k] = $analyzers[$k] }
# provenance: the pins this inventory was generated from (CI compares them with the pins file it is used for)
$provenance = [ordered]@{ alCompiler = [string]$pins.alCompiler; alcops = [string]$pins.alcops; socitasCopV2 = [string]$pins.socitasCopV2; testCop = [string]$pins.testCop }
$json = ([ordered]@{ pins = $provenance; analyzers = $sorted } | ConvertTo-Json -Depth 8)
$dir = Split-Path -Parent $OutPath
if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
[IO.File]::WriteAllText($OutPath, ($json -replace "`r`n", "`n") + "`n", [Text.UTF8Encoding]::new($false))
foreach ($k in $sorted.Keys) { Write-Host ("{0}: {1}" -f $k, @($sorted[$k]).Count) }
