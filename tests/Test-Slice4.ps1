[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/PSPersistence.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice4Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice4'
$outDll = Join-Path $outDir 'Slice4Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice4Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice4Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 4 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice4Fixture', $true)

# IntEqual
if ($type.GetMethod('IntEqual').Invoke($null, [object[]]@(5, 5)) -ne $true) { throw 'IntEqual(5, 5) failed' }
if ($type.GetMethod('IntEqual').Invoke($null, [object[]]@(5, 6)) -ne $false) { throw 'IntEqual(5, 6) failed' }

# IntLess
if ($type.GetMethod('IntLess').Invoke($null, [object[]]@(3, 5)) -ne $true) { throw 'IntLess(3, 5) failed' }
if ($type.GetMethod('IntLess').Invoke($null, [object[]]@(5, 3)) -ne $false) { throw 'IntLess(5, 3) failed' }

# IntLessOrEqual
if ($type.GetMethod('IntLessOrEqual').Invoke($null, [object[]]@(5, 5)) -ne $true) { throw 'IntLessOrEqual(5, 5) failed' }
if ($type.GetMethod('IntLessOrEqual').Invoke($null, [object[]]@(4, 5)) -ne $true) { throw 'IntLessOrEqual(4, 5) failed' }
if ($type.GetMethod('IntLessOrEqual').Invoke($null, [object[]]@(6, 5)) -ne $false) { throw 'IntLessOrEqual(6, 5) failed' }

# IntGreaterOrEqual
if ($type.GetMethod('IntGreaterOrEqual').Invoke($null, [object[]]@(5, 5)) -ne $true) { throw 'IntGreaterOrEqual(5, 5) failed' }
if ($type.GetMethod('IntGreaterOrEqual').Invoke($null, [object[]]@(6, 5)) -ne $true) { throw 'IntGreaterOrEqual(6, 5) failed' }
if ($type.GetMethod('IntGreaterOrEqual').Invoke($null, [object[]]@(4, 5)) -ne $false) { throw 'IntGreaterOrEqual(4, 5) failed' }

# IEEE 754 FloatLessOrEqual with NaN
if ($type.GetMethod('FloatLessOrEqual').Invoke($null, [object[]]@(3.0, 5.0)) -ne $true) { throw 'FloatLessOrEqual(3.0, 5.0) failed' }
if ($type.GetMethod('FloatLessOrEqual').Invoke($null, [object[]]@(5.0, 5.0)) -ne $true) { throw 'FloatLessOrEqual(5.0, 5.0) failed' }
if ($type.GetMethod('FloatLessOrEqual').Invoke($null, [object[]]@(7.0, 5.0)) -ne $false) { throw 'FloatLessOrEqual(7.0, 5.0) failed' }
if ($type.GetMethod('FloatLessOrEqual').Invoke($null, [object[]]@([double]::NaN, 5.0)) -ne $false) { throw 'FloatLessOrEqual(NaN, 5.0) must be false per IEEE 754' }
if ($type.GetMethod('FloatLessOrEqual').Invoke($null, [object[]]@(5.0, [double]::NaN)) -ne $false) { throw 'FloatLessOrEqual(5.0, NaN) must be false per IEEE 754' }

# Logical operations
if ($type.GetMethod('LogicalAnd').Invoke($null, [object[]]@($true, $true)) -ne $true) { throw 'LogicalAnd(T, T) failed' }
if ($type.GetMethod('LogicalAnd').Invoke($null, [object[]]@($true, $false)) -ne $false) { throw 'LogicalAnd(T, F) failed' }
if ($type.GetMethod('LogicalOr').Invoke($null, [object[]]@($false, $true)) -ne $true) { throw 'LogicalOr(F, T) failed' }
if ($type.GetMethod('LogicalOr').Invoke($null, [object[]]@($false, $false)) -ne $false) { throw 'LogicalOr(F, F) failed' }
if ($type.GetMethod('LogicalNot').Invoke($null, [object[]]@($true)) -ne $false) { throw 'LogicalNot(T) failed' }
if ($type.GetMethod('LogicalNot').Invoke($null, [object[]]@($false)) -ne $true) { throw 'LogicalNot(F) failed' }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$freshScript = @"
`$ErrorActionPreference = 'Stop'
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$type = `$asm.GetType('Slice4Fixture', `$true)
if (`$type.GetMethod('IntEqual').Invoke(`$null, [object[]]@(5, 5)) -ne `$true) { exit 1 }
if (`$type.GetMethod('FloatLessOrEqual').Invoke(`$null, [object[]]@([double]::NaN, 5.0)) -ne `$false) { exit 2 }
if (`$type.GetMethod('LogicalAnd').Invoke(`$null, [object[]]@(`$true, `$false)) -ne `$false) { exit 3 }
if (`$type.GetMethod('LogicalNot').Invoke(`$null, [object[]]@(`$false)) -ne `$true) { exit 4 }
Write-Output 'FRESH_PROCESS_SLICE4=PASS'
"@

$freshScriptPath = Join-Path $outDir 'invoke_fresh.ps1'
[IO.File]::WriteAllText($freshScriptPath, $freshScript)

$pwshPath = (Get-Process -Id $PID).Path
$proc = Start-Process -FilePath $pwshPath -ArgumentList @('-NoLogo', '-NoProfile', '-File', $freshScriptPath) -Wait -PassThru -NoNewWindow
if ($proc.ExitCode -ne 0) {
    throw "Fresh-process invocation failed with exit code $($proc.ExitCode)"
}

# 3. Determinism check
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice4_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice4Fixture.dll'
$null = Export-LoweredAssembly -SourcePath $fixturePath -ClassName 'Slice4Fixture' -OutputPath $outDll2 -Deterministic
$t2 = Test-LoweredAssembly -AssemblyPath $outDll2

if ($t2.SHA256 -ne $testReceipt.SHA256 -or $t2.MVID -ne $testReceipt.MVID) {
    throw "Determinism check failed: hashes differ ($($testReceipt.SHA256) vs $($t2.SHA256))"
}

[pscustomobject]@{
    Slice              = 4
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
