[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$modulePath = Join-Path $repoRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1'
Import-Module $modulePath -Force

Write-Host "Comparing compiled IL with Microsoft LambdaCompiler..."

# Helper to test parity between Microsoft LambdaCompiler and our Lowered Assembly
$script:ReferenceTypeCache = @{}

function Get-ReferenceEmittedType {
    param(
        [Parameter(Mandatory)][string] $FixturePath,
        [Parameter(Mandatory)][string] $ClassName
    )

    if ($script:ReferenceTypeCache.ContainsKey($ClassName)) {
        return $script:ReferenceTypeCache[$ClassName]
    }

    $outDir = Join-Path $repoRoot 'build/lambdacompiler-parity'
    if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    $outDll = Join-Path $outDir "$ClassName.dll"

    Export-LoweredAssembly -SourcePath $FixturePath -ClassName $ClassName -OutputPath $outDll -Deterministic | Out-Null
    $asm = [Reflection.Assembly]::LoadFile($outDll)
    $type = $asm.GetType($ClassName, $true)

    $script:ReferenceTypeCache[$ClassName] = $type
    return $type
}

function Test-MethodParity {
    param(
        [Parameter(Mandatory)][string] $FixturePath,
        [Parameter(Mandatory)][string] $ClassName,
        [Parameter(Mandatory)][string] $MethodName,
        [Parameter(Mandatory)][object[]] $TestInputs
    )

    $ast = [System.Management.Automation.Language.Parser]::ParseFile($FixturePath, [ref]$null, [ref]$null)
    $classAst = $ast.Find({
        param($n)
        $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.Name -eq $ClassName
    }, $true)
    $mAst = $classAst.Members | Where-Object { $_.Name -eq $MethodName }
    $lowered = ConvertTo-TypedExpression -MethodAst $mAst

    # 1. Compile with Microsoft LambdaCompiler
    $msDelegate = $lowered.Lambda.Compile()

    # 2. Compile via our pure-PowerShell IL Emitter
    $type = Get-ReferenceEmittedType -FixturePath $FixturePath -ClassName $ClassName
    $ourMethod = $type.GetMethod($MethodName)
    $target = if ($lowered.IsStatic) { $null } else { [Activator]::CreateInstance($type) }

    foreach ($inputs in $TestInputs) {
        $msResult = $null
        $msError = $null
        try {
            $msArguments = if ($lowered.HasThis) { [object[]](@($null) + $inputs) } else { $inputs }
            $msResult = $msDelegate.DynamicInvoke($msArguments)
        }
        catch {
            $msError = if ($_.Exception.InnerException) { $_.Exception.InnerException.GetType().FullName } else { $_.Exception.GetType().FullName }
        }

        $ourResult = $null
        $ourError = $null
        try {
            $ourResult = $ourMethod.Invoke($target, $inputs)
        }
        catch {
            $ourError = if ($_.Exception.InnerException) { $_.Exception.InnerException.GetType().FullName } else { $_.Exception.GetType().FullName }
        }

        if ($msError -or $ourError) {
            if ($msError -ne $ourError) {
                throw "LambdaCompiler error mismatch on $ClassName.$($MethodName) - MS='$msError' vs OURS='$ourError'"
            }
        }
        else {
            if ($msResult -ne $ourResult) {
                throw "LambdaCompiler value mismatch on $ClassName.$($MethodName) - MS='$msResult' vs OURS='$ourResult'"
            }
        }
    }

    Write-Host "  Parity MATCH: $ClassName.$MethodName ($($TestInputs.Count) inputs verified)"
}

# 1. Slice 2: Arithmetic & Locals
$fix2 = Join-Path $repoRoot 'tests/fixtures/Slice2Fixture.ps1'
Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'AddTwo' -TestInputs @(
    [object[]]@(0, 0),
    [object[]]@(15, 27),
    [object[]]@(-10, 20),
    [object[]]@(([int]::MaxValue - 1), 1)
)

Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'Compute' -TestInputs @(
    [object[]]@(10, 4),
    [object[]]@(20, 5),
    [object[]]@(100, 1)
)

Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'OverflowAdd' -TestInputs @(
    [object[]]@([int]::MaxValue, 1),
    [object[]]@([int]::MinValue, -1)
)

Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'Negate' -TestInputs @(
    [object[]]@(0),
    [object[]]@(42),
    [object[]]@(-99)
)

Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'FloatMath' -TestInputs @(
    [object[]]@(10.0, 5.0),
    [object[]]@(2.5, 4.0),
    [object[]]@(0.0, 100.0)
)

Test-MethodParity -FixturePath $fix2 -ClassName 'Slice2Fixture' -MethodName 'Calculate' -TestInputs @(
    [object[]]@(10, 2),
    [object[]]@(0, 5),
    [object[]]@(-4, 3)
)

# 2. Slice 4: Comparisons & Logic
$fix4 = Join-Path $repoRoot 'tests/fixtures/Slice4Fixture.ps1'
Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'IntEqual' -TestInputs @(
    [object[]]@(10, 10),
    [object[]]@(10, 20)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'IntLess' -TestInputs @(
    [object[]]@(5, 10),
    [object[]]@(10, 5),
    [object[]]@(7, 7)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'IntLessOrEqual' -TestInputs @(
    [object[]]@(5, 10),
    [object[]]@(10, 10),
    [object[]]@(10, 5)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'FloatLessOrEqual' -TestInputs @(
    [object[]]@(2.5, 3.5),
    [object[]]@(3.5, 3.5),
    [object[]]@([double]::NaN, 1.0),
    [object[]]@(1.0, [double]::NaN)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'LogicalAnd' -TestInputs @(
    [object[]]@($true, $true),
    [object[]]@($true, $false),
    [object[]]@($false, $true),
    [object[]]@($false, $false)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'LogicalOr' -TestInputs @(
    [object[]]@($true, $false),
    [object[]]@($false, $false),
    [object[]]@($true, $true)
)

Test-MethodParity -FixturePath $fix4 -ClassName 'Slice4Fixture' -MethodName 'LogicalNot' -TestInputs @(
    [object[]]@($true),
    [object[]]@($false)
)

# 3. Slice 5: Control Flow & Loops
$fix5 = Join-Path $repoRoot 'tests/fixtures/Slice5Fixture.ps1'
Test-MethodParity -FixturePath $fix5 -ClassName 'Slice5Fixture' -MethodName 'BranchMax' -TestInputs @(
    [object[]]@(10, 20),
    [object[]]@(50, 25),
    [object[]]@(0, 0)
)

Test-MethodParity -FixturePath $fix5 -ClassName 'Slice5Fixture' -MethodName 'NestedIf' -TestInputs @(
    [object[]]@(150),
    [object[]]@(50),
    [object[]]@(-10),
    [object[]]@(0)
)

Test-MethodParity -FixturePath $fix5 -ClassName 'Slice5Fixture' -MethodName 'SumTo' -TestInputs @(
    [object[]]@(0),
    [object[]]@(5),
    [object[]]@(10)
)

Test-MethodParity -FixturePath $fix5 -ClassName 'Slice5Fixture' -MethodName 'EarlyReturnInLoop' -TestInputs @(
    [object[]]@(5),
    [object[]]@(200),
    [object[]]@(0)
)

Test-MethodParity -FixturePath $fix5 -ClassName 'Slice5Fixture' -MethodName 'WhileCountdown' -TestInputs @(
    [object[]]@(5),
    [object[]]@(0),
    [object[]]@(10)
)

# 4. Slice 9: Kokoro VoiceRowIndex Contract
$fix9 = Join-Path $repoRoot 'tests/fixtures/Slice9KokoroFixture.ps1'
Test-MethodParity -FixturePath $fix9 -ClassName 'VoiceRowIndexContract' -MethodName 'VoiceRowIndex' -TestInputs @(
    [object[]]@(1),
    [object[]]@(50),
    [object[]]@(256),
    [object[]]@(510),
    [object[]]@(0),
    [object[]]@(-5),
    [object[]]@(511)
)

[pscustomobject]@{
    ParitySuite = 'LambdaCompilerParity'
    Status      = 'PASS'
    DifferentialParity = '100% MATCH'
}
