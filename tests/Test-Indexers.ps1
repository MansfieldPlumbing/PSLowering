<#
.SYNOPSIS
    Checks element access through CLR indexers and that array indexing output is unchanged.
.DESCRIPTION
    Compiles tests/fixtures/IndexerFixture.ps1 twice with -Deterministic and
    requires byte-identical assemblies that reference only System.Private.CoreLib
    (ClrOnlyAdmitted), then checks List[int] read, write, compound assignment,
    ++ and --, and Dictionary[string,long] read and write against fixed values.
    (tests/parity/PowerShellParity.ps1 runs the same methods against PowerShell.)
    Index forms outside the admitted subset must be rejected with a source
    position and no output. Fixtures that index arrays must still build to the
    SHA-256 frozen in tests/baseline/218f54e.json.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'
$fixturePath = Join-Path $PSScriptRoot 'fixtures/IndexerFixture.ps1'
$outDir = Join-Path $repoRoot 'build/indexers'
if (Test-Path -LiteralPath $outDir) { Remove-Item -LiteralPath $outDir -Recurse -Force }
$null = New-Item -ItemType Directory -Force -Path $outDir
$failures = [Collections.Generic.List[string]]::new()

# 1. Deterministic, CoreLib-only output
$dll = Join-Path $outDir 'IndexerFixture.dll'
$reproDll = Join-Path $outDir 'repro/IndexerFixture.dll'
$null = New-Item -ItemType Directory -Force -Path (Split-Path $reproDll)
& $compilerPath -Mode Compile -SourcePath $fixturePath -ClassName IndexerFixture -OutputPath $dll -Deterministic | Out-Null
& $compilerPath -Mode Compile -SourcePath $fixturePath -ClassName IndexerFixture -OutputPath $reproDll -Deterministic | Out-Null
if (-not [Linq.Enumerable]::SequenceEqual([byte[]][IO.File]::ReadAllBytes($dll), [byte[]][IO.File]::ReadAllBytes($reproDll))) {
    $failures.Add('Deterministic builds of IndexerFixture differ.')
}
$receipt = & $compilerPath -Mode Inspect -AssemblyPath $dll
if (-not $receipt.ClrOnlyAdmitted) { $failures.Add('IndexerFixture is not ClrOnlyAdmitted.') }

# 2. Values
$type = [Reflection.Assembly]::LoadFile($dll).GetType('IndexerFixture', $true)
$expected = @(
    ,@('ListReadWrite', @([int[]]@(1, 2, 3), 1), 21)
    ,@('ListReadWrite', @([int[]]@(1, 2, 3), -1), 31)
    ,@('ListCompound', @(, [int[]]@(1, 2, 3)), -56)
    ,@('ListIncrementValue', @(, [int[]]@(7, 8)), 7099)
    ,@('ListScanStarts', @([int[]]@(4, 1, 8, 3, 16), 3), [long]68)
    ,@('ListIndexConversion', @([int[]]@(5, 6, 7), 1.5), 7)
    ,@('InterfaceNegativeIndex', @(, [int[]]@(1, 2, 3)), 4)
    ,@('DictionaryReadWrite', @(, [string[]]@('a', 'b', 'a', 'c')), [long]210)
    ,@('DictionaryCompound', @(, [string[]]@('a', 'b', 'a')), [long]15)
    ,@('StringIndex', @('abc', -1), [char]'c')
    ,@('ArrayElementIncrement', @(, [int[]]@(1, 2, 3)), 206)
)
foreach ($case in $expected) {
    $name, $arguments, $want = $case
    $got = $type.GetMethod($name).Invoke($null, [object[]]$arguments)
    if ($got -isnot $want.GetType() -or $got -ne $want) { $failures.Add("${name}: expected $want ($($want.GetType().Name)), got $got") }
}
$missing = $null
try { $null = $type.GetMethod('ListReadWrite').Invoke($null, [object[]]@([int[]]@(1, 2), 5)) } catch { $missing = $_.Exception.InnerException }
if ($missing -isnot [ArgumentOutOfRangeException]) { $failures.Add("ListReadWrite out of range: expected ArgumentOutOfRangeException, got '$missing'") }

# 3. Rejections: position, reason, and no output written
$rejections = [ordered]@{
    ReadOnlyIndexer   = @('$l = [System.Collections.Generic.List[int]]::new(); $l.Add(1); [System.Collections.Generic.IReadOnlyList[int]] $r = $l; $r[0] = 2; return $r[0]', 'indexer of .*IReadOnlyList.* is read-only')
    ReadOnlyCompound  = @('$l = [System.Collections.Generic.List[int]]::new(); $l.Add(1); $r = $l.AsReadOnly(); $r[0] += 2; return $r[0]', 'indexer of .*ReadOnlyCollection.* is read-only')
    ReadOnlyIncrement = @('[string] $s = ''abc''; $s[0]++; return 0', "indexer of 'System.String' is read-only")
    NoIndexer         = @('[int] $n = 3; return $n[0]', "Type 'System.Int32' has no indexer")
    Slicing           = @('$l = [System.Collections.Generic.List[int]]::new(); $l.Add(1); $l.Add(2); return $l[0, 1]', 'with 2 indexes \(slicing\) is not supported')
    ValueTypeReceiver = @('$v = [int[]]::new(3); $s = [System.ArraySegment[int]]::new($v, 0, 2); return $s[0]', "Indexing a value of value type 'System.ArraySegment")
}
foreach ($name in $rejections.Keys) {
    $body, $pattern = $rejections[$name]
    $source = Join-Path $outDir "Reject$name.ps1"
    $output = Join-Path $outDir "Reject$name.dll"
    Set-Content -LiteralPath $source -Value "class Reject$name {`n    static [int] M() {`n        $body`n    }`n}"
    $message = $null
    try { & $compilerPath -Mode Compile -SourcePath $source -ClassName "Reject$name" -OutputPath $output | Out-Null }
    catch { $message = $_.Exception.Message }
    if ($null -eq $message) { $failures.Add("${name}: compiled; expected rejection"); continue }
    if ($message -notmatch '\[\d+:\d+\]') { $failures.Add("${name}: no source position in '$message'") }
    if ($message -notmatch $pattern) { $failures.Add("${name}: '$message' does not match '$pattern'") }
    if (Test-Path -LiteralPath $output) { $failures.Add("${name}: output was written") }
}

# 4. Array indexing builds the same bytes as the frozen 218f54e baseline
$manifest = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'baseline/218f54e.json') -Raw | ConvertFrom-Json
foreach ($path in 'slice6/Slice6Fixture.dll', 'powershell-parity/ClassesFixture.dll', 'powershell-parity/LoopsFixture.dll') {
    $frozen = $manifest.Outputs | Where-Object Path -CEQ $path
    $built = Join-Path $outDir "arrays/$path"
    $null = New-Item -ItemType Directory -Force -Path (Split-Path $built)
    & $compilerPath -Mode Compile -SourcePath (Join-Path $repoRoot $frozen.Fixture) -ClassName $frozen.ClassName -OutputPath $built -Deterministic | Out-Null
    $hash = (Get-FileHash -LiteralPath $built -Algorithm SHA256).Hash
    if ($hash -cne $frozen.SHA256) { $failures.Add("${path}: SHA-256 $hash differs from frozen $($frozen.SHA256)") }
}

$failures | ForEach-Object { Write-Host "  FAIL $_" }
[pscustomobject]@{
    Suite           = 'Indexers'
    Values          = $expected.Count + 1
    Rejections      = $rejections.Count
    ArrayOutputs    = 3
    ClrOnlyAdmitted = $receipt.ClrOnlyAdmitted
    SHA256          = $receipt.SHA256
    Failures        = $failures.Count
    Status          = if ($failures.Count) { 'FAIL' } else { 'PASS' }
}
if ($failures.Count) { exit 1 }
