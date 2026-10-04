[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice2Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice2'
$outDll = Join-Path $outDir 'Slice2Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice2Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice2Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 2 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice2Fixture', $true)

# AddTwo
$r1 = $type.GetMethod('AddTwo').Invoke($null, [object[]]@(15, 27))
if ($r1 -ne 42) { throw "AddTwo(15, 27) returned '$r1', expected 42" }

# Compute
$r2 = $type.GetMethod('Compute').Invoke($null, [object[]]@(10, 4))
if ($r2 -ne 84) { throw "Compute(10, 4) returned '$r2', expected 84" }

# OverflowAdd: Int32 overflow must fail, as it does in a typed PowerShell method
$overflowed = $false
try { $null = $type.GetMethod('OverflowAdd').Invoke($null, [object[]]@([int]::MaxValue, 1)) }
catch {
    if ($_.Exception.GetBaseException() -isnot [OverflowException]) { throw "OverflowAdd threw $($_.Exception.GetBaseException().GetType().FullName), expected System.OverflowException" }
    $overflowed = $true
}
if (-not $overflowed) { throw 'OverflowAdd returned a value for Int32.MaxValue + 1; expected System.OverflowException' }

# Negate
$r4 = $type.GetMethod('Negate').Invoke($null, [object[]]@(42))
if ($r4 -ne -42) { throw "Negate(42) returned '$r4', expected -42" }

# FloatMath
$r5 = $type.GetMethod('FloatMath').Invoke($null, [object[]]@(5.0, 4.0))
if ($r5 -ne 10.0) { throw "FloatMath(5.0, 4.0) returned '$r5', expected 10.0" }

# Calculate (Instance method)
$inst = [Activator]::CreateInstance($type)
$r6 = $type.GetMethod('Calculate').Invoke($inst, [object[]]@(6, 7))
if ($r6 -ne 47) { throw "Calculate(6, 7) returned '$r6', expected 47" }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$freshScript = @"
`$ErrorActionPreference = 'Stop'
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$type = `$asm.GetType('Slice2Fixture', `$true)
if (`$type.GetMethod('AddTwo').Invoke(`$null, [object[]]@(15, 27)) -ne 42) { exit 1 }
if (`$type.GetMethod('Compute').Invoke(`$null, [object[]]@(10, 4)) -ne 84) { exit 2 }
try { `$null = `$type.GetMethod('OverflowAdd').Invoke(`$null, [object[]]@([int]::MaxValue, 1)); exit 3 } catch { if (`$_.Exception.GetBaseException() -isnot [OverflowException]) { exit 3 } }
if (`$type.GetMethod('Negate').Invoke(`$null, [object[]]@(42)) -ne -42) { exit 4 }
if (`$type.GetMethod('FloatMath').Invoke(`$null, [object[]]@(5.0, 4.0)) -ne 10.0) { exit 5 }
`$inst = [Activator]::CreateInstance(`$type)
if (`$type.GetMethod('Calculate').Invoke(`$inst, [object[]]@(6, 7)) -ne 47) { exit 6 }
Write-Output 'FRESH_PROCESS_SLICE2=PASS'
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
$reproDir = Join-Path $repoRoot 'build/slice2_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice2Fixture.dll'
$null = Export-LoweredAssembly -SourcePath $fixturePath -ClassName 'Slice2Fixture' -OutputPath $outDll2 -Deterministic
$t2 = Test-LoweredAssembly -AssemblyPath $outDll2

if ($t2.SHA256 -ne $testReceipt.SHA256 -or $t2.MVID -ne $testReceipt.MVID) {
    throw "Determinism check failed: hashes differ ($($testReceipt.SHA256) vs $($t2.SHA256))"
}

[pscustomobject]@{
    Slice              = 2
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
