[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/PSPersistence.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice7Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice7'
$outDll = Join-Path $outDir 'Slice7Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice7Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice7Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 7 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice7Fixture', $true)

# StaticMath
$max = $type.GetMethod('StaticMath').Invoke($null, [object[]]@(15, 27))
if ($max -ne 27) { throw "StaticMath failed: expected 27, got $max" }

# SubstringTest
$sub = $type.GetMethod('SubstringTest').Invoke($null, [object[]]@('Hello World', 6, 5))
if ($sub -ne 'World') { throw "SubstringTest failed: expected 'World', got '$sub'" }

# BuildGreeting
$greeting = $type.GetMethod('BuildGreeting').Invoke($null, [object[]]@('Reader'))
if ($greeting -ne 'Hello, Reader!') { throw "BuildGreeting failed: expected 'Hello, Reader!', got '$greeting'" }

# IsEmpty
$emptyT = $type.GetMethod('IsEmpty').Invoke($null, [object[]]@(''))
$emptyF = $type.GetMethod('IsEmpty').Invoke($null, [object[]]@('non-empty'))
if (-not $emptyT -or $emptyF) { throw "IsEmpty failed: emptyT=$emptyT, emptyF=$emptyF" }

# PathCombine
$combined = $type.GetMethod('PathCombine').Invoke($null, [object[]]@('C:\foo', 'bar.txt'))
$expected = [IO.Path]::Combine('C:\foo', 'bar.txt')
if ($combined -ne $expected) { throw "PathCombine failed: expected '$expected', got '$combined'" }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$childCmd = @"
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$t = `$asm.GetType('Slice7Fixture')
`$max = `$t.GetMethod('StaticMath').Invoke(`$null, [object[]]@(15, 27))
`$sub = `$t.GetMethod('SubstringTest').Invoke(`$null, [object[]]@('Hello World', 6, 5))
`$greeting = `$t.GetMethod('BuildGreeting').Invoke(`$null, [object[]]@('Reader'))
`$emptyT = `$t.GetMethod('IsEmpty').Invoke(`$null, [object[]]@(''))
`$emptyF = `$t.GetMethod('IsEmpty').Invoke(`$null, [object[]]@('hello'))
`$combined = `$t.GetMethod('PathCombine').Invoke(`$null, [object[]]@('dir', 'file.dat'))

if (`$max -eq 27 -and `$sub -eq 'World' -and `$greeting -eq 'Hello, Reader!' -and `$emptyT -and -not `$emptyF -and `$combined -eq [IO.Path]::Combine('dir', 'file.dat')) {
    Write-Output 'FRESH_PROCESS_SLICE7=PASS'
} else {
    Write-Output 'FRESH_PROCESS_SLICE7=FAIL'
}
"@

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
$childOut = & $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoProfile -Command $childCmd
Write-Host $childOut
if ($childOut -notmatch 'FRESH_PROCESS_SLICE7=PASS') {
    throw "Fresh process verification failed: $childOut"
}

# 3. Byte determinism verification
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice7_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice7Fixture.dll'
Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice7Fixture' `
    -OutputPath $outDll2 `
    -Deterministic | Out-Null

$bytes1 = [IO.File]::ReadAllBytes($outDll)
$bytes2 = [IO.File]::ReadAllBytes($outDll2)
$match = [Linq.Enumerable]::SequenceEqual([byte[]]$bytes1, [byte[]]$bytes2)

if (-not $match) {
    throw "Non-deterministic build detected! Hashes differ between consecutive runs."
}

[pscustomobject]@{
    Slice              = 7
    Status             = 'PASS'
    Assembly           = $outDll
    Length             = $bytes1.Length
    SHA256             = $testReceipt.SHA256
    MVID               = $testReceipt.MVID
    SmaReferenced      = $testReceipt.SmaReferenced
    ClrOnlyAdmitted    = $testReceipt.ClrOnlyAdmitted
    FreshProcessResult = 'PASS'
    DeterminismMatch   = 'PASS'
}
