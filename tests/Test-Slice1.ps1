[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/PSPersistence.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice1Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice1'
$outDll = Join-Path $outDir 'Slice1Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice1Fixture..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'Slice1Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 1 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice1Fixture', $true)

$ans = $type.GetMethod('GetAnswer').Invoke($null, @())
if ($ans -ne 42) { throw "GetAnswer returned '$ans', expected 42" }

$fls = $type.GetMethod('GetFalse').Invoke($null, @())
if ($fls -ne $false) { throw "GetFalse returned '$fls', expected false" }

$str = $type.GetMethod('GetGreeting').Invoke($null, @())
if ($str -ne 'hello') { throw "GetGreeting returned '$str', expected 'hello'" }

$nullRet = $type.GetMethod('DoNothing').Invoke($null, @())
if ($null -ne $nullRet) { throw "DoNothing returned a value, expected null" }

$inst = [Activator]::CreateInstance($type)
$instVal = $type.GetMethod('GetInstanceVal').Invoke($inst, @())
if ($instVal -ne 100) { throw "GetInstanceVal returned '$instVal', expected 100" }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$freshScript = @"
`$ErrorActionPreference = 'Stop'
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$type = `$asm.GetType('Slice1Fixture', `$true)
if (`$type.GetMethod('GetAnswer').Invoke(`$null, @()) -ne 42) { exit 1 }
if (`$type.GetMethod('GetFalse').Invoke(`$null, @()) -ne `$false) { exit 2 }
if (`$type.GetMethod('GetGreeting').Invoke(`$null, @()) -ne 'hello') { exit 3 }
`$inst = [Activator]::CreateInstance(`$type)
if (`$type.GetMethod('GetInstanceVal').Invoke(`$inst, @()) -ne 100) { exit 4 }
Write-Output 'FRESH_PROCESS_SLICE1=PASS'
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
$reproDir = Join-Path $repoRoot 'build/slice1_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice1Fixture.dll'
$null = Export-LoweredAssembly -SourcePath $fixturePath -ClassName 'Slice1Fixture' -OutputPath $outDll2 -Deterministic
$t2 = Test-LoweredAssembly -AssemblyPath $outDll2

if ($t2.SHA256 -ne $testReceipt.SHA256 -or $t2.MVID -ne $testReceipt.MVID) {
    throw "Determinism check failed: hashes differ ($($testReceipt.SHA256) vs $($t2.SHA256))"
}

[pscustomobject]@{
    Slice              = 1
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
