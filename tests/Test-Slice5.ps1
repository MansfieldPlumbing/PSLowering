[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice5Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice5'
$outDll = Join-Path $outDir 'Slice5Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice5Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice5Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 5 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice5Fixture', $true)

# BranchMax
if ($type.GetMethod('BranchMax').Invoke($null, [object[]]@(10, 20)) -ne 20) { throw 'BranchMax(10, 20) failed' }
if ($type.GetMethod('BranchMax').Invoke($null, [object[]]@(30, 20)) -ne 30) { throw 'BranchMax(30, 20) failed' }

# NestedIf
if ($type.GetMethod('NestedIf').Invoke($null, [object[]]@(150)) -ne 2) { throw 'NestedIf(150) failed' }
if ($type.GetMethod('NestedIf').Invoke($null, [object[]]@(50)) -ne 1) { throw 'NestedIf(50) failed' }
if ($type.GetMethod('NestedIf').Invoke($null, [object[]]@(-5)) -ne -1) { throw 'NestedIf(-5) failed' }
if ($type.GetMethod('NestedIf').Invoke($null, [object[]]@(0)) -ne 0) { throw 'NestedIf(0) failed' }

# SumTo (for loop)
if ($type.GetMethod('SumTo').Invoke($null, [object[]]@(10)) -ne 55) { throw 'SumTo(10) failed' }
if ($type.GetMethod('SumTo').Invoke($null, [object[]]@(0)) -ne 0) { throw 'SumTo(0) failed' }

# EarlyReturnInLoop
if ($type.GetMethod('EarlyReturnInLoop').Invoke($null, [object[]]@(5)) -ne 50) { throw 'EarlyReturnInLoop(5) failed' }
if ($type.GetMethod('EarlyReturnInLoop').Invoke($null, [object[]]@(150)) -ne -1) { throw 'EarlyReturnInLoop(150) failed' }

# WhileCountdown
if ($type.GetMethod('WhileCountdown').Invoke($null, [object[]]@(10)) -ne 10) { throw 'WhileCountdown(10) failed' }
if ($type.GetMethod('WhileCountdown').Invoke($null, [object[]]@(0)) -ne 0) { throw 'WhileCountdown(0) failed' }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$freshScript = @"
`$ErrorActionPreference = 'Stop'
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$type = `$asm.GetType('Slice5Fixture', `$true)
if (`$type.GetMethod('BranchMax').Invoke(`$null, [object[]]@(10, 20)) -ne 20) { exit 1 }
if (`$type.GetMethod('NestedIf').Invoke(`$null, [object[]]@(150)) -ne 2) { exit 2 }
if (`$type.GetMethod('SumTo').Invoke(`$null, [object[]]@(10)) -ne 55) { exit 3 }
if (`$type.GetMethod('EarlyReturnInLoop').Invoke(`$null, [object[]]@(5)) -ne 50) { exit 4 }
if (`$type.GetMethod('WhileCountdown').Invoke(`$null, [object[]]@(10)) -ne 10) { exit 5 }
Write-Output 'FRESH_PROCESS_SLICE5=PASS'
"@

$freshScriptPath = Join-Path $outDir 'invoke_fresh.ps1'
[IO.File]::WriteAllText($freshScriptPath, $freshScript)

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
& $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoLogo -NoProfile -File $freshScriptPath | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw "Fresh-process invocation failed with exit code $LASTEXITCODE"
}

# 3. Determinism check
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice5_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice5Fixture.dll'
$null = Export-LoweredAssembly -SourcePath $fixturePath -ClassName 'Slice5Fixture' -OutputPath $outDll2 -Deterministic
$t2 = Test-LoweredAssembly -AssemblyPath $outDll2

if ($t2.SHA256 -ne $testReceipt.SHA256 -or $t2.MVID -ne $testReceipt.MVID) {
    throw "Determinism check failed: hashes differ ($($testReceipt.SHA256) vs $($t2.SHA256))"
}

[pscustomobject]@{
    Slice              = 5
    Status             = 'PASS'
    Assembly           = $outDll
    Length             = $testReceipt.Length
    SHA256             = $testReceipt.SHA256
    MVID               = $testReceipt.MVID
    SmaReferenced      = $testReceipt.SmaReferenced
    ClrOnlyAdmitted    = $testReceipt.ClrOnlyAdmitted
    FreshProcessResult = 'PASS'
    DeterminismMatch   = 'PASS'
}
