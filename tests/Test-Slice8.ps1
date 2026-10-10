[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice8Fixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice8'
$outDll = Join-Path $outDir 'Slice8Fixture.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting Slice8Fixture..."
$exportReceipt = & $compilerPath -Mode Compile `
    -SourcePath $fixturePath `
    -ClassName 'Slice8Fixture' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = & $compilerPath -Mode Inspect -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 8 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('Slice8Fixture', $true)

# ThrowPositive success
$res1 = $type.GetMethod('ThrowPositive').Invoke($null, [object[]]@(5))
if ($res1 -ne 10) { throw "ThrowPositive(5) failed: expected 10, got $res1" }

# ThrowPositive exception
$threw = $false
try {
    $null = $type.GetMethod('ThrowPositive').Invoke($null, [object[]]@(-1))
}
catch {
    if ($_.Exception.InnerException -is [System.ArgumentOutOfRangeException] -or $_.Exception -is [System.ArgumentOutOfRangeException]) {
        $threw = $true
    }
}
if (-not $threw) { throw "ThrowPositive(-1) did not throw ArgumentOutOfRangeException" }

# TryCatchParse
$p1 = $type.GetMethod('TryCatchParse').Invoke($null, [object[]]@('123', 0))
if ($p1 -ne 123) { throw "TryCatchParse('123', 0) failed: expected 123, got $p1" }

$p2 = $type.GetMethod('TryCatchParse').Invoke($null, [object[]]@('invalid', -99))
if ($p2 -ne -99) { throw "TryCatchParse('invalid', -99) failed: expected -99, got $p2" }

# TryFinallyExecution
$fin = $type.GetMethod('TryFinallyExecution').Invoke($null, [object[]]@(5))
if ($fin -ne 15) { throw "TryFinallyExecution(5) failed: expected 15, got $fin" }

# MultiCatch
$m1 = $type.GetMethod('MultiCatch').Invoke($null, [object[]]@('42'))
if ($m1 -ne 42) { throw "MultiCatch('42') failed: expected 42, got $m1" }

$m2 = $type.GetMethod('MultiCatch').Invoke($null, [object[]]@('null'))
if ($m2 -ne -1) { throw "MultiCatch('null') failed: expected -1, got $m2" }

$m3 = $type.GetMethod('MultiCatch').Invoke($null, [object[]]@('not-a-number'))
if ($m3 -ne -2) { throw "MultiCatch('not-a-number') failed: expected -2, got $m3" }

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$childCmd = @"
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$t = `$asm.GetType('Slice8Fixture')

`$r1 = `$t.GetMethod('ThrowPositive').Invoke(`$null, [object[]]@(5))

`$threw = `$false
try {
    `$null = `$t.GetMethod('ThrowPositive').Invoke(`$null, [object[]]@(-1))
} catch {
    if (`$_.Exception.InnerException -is [System.ArgumentOutOfRangeException] -or `$_.Exception -is [System.ArgumentOutOfRangeException]) { `$threw = `$true }
}

`$p1 = `$t.GetMethod('TryCatchParse').Invoke(`$null, [object[]]@('456', 0))
`$p2 = `$t.GetMethod('TryCatchParse').Invoke(`$null, [object[]]@('bad', -7))
`$fin = `$t.GetMethod('TryFinallyExecution').Invoke(`$null, [object[]]@(10))
`$m1 = `$t.GetMethod('MultiCatch').Invoke(`$null, [object[]]@('100'))
`$m2 = `$t.GetMethod('MultiCatch').Invoke(`$null, [object[]]@('null'))
`$m3 = `$t.GetMethod('MultiCatch').Invoke(`$null, [object[]]@('err'))

if (`$r1 -eq 10 -and `$threw -and `$p1 -eq 456 -and `$p2 -eq -7 -and `$fin -eq 20 -and `$m1 -eq 100 -and `$m2 -eq -1 -and `$m3 -eq -2) {
    Write-Output 'FRESH_PROCESS_SLICE8=PASS'
} else {
    Write-Output 'FRESH_PROCESS_SLICE8=FAIL'
}
"@

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
$childScriptPath = Join-Path $outDir 'fresh-process.ps1'
Set-Content -LiteralPath $childScriptPath -Value $childCmd
$childOut = & $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoProfile -File $childScriptPath
Write-Host $childOut
if ($childOut -notmatch 'FRESH_PROCESS_SLICE8=PASS') {
    throw "Fresh process verification failed: $childOut"
}

# 3. Byte determinism verification
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice8_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'Slice8Fixture.dll'
& $compilerPath -Mode Compile `
    -SourcePath $fixturePath `
    -ClassName 'Slice8Fixture' `
    -OutputPath $outDll2 `
    -Deterministic | Out-Null

$bytes1 = [IO.File]::ReadAllBytes($outDll)
$bytes2 = [IO.File]::ReadAllBytes($outDll2)
$match = [Linq.Enumerable]::SequenceEqual([byte[]]$bytes1, [byte[]]$bytes2)

if (-not $match) {
    throw "Non-deterministic build detected! Hashes differ between consecutive runs."
}

[pscustomobject]@{
    Slice              = 8
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
