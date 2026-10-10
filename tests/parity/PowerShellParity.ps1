<#
.SYNOPSIS
    Compares every compiled fixture method with the PowerShell source it came from.
.DESCRIPTION
    The LambdaCompiler parity check compares the emitter against the framework on the
    same expression tree, so it cannot see a tree whose meaning differs from
    the PowerShell source. This check runs each method twice on the same
    inputs (ParityCases.ps1): once as the fixture's own PowerShell class,
    once from the lowered assembly. Results must agree in value and type,
    or both calls must throw. Every divergence is reported; any divergence
    fails the suite.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'
$fixtureRoot = Join-Path $repoRoot 'tests/fixtures'
$outDir = Join-Path $repoRoot 'build/powershell-parity'
$null = New-Item -ItemType Directory -Force -Path $outDir

function Get-SourceType([string] $Path, [string] $Class) {
    # The class as PowerShell itself defines it: dot-source the fixture file and
    # resolve the class by name, which finds PowerShell's own dynamic type.
    . $Path
    $type = $Class -as [type]
    if (-not $type -or -not $type.Assembly.IsDynamic) { throw "$Path does not define PowerShell class $Class." }
    $type
}

function Get-CompiledType([string] $Path, [string] $Class) {
    $dll = Join-Path $outDir "$Class.dll"
    if (-not (Test-Path -LiteralPath $dll)) {
        & $compilerPath -Mode Compile -SourcePath $Path -ClassName $Class -OutputPath $dll -Deterministic | Out-Null
    }
    [Reflection.Assembly]::LoadFile($dll).GetType($Class, $true)
}

function Invoke-Side([type] $Type, [string] $Method, [object[]] $Arguments) {
    # Each side gets its own copy of array arguments, so a method that writes
    # into an array cannot change the other side's input.
    $copy = [object[]]::new($Arguments.Length)
    for ($i = 0; $i -lt $Arguments.Length; $i++) {
        $copy[$i] = if ($Arguments[$i] -is [Array]) { $Arguments[$i].Clone() } else { $Arguments[$i] }
    }
    $Arguments = $copy
    $m = $Type.GetMethod($Method)
    $target = if ($m.IsStatic) { $null } else { [Activator]::CreateInstance($Type) }
    try { [pscustomobject]@{ Value = $m.Invoke($target, $Arguments); Error = $null } }
    catch {
        $e = $_.Exception
        while ($e -is [Reflection.TargetInvocationException] -or $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }
        [pscustomobject]@{ Value = $null; Error = $e.GetType().Name }
    }
}

function Test-Same($A, $B) {
    if ($null -eq $A -or $null -eq $B) { return $null -eq $A -and $null -eq $B }
    if ($A.GetType() -ne $B.GetType()) { return $false }
    if ($A -is [Array]) {
        if ($A.Length -ne $B.Length) { return $false }
        for ($i = 0; $i -lt $A.Length; $i++) { if (-not (Test-Same $A[$i] $B[$i])) { return $false } }
        return $true
    }
    if ($A -is [double] -and [double]::IsNaN($A)) { return [double]::IsNaN($B) }
    if ($A -is [float] -and [float]::IsNaN($A)) { return [float]::IsNaN($B) }
    [object]::Equals($A, $B)
}

function Format-Value($V) {
    if ($null -eq $V) { return '$null' }
    if ($V -is [Array]) { return "$($V.GetType().Name)[$(@($V | ForEach-Object { Format-Value $_ }) -join ',')]" }
    "$V ($($V.GetType().Name))"
}

$divergences = [Collections.Generic.List[string]]::new()
$checked = 0
foreach ($v in . (Join-Path $PSScriptRoot 'ParityCases.ps1')) {
    $path = Join-Path $fixtureRoot $v.Fixture
    $source = Get-SourceType $path $v.Class
    $compiled = Get-CompiledType $path $v.Class
    foreach ($arguments in $v.Inputs) {
        $checked++
        $s = Invoke-Side $source $v.Method $arguments
        $c = Invoke-Side $compiled $v.Method $arguments
        $same = if ($s.Error -or $c.Error) { [bool]$s.Error -and [bool]$c.Error } else { Test-Same $s.Value $c.Value }
        if (-not $same) {
            $label = "$($v.Class).$($v.Method)($(@($arguments | ForEach-Object { Format-Value $_ }) -join ', '))"
            $sText = if ($s.Error) { "throws $($s.Error)" } else { Format-Value $s.Value }
            $cText = if ($c.Error) { "throws $($c.Error)" } else { Format-Value $c.Value }
            $divergences.Add("$label  PowerShell: $sText  compiled: $cText")
        }
    }
}

$divergences | ForEach-Object { Write-Host "  DIVERGE $_" }
[pscustomobject]@{
    ParitySuite = 'PowerShellParity'
    Calls       = $checked
    Divergences = $divergences.Count
    Status      = if ($divergences.Count) { 'FAIL' } else { 'PASS' }
}
if ($divergences.Count) { exit 1 }
