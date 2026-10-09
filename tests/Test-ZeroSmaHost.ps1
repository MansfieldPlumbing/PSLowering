[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'

Write-Host "Running Zero-SMA Host and Metadata Admission Suite..."

$slices = @(
    @{ Slice = 1; Fixture = 'Slice1Fixture.ps1'; Class = 'Slice1Fixture'; Out = 'build/slice1/Slice1Fixture.dll' }
    @{ Slice = 2; Fixture = 'Slice2Fixture.ps1'; Class = 'Slice2Fixture'; Out = 'build/slice2/Slice2Fixture.dll' }
    @{ Slice = 4; Fixture = 'Slice4Fixture.ps1'; Class = 'Slice4Fixture'; Out = 'build/slice4/Slice4Fixture.dll' }
    @{ Slice = 5; Fixture = 'Slice5Fixture.ps1'; Class = 'Slice5Fixture'; Out = 'build/slice5/Slice5Fixture.dll' }
    @{ Slice = 6; Fixture = 'Slice6Fixture.ps1'; Class = 'Slice6Fixture'; Out = 'build/slice6/Slice6Fixture.dll' }
    @{ Slice = 7; Fixture = 'Slice7Fixture.ps1'; Class = 'Slice7Fixture'; Out = 'build/slice7/Slice7Fixture.dll' }
    @{ Slice = 8; Fixture = 'Slice8Fixture.ps1'; Class = 'Slice8Fixture'; Out = 'build/slice8/Slice8Fixture.dll' }
    @{ Slice = 9; Fixture = 'Slice9KokoroFixture.ps1'; Class = 'VoiceRowIndexContract'; Out = 'build/slice9/VoiceRowIndexContract.dll' }
)

$results = [System.Collections.Generic.List[psobject]]::new()

foreach ($s in $slices) {
    $fixPath = Join-Path $PSScriptRoot "fixtures/$($s.Fixture)"
    $outDll = Join-Path $repoRoot $s.Out
    $outDir = [IO.Path]::GetDirectoryName($outDll)
    if (-not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    # Ensure freshly exported
    & $compilerPath -Mode Compile -SourcePath $fixPath -ClassName $s.Class -OutputPath $outDll -Deterministic | Out-Null

    # 1. Metadata inspection via Test-LoweredAssembly
    $receipt = & $compilerPath -Mode Inspect -AssemblyPath $outDll

    if ($receipt.SmaReferenced) {
        throw "Slice $($s.Slice) ($($s.Class)) references System.Management.Automation in AssemblyReferences!"
    }

    # 2. Deep TypeReference inspection
    $bytes = [IO.File]::ReadAllBytes($outDll)
    $stream = [IO.MemoryStream]::new($bytes, $false)
    $peReader = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $meta = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        foreach ($trHandle in $meta.TypeReferences) {
            $tr = $meta.GetTypeReference($trHandle)
            $ns = $meta.GetString($tr.Namespace)
            $name = $meta.GetString($tr.Name)

            if ($ns -like 'System.Management.Automation*' -or $name -like '*CallSite*') {
                throw "Slice $($s.Slice) contains prohibited TypeReference: '$ns.$name'"
            }
        }
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    $results.Add([pscustomobject]@{
        Slice           = $s.Slice
        Class           = $s.Class
        AssemblyPath    = $outDll
        SmaReferenced   = $receipt.SmaReferenced
        ClrOnlyAdmitted = $receipt.ClrOnlyAdmitted
        AssemblyRefs    = ($receipt.AssemblyReferences -join ', ')
    })

    Write-Host "  Slice $($s.Slice) ($($s.Class)): Zero-SMA metadata verified. Refs: [$(($receipt.AssemblyReferences -join ', '))]"
}

# 3. Fresh-process execution across all assemblies
Write-Host "Verifying execution across all assemblies in fresh child process..."
$env:TEST_REPO_ROOT = $repoRoot
$childScript = @'
$ErrorActionPreference = 'Stop'
$Root = $env:TEST_REPO_ROOT

# Slice 1
$a1 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice1/Slice1Fixture.dll'))
$t1 = $a1.GetType('Slice1Fixture')
if ($t1.GetMethod('GetAnswer').Invoke($null, $null) -ne 42) { exit 1 }

# Slice 2
$a2 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice2/Slice2Fixture.dll'))
$t2 = $a2.GetType('Slice2Fixture')
if ($t2.GetMethod('AddTwo').Invoke($null, [object[]]@(10, 20)) -ne 30) { exit 2 }

# Slice 4
$a4 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice4/Slice4Fixture.dll'))
$t4 = $a4.GetType('Slice4Fixture')
if ($t4.GetMethod('IntEqual').Invoke($null, [object[]]@(5, 5)) -ne $true) { exit 4 }

# Slice 5
$a5 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice5/Slice5Fixture.dll'))
$t5 = $a5.GetType('Slice5Fixture')
if ($t5.GetMethod('BranchMax').Invoke($null, [object[]]@(100, 50)) -ne 100) { exit 5 }

# Slice 6
$a6 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice6/Slice6Fixture.dll'))
$t6 = $a6.GetType('Slice6Fixture')
$arr = $t6.GetMethod('AllocateIntArray').Invoke($null, [object[]]@(5))
if ($arr.Length -ne 5) { exit 6 }

# Slice 7
$a7 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice7/Slice7Fixture.dll'))
$t7 = $a7.GetType('Slice7Fixture')
$greeting = $t7.GetMethod('BuildGreeting').Invoke($null, [object[]]@('ZeroSMA'))
if ($greeting -ne 'Hello, ZeroSMA!') { exit 7 }

# Slice 8
$a8 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice8/Slice8Fixture.dll'))
$t8 = $a8.GetType('Slice8Fixture')
$parsed = $t8.GetMethod('TryCatchParse').Invoke($null, [object[]]@('invalid', -999))
if ($parsed -ne -999) { exit 8 }

# Slice 9
$a9 = [Reflection.Assembly]::LoadFile((Join-Path $Root 'build/slice9/VoiceRowIndexContract.dll'))
$t9 = $a9.GetType('VoiceRowIndexContract')
if ($t9.GetMethod('VoiceRowIndex').Invoke($null, [object[]]@(510)) -ne 509) { exit 9 }

Write-Output 'FRESH_PROCESS_ALL_SLICES=PASS'
'@

. (Join-Path $PSScriptRoot 'ChildPwsh.ps1')
$pwshCommand = Get-ChildPwshCommand
$childDir = Join-Path $repoRoot 'build/zero-sma-host'
$null = New-Item -ItemType Directory -Force -Path $childDir
$childScriptPath = Join-Path $childDir 'fresh-process.ps1'
Set-Content -LiteralPath $childScriptPath -Value $childScript
$childOut = & $pwshCommand[0] @($pwshCommand | Select-Object -Skip 1) -NoProfile -File $childScriptPath
Write-Host $childOut
if ($LASTEXITCODE -ne 0 -or $childOut -notmatch 'FRESH_PROCESS_ALL_SLICES=PASS') {
    throw "Fresh child process execution failed (ExitCode=$LASTEXITCODE): $childOut"
}

[pscustomobject]@{
    Suite              = 'Test-ZeroSmaHost'
    Status             = 'PASS'
    SlicesVerified     = $results.Count
    AllZeroSma         = $true
    FreshProcessResult = 'PASS'
}
