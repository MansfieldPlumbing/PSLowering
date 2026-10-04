[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/PSPersistence.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice6Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice6'
$outDll = Join-Path $outDir 'Slice6Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice6Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice6Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 6 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice6Fixture', $true)

# AllocateIntArray
$arr1 = $type.GetMethod('AllocateIntArray').Invoke($null, [object[]]@(5))
if ($null -eq $arr1 -or $arr1.Length -ne 5 -or $arr1.GetType() -ne [int[]]) {
    throw "AllocateIntArray(5) failed: got $arr1"
}

# SumArray
$sum = $type.GetMethod('SumArray').Invoke($null, [object[]]@(, [int[]]@(1, 2, 3, 4, 5)))
if ($sum -ne 15) {
    throw "SumArray failed: expected 15, got $sum"
}

# ScaleFloatArray
$fArr = [float[]]@(1.0, 2.5, 4.0)
$scaled = $type.GetMethod('ScaleFloatArray').Invoke($null, [object[]]@($fArr, [float]2.0))
if ($scaled[0] -ne 2.0 -or $scaled[1] -ne 5.0 -or $scaled[2] -ne 8.0) {
    throw "ScaleFloatArray failed: got $($scaled -join ', ')"
}

# ArrayLiteralInit
$lit = $type.GetMethod('ArrayLiteralInit').Invoke($null, $null)
if ($lit.Length -ne 4 -or $lit[0] -ne 10 -or $lit[1] -ne 20 -or $lit[2] -ne 30 -or $lit[3] -ne 40) {
    throw "ArrayLiteralInit failed: got $($lit -join ', ')"
}

# ArrayLengthCheck
$dArr = [double[]]@(1.1, 2.2, 3.3, 4.4, 5.5, 6.6)
$len = $type.GetMethod('ArrayLengthCheck').Invoke($null, [object[]]@(, $dArr))
if ($len -ne 6) {
    throw "ArrayLengthCheck failed: expected 6, got $len"
}

# CopyArray
$src = [int[]]@(100, 200, 300)
$copied = $type.GetMethod('CopyArray').Invoke($null, [object[]]@(, $src))
if ($copied.Length -ne 3 -or $copied[0] -ne 100 -or $copied[1] -ne 200 -or $copied[2] -ne 300) {
    throw "CopyArray failed: got $($copied -join ', ')"
}

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$childCmd = @"
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$t = `$asm.GetType('Slice6Fixture')
`$a = `$t.GetMethod('AllocateIntArray').Invoke(`$null, [object[]]@(5))
`$s = `$t.GetMethod('SumArray').Invoke(`$null, [object[]]@(, [int[]]@(1, 2, 3, 4, 5)))
`$scaled = `$t.GetMethod('ScaleFloatArray').Invoke(`$null, [object[]]@([float[]]@(1.0, 2.5, 4.0), [float]2.0))
`$lit = `$t.GetMethod('ArrayLiteralInit').Invoke(`$null, `$null)
`$len = `$t.GetMethod('ArrayLengthCheck').Invoke(`$null, [object[]]@(, [double[]]@(1.1, 2.2, 3.3)))
`$copied = `$t.GetMethod('CopyArray').Invoke(`$null, [object[]]@(, [int[]]@(10, 20)))
if (`$a.Length -eq 5 -and `$s -eq 15 -and `$scaled[1] -eq 5.0 -and `$lit[3] -eq 40 -and `$len -eq 3 -and `$copied[1] -eq 20) {
    Write-Output 'FRESH_PROCESS_SLICE6=PASS'
} else {
    Write-Output 'FRESH_PROCESS_SLICE6=FAIL'
}
"@

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
$childOut = & $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoProfile -Command $childCmd
Write-Host $childOut
if ($childOut -notmatch 'FRESH_PROCESS_SLICE6=PASS') {
    throw "Fresh process verification failed: $childOut"
}

# 3. Byte determinism verification
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice6_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice6Fixture.dll'
Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice6Fixture' `
    -OutputPath $outDll2 `
    -Deterministic | Out-Null

$bytes1 = [IO.File]::ReadAllBytes($outDll)
$bytes2 = [IO.File]::ReadAllBytes($outDll2)
$match = [Linq.Enumerable]::SequenceEqual([byte[]]$bytes1, [byte[]]$bytes2)

if (-not $match) {
    throw "Non-deterministic build detected! Hashes differ between consecutive runs."
}

[pscustomobject]@{
    Slice              = 6
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
