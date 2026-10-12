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
        if ($Arguments[$i] -is [Array]) { $copy[$i] = $Arguments[$i].Clone() }
        else { $copy[$i] = $Arguments[$i] }
    }
    $Arguments = $copy
    $m = $Type.GetMethod($Method)
    $target = if ($m.IsStatic) { $null } else { [Activator]::CreateInstance($Type) }
    try { [pscustomobject]@{ Value = $m.Invoke($target, $Arguments); Error = $null; Detail = $null } }
    catch {
        $e = $_.Exception
        while ($e -is [Reflection.TargetInvocationException] -or $e -is [Management.Automation.MethodInvocationException]) { $e = $e.InnerException }
        [pscustomobject]@{ Value = $null; Error = $e.GetType().Name; Detail = $e.Message }
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

class PredicateSwitchParity {
    static [bool[]] Membership([string] $Value, [string[]] $Values) {
        return [bool[]]@(($Value -in $Values), ($Value -notin $Values), ($Value -cin $Values), ($Value -cnotin $Values))
    }
    static [string] MembershipPredicate([string] $Value) {
        [string] $result = ''
        switch ($Value) {
            { $_ -in 'x', 'y' } { $result += 'a' }
            { $_ -notin 'z', 'y' } { $result += 'b' }
            default { $result += 'd' }
        }
        return $result
    }
    static [string] Ordered([string[]] $Values) {
        [string] $result = ''
        switch ($Values) {
            { $_ -ne '' } { $result += 'a' + $_ }
            'X' { $result += 'b' + $_ }
            { $_ -eq 'x' } { $result += 'c' + $_ }
            default { $result += 'd' + $_ }
        }
        return $result
    }
    static [string] BreakContinue([string[]] $Values) {
        [string] $result = ''
        switch ($Values) {
            { $_ -eq 'skip' } { $result += 's'; continue }
            { $_ -eq 'stop' } { $result += 'b'; break }
            { $true } { $result += $_ }
            default { $result += 'd' }
        }
        return $result
    }
    static [string] Restore([object] $_) {
        [string] $result = ''
        switch ('outer') {
            { $_ -eq 'outer' } {
                $result += $_
                switch ('inner') {
                    { $_ -eq 'inner' } { $result += $_; break }
                    default { $result += 'bad' }
                }
                $result += $_
            }
            default { $result += 'bad' }
        }
        return $result + [string]$_
    }
    static [string] Truth([string] $Value, [int] $Number, [bool[]] $Flags, [string] $Text) {
        [string] $result = ''
        switch ($Value) {
            { $Number } { $result += 'n' }
            { $Flags } { $result += 'a' }
            { $Text } { $result += 's' }
            default { $result += 'd' }
        }
        return $result
    }
}
class StringThrowParity {
    static [void] Fail([string] $Message) { throw ('encoder: ' + $Message) }
}
class CharacterConversionParity {
    static [char] FromInt([int] $Value) { return [char]$Value }
    static [char] FromLong([long] $Value) { return [char]$Value }
    static [int] ToInt([char] $Value) { return [int]$Value }
}

$switchDll = Join-Path $outDir 'PredicateSwitchParity.dll'
& $compilerPath -SourcePath $PSCommandPath -ClassName PredicateSwitchParity -OutputPath $switchDll -Deterministic | Out-Null
$switchType = [Reflection.Assembly]::LoadFile($switchDll).GetType('PredicateSwitchParity', $true)
$switchCases = @(
    @{ Method = 'Membership'; Args = [object[]]@('x', [string[]]@('X', 'y')) },
    @{ Method = 'Membership'; Args = [object[]]@('', [string[]]@($null, '')) },
    @{ Method = 'Membership'; Args = [object[]]@('x', [string[]]@()) },
    @{ Method = 'Membership'; Args = [object[]]@('x', $null) },
    @{ Method = 'MembershipPredicate'; Args = [object[]]@('X') },
    @{ Method = 'MembershipPredicate'; Args = [object[]]@('y') },
    @{ Method = 'MembershipPredicate'; Args = [object[]]@('z') },
    @{ Method = 'Ordered'; Args = [object[]]@(,[string[]]@('x', '', 'y')) },
    @{ Method = 'Ordered'; Args = [object[]]@(,[string[]]@()) },
    @{ Method = 'Ordered'; Args = [object[]]@($null) },
    @{ Method = 'BreakContinue'; Args = [object[]]@(,[string[]]@('x', 'skip', 'y', 'stop', 'z')) },
    @{ Method = 'Restore'; Args = [object[]]@('saved') },
    @{ Method = 'Truth'; Args = [object[]]@('x', 0, [bool[]]@(), '') },
    @{ Method = 'Truth'; Args = [object[]]@('x', -1, [bool[]]@($false), 'yes') },
    @{ Method = 'Truth'; Args = [object[]]@('x', 0, [bool[]]@($false, $false), '') },
    @{ Method = 'Truth'; Args = [object[]]@('x', 0, [bool[]]@($true), '') }
)
foreach ($case in $switchCases) {
    $checked++
    $s = Invoke-Side ([PredicateSwitchParity]) $case.Method $case.Args
    $c = Invoke-Side $switchType $case.Method $case.Args
    if ($s.Error -or $c.Error -or -not (Test-Same $s.Value $c.Value)) {
        $divergences.Add("PredicateSwitchParity.$($case.Method): SMA=$($s.Value) [$($s.Error) $($s.Detail)] lowered=$($c.Value) [$($c.Error) $($c.Detail)]")
    }
}

$throwType = $switchType.Assembly.GetType('StringThrowParity', $true)
$characterType = $switchType.Assembly.GetType('CharacterConversionParity', $true)
foreach ($value in @(-1, 0, 48, 55296, 65535, 65536, [int]::MaxValue)) {
    foreach ($method in @('FromInt', 'FromLong')) {
        $checked++
        $arguments = if ($method -eq 'FromLong') { [object[]]@([long]$value) } else { [object[]]@([int]$value) }
        $s = Invoke-Side ([CharacterConversionParity]) $method $arguments
        $c = Invoke-Side $characterType $method $arguments
        if (($s.Error -or $c.Error) -and -not ($s.Error -and $c.Error) -or
            (-not $s.Error -and -not (Test-Same $s.Value $c.Value))) {
            $divergences.Add("Character conversion $method($value): SMA=$($s.Value) [$($s.Error)] lowered=$($c.Value) [$($c.Error)]")
        }
    }
}
foreach ($value in @([char]0, [char]48, [char]65535)) {
    $checked++
    $s = Invoke-Side ([CharacterConversionParity]) 'ToInt' ([object[]]@($value))
    $c = Invoke-Side $characterType 'ToInt' ([object[]]@($value))
    if ($s.Error -or $c.Error -or -not (Test-Same $s.Value $c.Value)) { $divergences.Add('Char-to-Int32 conversion diverged.') }
}
foreach ($message in @('bad register', "line one`nline two", 'données')) {
    $checked++
    $s = Invoke-Side ([StringThrowParity]) 'Fail' ([object[]]@($message))
    $c = Invoke-Side $throwType 'Fail' ([object[]]@($message))
    if ($s.Detail -cne $c.Detail -or $c.Error -cne 'InvalidOperationException') {
        $divergences.Add("String throw message: SMA=$($s.Detail), lowered=$($c.Detail) [$($c.Error)]")
    }
    $caughtWrapper = $false
    try { $throwType::Fail($message) }
    catch [System.Management.Automation.RuntimeException] {
        $caughtWrapper = $true
        if ($_.Exception -isnot [System.Management.Automation.MethodInvocationException] -or
            $_.Exception.InnerException.GetType() -ne [InvalidOperationException] -or
            $_.Exception.InnerException.Message -cne $s.Detail) {
            throw 'STOP: lowered string throw failed the RuntimeException wrapper-catch assertion.'
        }
    }
    if (-not $caughtWrapper) { throw 'STOP: RuntimeException catch did not catch the lowered string throw.' }
}

$throwRejections = @(
    "class RejectThrow { static [void] Fail([Exception] `$Value) { throw `$Value } }",
    "class RejectThrow { static [void] Fail([System.Management.Automation.ErrorRecord] `$Value) { throw `$Value } }",
    'class RejectThrow { static [void] Fail() { throw 42 } }',
    'class RejectThrow { static [void] Fail() { try { throw ''first'' } catch { throw } } }',
    "class RejectThrow { static [void] Fail() { throw 'first' }`n static [void] Other() { try { throw 'second' } catch [System.Management.Automation.RuntimeException] { } } }",
    'class RejectThrow { static [void] Fail() { try { throw ''first'' } catch { $_.Exception.ErrorRecord } } }',
    'class RejectThrow { static [void] Fail() { try { throw ''first'' } catch { $_ } } }',
    'class RejectThrow { static [void] Fail() { try { throw ''first'' } catch { $Error } } }'
)
for ($caseIndex = 0; $caseIndex -lt $throwRejections.Count; $caseIndex++) {
    $checked++
    $rejectSource = Join-Path $outDir "RejectStringThrow$caseIndex.ps1"
    $rejectOutput = Join-Path $outDir "RejectStringThrow$caseIndex.dll"
    [IO.File]::WriteAllText($rejectSource, $throwRejections[$caseIndex])
    $diagnostic = ''
    try { & $compilerPath -SourcePath $rejectSource -OutputPath $rejectOutput -Deterministic | Out-Null }
    catch { $diagnostic = $_.Exception.Message }
    if (-not $diagnostic.Contains($rejectSource + ':') -or [IO.File]::Exists($rejectOutput)) {
        $divergences.Add("String throw rejection $caseIndex failed: $diagnostic")
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
