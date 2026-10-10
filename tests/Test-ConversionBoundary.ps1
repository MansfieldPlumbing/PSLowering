<#
.SYNOPSIS
    Pins the one documented difference in reference-to-number conversions.
.DESCRIPTION
    Compiled code converts a reference to a number through System.Convert with
    the invariant culture. PowerShell also reads hexadecimal, exponent and
    decimal text, and converts '' to 0. For those inputs the compiled method
    must throw a FormatException, never return a value PowerShell would not.
    The parity check covers every input where both agree.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'
$outDir = Join-Path $repoRoot 'build/conversion-boundary'
$null = New-Item -ItemType Directory -Force -Path $outDir
$fixture = Join-Path $PSScriptRoot 'fixtures/ObjectConversionFixture.ps1'
$dll = Join-Path $outDir 'ObjectConversionFixture.dll'
$null = & $compilerPath -Mode Compile -SourcePath $fixture -ClassName ObjectConversionFixture -OutputPath $dll -Deterministic
$compiled = [Reflection.Assembly]::LoadFile($dll).GetType('ObjectConversionFixture', $true)
. $fixture
$source = 'ObjectConversionFixture' -as [type]

$failures = [Collections.Generic.List[string]]::new()
foreach ($text in '0x10', '1e3', '5.5', '') {
    $expected = $source::ToInt($text)
    $thrown = $null
    try {
        $value = $compiled.GetMethod('ToInt').Invoke($null, @($text))
        $failures.Add("ToInt('$text') returned $value; PowerShell returns $expected")
    } catch {
        $thrown = $_.Exception
        while ($thrown -is [Reflection.TargetInvocationException] -or $thrown -is [Management.Automation.MethodInvocationException]) { $thrown = $thrown.InnerException }
        if ($thrown -isnot [FormatException]) { $failures.Add("ToInt('$text') threw $($thrown.GetType().Name), expected FormatException") }
    }
}

$failures | ForEach-Object { Write-Host "  FAIL $_" }
[pscustomobject]@{ Suite = 'ConversionBoundary'; Cases = 4; Failures = $failures.Count; Status = if ($failures.Count) { 'FAIL' } else { 'PASS' } }
if ($failures.Count) { exit 1 }
