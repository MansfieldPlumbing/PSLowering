<#
.SYNOPSIS
    Checks that source outside the admitted subset is rejected before any output is written.
.DESCRIPTION
    Each case is a one-method class. Export-LoweredAssembly must throw with
    the source position ([line:column]) and a reason matching the expected
    pattern, and must not write the output assembly.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
$compilerPath = Join-Path $repoRoot 'Export-LoweredAssembly.ps1'
$outDir = Join-Path $repoRoot 'build/rejections'
$null = New-Item -ItemType Directory -Force -Path $outDir

$cases = [ordered]@{
    DoWhile           = @('[int] $i = 0; do { $i++ } while ($i -lt 3); return $i', 'DoWhileStatementAst')
    Switch            = @('[int] $i = 1; switch ($i) { 1 { $i = 2 } }; return $i', 'SwitchStatementAst')
    LabeledBreak      = @('[int] $i = 0; :outer while ($true) { break outer }; return $i', 'Labeled break')
    BreakOutsideLoop  = @('[int] $i = 0; break; return $i', 'break outside a loop')
    ContinueOutside   = @('[int] $i = 0; continue; return $i', 'continue outside a loop')
    ForeachNonArray   = @('[int] $n = 3; [int] $s = 0; foreach ($x in $n) { $s++ }; return $s', 'typed one-dimensional array')
    CompoundMixed     = @('[int] $i = 1; [double] $d = 1.5; $i += $d; return $i', 'identical operand types')
    BinaryMixed       = @('[int] $i = 1; [double] $d = 1.5; return $i + $d', 'identical operand types')
    Command           = @('Get-Date; return 0', 'Commands and cmdlets are not allowed')
    Pipeline          = @('[int[]] $a = 1, 2; $a | Out-Null; return 0', 'pipelines are not allowed|not allowed')
}

# Whole-class cases: the source is given in full.
$classCases = [ordered]@{
    DerivedClass       = @("class RejectDerivedClass : System.Collections.ArrayList {`n    static [int] M() { return 0 }`n}", 'only classes deriving from System.Object')
    UntypedProperty    = @("class RejectUntypedProperty {`n    `$Value`n    static [int] M() { return 0 }`n}", 'needs a type')
    UntypedParameter   = @("class RejectUntypedParameter {`n    static [int] M(`$x) { return 0 }`n}", 'needs a type')
    BaseCallWithArgs   = @("class RejectBaseCallWithArgs {`n    RejectBaseCallWithArgs() : base(1) { }`n    static [int] M() { return 0 }`n}", 'base constructor call with arguments')
}

$failures = [Collections.Generic.List[string]]::new()
foreach ($name in @($cases.Keys) + @($classCases.Keys)) {
    $source = Join-Path $outDir "Reject$name.ps1"
    $output = Join-Path $outDir "Reject$name.dll"
    if ($cases.Contains($name)) {
        $body, $expected = $cases[$name]
        Set-Content -LiteralPath $source -Value "class Reject$name {`n    static [int] M() {`n        $body`n    }`n}"
    }
    else {
        $text, $expected = $classCases[$name]
        Set-Content -LiteralPath $source -Value $text
    }
    if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output -Force }
    $message = $null
    try { & $compilerPath -Mode Compile -SourcePath $source -ClassName "Reject$name" -OutputPath $output | Out-Null }
    catch { $message = $_.Exception.Message }
    if ($null -eq $message) { $failures.Add("${name}: compiled; expected rejection"); continue }
    if ($message -notmatch '\[\d+:\d+\]') { $failures.Add("${name}: no source position in '$message'") }
    if ($message -notmatch $expected) { $failures.Add("${name}: '$message' does not match '$expected'") }
    if (Test-Path -LiteralPath $output) { $failures.Add("${name}: output was written") }
}

$failures | ForEach-Object { Write-Host "  FAIL $_" }
[pscustomobject]@{ Suite = 'Rejections'; Cases = $cases.Count + $classCases.Count; Failures = $failures.Count; Status = if ($failures.Count) { 'FAIL' } else { 'PASS' } }
if ($failures.Count) { exit 1 }
