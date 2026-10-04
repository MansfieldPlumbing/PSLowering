[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$modulePath = Join-Path $repoRoot 'src/PSPersistence.psd1'
Import-Module $modulePath -Force

$fixturePath = Join-Path $PSScriptRoot 'fixtures/Slice9KokoroFixture.ps1'
$outDir = Join-Path $repoRoot 'build/slice9'
$outDll = Join-Path $outDir 'VoiceRowIndexContract.dll'

if (Test-Path $outDir) {
    Remove-Item -Recurse -Force $outDir
}
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

Write-Host "Exporting VoiceRowIndexContract..."
$exportReceipt = Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'VoiceRowIndexContract' `
    -OutputPath $outDll `
    -Deterministic

Write-Host "Testing assembly metadata..."
$testReceipt = Test-LoweredAssembly -AssemblyPath $outDll

if (-not $testReceipt.ClrOnlyAdmitted) {
    throw "Slice 9 assembly references System.Management.Automation!"
}

# 1. In-process invocation
Write-Host "Verifying in-process invocation across Kokoro contract..."
$asm = [Reflection.Assembly]::LoadFrom($outDll)
$type = $asm.GetType('VoiceRowIndexContract', $true)
$voiceMethod = $type.GetMethod('VoiceRowIndex')
$readyMethod = $type.GetMethod('SynthesisReady')

# SynthesisReady
if ($readyMethod.Invoke($null, $null) -ne $false) {
    throw "SynthesisReady() failed: expected false; the consumer contract reports no synthesis"
}

# Test all valid phoneme counts 1..510
for ($c = 1; $c -le 510; $c++) {
    $idx = $voiceMethod.Invoke($null, [object[]]@($c))
    if ($idx -ne ($c - 1)) {
        throw "VoiceRowIndex($c) failed: expected $($c - 1), got $idx"
    }
}

# Test out-of-range counts
foreach ($bad in @([int]::MinValue, -10, -1, 0, 511, 512, 1000, [int]::MaxValue)) {
    $threw = $false
    try {
        $null = $voiceMethod.Invoke($null, [object[]]@($bad))
    }
    catch {
        $base = $_.Exception.GetBaseException()
        if ($base -is [System.ArgumentOutOfRangeException]) {
            if ($base.ParamName -cne 'phonemeCount') {
                throw "VoiceRowIndex($bad) named parameter '$($base.ParamName)', expected 'phonemeCount'"
            }
            $threw = $true
        }
    }
    if (-not $threw) {
        throw "VoiceRowIndex($bad) did not throw ArgumentOutOfRangeException"
    }
}

# 2. Fresh-process invocation
Write-Host "Verifying fresh-process invocation..."
$childCmd = @"
`$asm = [Reflection.Assembly]::LoadFrom('$outDll')
`$t = `$asm.GetType('VoiceRowIndexContract')
`$m = `$t.GetMethod('VoiceRowIndex')
`$r = `$t.GetMethod('SynthesisReady')

if (`$r.Invoke(`$null, `$null) -ne `$false) { exit 1 }

# Spot check boundary points
if (`$m.Invoke(`$null, [object[]]@(1)) -ne 0) { exit 2 }
if (`$m.Invoke(`$null, [object[]]@(256)) -ne 255) { exit 3 }
if (`$m.Invoke(`$null, [object[]]@(510)) -ne 509) { exit 4 }

`$threw0 = `$false
try { `$null = `$m.Invoke(`$null, [object[]]@(0)) }
catch { `$threw0 = `$true }

`$threw511 = `$false
try { `$null = `$m.Invoke(`$null, [object[]]@(511)) }
catch { `$threw511 = `$true }

if (`$threw0 -and `$threw511) {
    Write-Output 'FRESH_PROCESS_SLICE9=PASS'
} else {
    Write-Output 'FRESH_PROCESS_SLICE9=FAIL'
}
"@

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
$childOut = & $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoProfile -Command $childCmd
Write-Host $childOut
if ($childOut -notmatch 'FRESH_PROCESS_SLICE9=PASS') {
    throw "Fresh process verification failed: $childOut"
}

# 3. Byte determinism verification
Write-Host "Verifying byte determinism..."
$reproDir = Join-Path $repoRoot 'build/slice9_repro'
New-Item -ItemType Directory -Force -Path $reproDir | Out-Null
$outDll2 = Join-Path $reproDir 'VoiceRowIndexContract.dll'
Export-LoweredAssembly `
    -SourcePath $fixturePath `
    -ClassName 'VoiceRowIndexContract' `
    -OutputPath $outDll2 `
    -Deterministic | Out-Null

$bytes1 = [IO.File]::ReadAllBytes($outDll)
$bytes2 = [IO.File]::ReadAllBytes($outDll2)
$match = [Linq.Enumerable]::SequenceEqual([byte[]]$bytes1, [byte[]]$bytes2)

if (-not $match) {
    throw "Non-deterministic build detected! Hashes differ between consecutive runs."
}

[pscustomobject]@{
    Slice              = 9
    Status             = 'PASS'
    Assembly           = $outDll
    Length             = $bytes1.Length
    SHA256             = $testReceipt.SHA256
    MVID               = $testReceipt.MVID
    SmaReferenced      = $testReceipt.SmaReferenced
    ClrOnlyAdmitted    = $testReceipt.ClrOnlyAdmitted
    FreshProcessResult = 'PASS'
    DeterminismMatch   = 'PASS'
    KokoroParity510    = 'PASS'
}
