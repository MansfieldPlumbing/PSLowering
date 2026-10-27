param([switch] $ExecuteOnly, [string] $ArtifactDirectory)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or
    [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription -cne '.NET 11.0.0-rc.1.26425.128') {
    throw 'Portable SIMD verification requires the pinned PowerShell and .NET runtime.'
}
$root = Split-Path $PSScriptRoot -Parent
$compiler = Join-Path $root 'Export-LoweredAssembly.ps1'
$source = Join-Path $PSScriptRoot 'fixtures/PortableVectorFixture.ps1'
$work = if ($ArtifactDirectory) { $ArtifactDirectory } else { Join-Path $root 'build/portable-simd' }
$dll = Join-Path $work 'PortableVectorFixture.dll'
if (-not $ExecuteOnly) {
    $null = New-Item -ItemType Directory -Force $work
    $null = & $compiler -SourcePath $source -ClassName PortableVectorProbe -OutputPath $dll -Deterministic
    $inspection = & $compiler -Mode Inspect -AssemblyPath $dll
    if (-not $inspection.ClrOnlyAdmitted -or @($inspection.AssemblyReferences | Where-Object { $_ -cne 'System.Private.CoreLib' }).Count) {
        throw 'Portable SIMD artifact must reference only CoreLib.'
    }
}
$assembly = [Reflection.Assembly]::LoadFrom($dll)
$lowered = $assembly.GetType('PortableVectorProbe', $true)
. $source
$reference = 'PortableVectorProbe' -as [Type]
$script:comparisons = 0
$script:resultBits = [Collections.Generic.List[string]]::new()
function Compare-Result($expected, $observed, [string] $Label) {
    $expectedItems = @($expected)
    $observedItems = @($observed)
    if ($expectedItems.Count -ne $observedItems.Count) { throw "$Label result length differs." }
    for ($i = 0; $i -lt $expectedItems.Count; $i++) {
        $expectedItem = $expectedItems[$i]
        $observedItem = $observedItems[$i]
        if ($expectedItem -is [single]) {
            $expectedItem = [BitConverter]::SingleToInt32Bits($expectedItem)
            $observedItem = [BitConverter]::SingleToInt32Bits($observedItem)
        } elseif ($expectedItem -is [double]) {
            $expectedItem = [BitConverter]::DoubleToInt64Bits($expectedItem)
            $observedItem = [BitConverter]::DoubleToInt64Bits($observedItem)
        }
        if (-not [object]::Equals($expectedItem, $observedItem)) { throw "$Label lane $i differs." }
        $script:resultBits.Add($Label + ':' + $i + ':' + [Convert]::ToString($observedItem, [Globalization.CultureInfo]::InvariantCulture))
        $script:comparisons++
    }
}
function Compare-Call([string] $Name, [object[]] $Arguments) {
    $expected = $reference.GetMethod($Name).Invoke($null, $Arguments)
    $observed = $lowered.GetMethod($Name).Invoke($null, $Arguments)
    Compare-Result $expected $observed $Name
}
$a = [float[]]@(1, 2, 3, 4)
$b = [float[]]@(1, 1, 1, 1)
Compare-Call Sum4 @($a, $b)
Compare-Result ([float]27) ($lowered.GetMethod('Sum4').Invoke($null, @($a, $b))) 'appendix expected value'
foreach ($pair in @(
    @($a, $b),
    @([float[]]@(-0.0, -1.25, 0.125, 65536), [float[]]@(0, 2, -4, 0.5)),
    @([float[]]@([float]::PositiveInfinity, [float]::NegativeInfinity, [float]::Epsilon, -7), [float[]]@(2, 3, 1, 0.25))
)) {
    Compare-Call Lanes128 $pair
    Compare-Call Sum4 $pair
}
Compare-Call IntLanes @(,[int[]]@(0, -1, 16777217, [int]::MaxValue))
Compare-Call DoubleLanes @([double[]]@(1, -1.25, 0.125, 1e100), [double[]]@(2, 0.5, -4, 1e-50))
$vector = [System.Runtime.Intrinsics.Vector128]::Create([float]3)
$vectors = [System.Runtime.Intrinsics.Vector128[float][]]::new(2)
$vectors[0] = $vector
$vectors[1] = [System.Runtime.Intrinsics.Vector128]::Create([float]-7)
Compare-Call Parameter @($vector, [int]3)
Compare-Call Element @($vectors, [int]-1)
Compare-Call Temporary @([float]-2.5)
Compare-Call Numerics @(,[float[]]::new([System.Numerics.Vector[float]]::Count))
Compare-Call ArrayInference @([int[]]@(4, 7, 9), [int]7)
Compare-Call MirrorInference @()
Compare-Call Virtual @($vector)
Compare-Call InheritedVirtual @([int]0)
$holderType = $assembly.GetType('PortableVectorHolder', $true)
$holder = [Activator]::CreateInstance($holderType)
$holderType.GetField('Value').SetValue($holder, $vector)
$holderType.GetField('Shared').SetValue($null, $vector)
Compare-Result ([float]3) ($holderType.GetMethod('Field').Invoke($holder, @([int]2))) 'struct field'
Compare-Result ([float]3) ($holderType.GetMethod('StaticField').Invoke($null, @([int]2))) 'static struct field'
. (Join-Path $PSScriptRoot 'PortableStructSupport.ps1')
$supportDll = Join-Path $work 'PortableStructSupport.dll'
if (-not $ExecuteOnly) { New-PortableStructAssembly $supportDll }
$support = [Reflection.Assembly]::LoadFrom($supportDll)
$structSource = Join-Path $PSScriptRoot 'fixtures/PortableStructFixture.ps1'
$structDll = Join-Path $work 'PortableStructFixture.dll'
if (-not $ExecuteOnly) { $null = & $compiler -SourcePath $structSource -OutputPath $structDll -Deterministic }
$structType = [Reflection.Assembly]::LoadFrom($structDll).GetType('PortableStructFixture', $true)
. $structSource
$structReference = 'PortableStructFixture' -as [Type]
$counterType = $support.GetType('PortableCounter', $true)
$counter = [Activator]::CreateInstance($counterType)
$counterType.GetField('Value').SetValue($counter, [int]7)
$counters = [Array]::CreateInstance($counterType, 2)
$counters.SetValue($counter, 0); $counters.SetValue($counter, 1)
$nested = [Collections.Generic.List[int[]]]::new()
$nested.Add([int[]]@(1, 2))
foreach ($case in @(
    @{ Name = 'Parameter'; Arguments = @($counter) },
    @{ Name = 'Local'; Arguments = @($counter) },
    @{ Name = 'Array'; Arguments = @(,$counters) },
    @{ Name = 'Virtual'; Arguments = @($counter) },
    @{ Name = 'PropertySetter'; Arguments = @($counter) },
    @{ Name = 'IndexerSetter'; Arguments = @($counter) },
    @{ Name = 'Choose'; Arguments = @([int]8) },
    @{ Name = 'Nested'; Arguments = @(,$nested) }
)) {
    # Reflection boxes value arguments; give each side its own box, so a
    # mutating PowerShell reference call cannot alter the compiled input.
    $referenceArguments = [object[]]$case.Arguments.Clone()
    $loweredArguments = [object[]]$case.Arguments.Clone()
    for ($i = 0; $i -lt $case.Arguments.Count; $i++) {
        $referenceArguments[$i] = [Runtime.CompilerServices.RuntimeHelpers]::GetObjectValue($case.Arguments[$i])
        $loweredArguments[$i] = [Runtime.CompilerServices.RuntimeHelpers]::GetObjectValue($case.Arguments[$i])
    }
    $expected = $structReference.GetMethod($case.Name).Invoke($null, $referenceArguments)
    $observed = $structType.GetMethod($case.Name).Invoke($null, $loweredArguments)
    Compare-Result $expected $observed ('user struct/inference ' + $case.Name)
}
$structHolder = [Activator]::CreateInstance($structType)
$structType.GetField('StoredCounter').SetValue($structHolder, $counter)
Compare-Result ([int]37) ($structType.GetMethod('Field').Invoke($structHolder, @())) 'user struct field'
if (-not $ExecuteOnly) {
    foreach ($rejection in @(
        @{ Name = 'Conflict'; Arguments = '[int]1, [string]::Empty' },
        @{ Name = 'Constrained'; Arguments = '[int]1' },
        @{ Name = 'Uninferred'; Arguments = '[int]1' }
    )) {
        $rejectedSource = Join-Path $work ($rejection.Name + '.ps1')
        $rejectedDll = Join-Path $work ($rejection.Name + '-' + [Guid]::NewGuid().ToString('N') + '.dll')
        Set-Content -LiteralPath $rejectedSource -Value ('class RejectedInference { static [int] Run() { return [PortableInference]::' + $rejection.Name + '(' + $rejection.Arguments + ') } }')
        $diagnostic = $null
        try { $null = & $compiler -SourcePath $rejectedSource -OutputPath $rejectedDll }
        catch { $diagnostic = $_.Exception.Message }
        if (-not $diagnostic -or $diagnostic -notmatch '\[1:\d+\].*Candidates tried:' -or (Test-Path -LiteralPath $rejectedDll)) {
            throw ('Generic rejection failed: ' + $rejection.Name)
        }
    }
}
$architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
$resultsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(($script:resultBits -join "`n"))))
[pscustomobject]@{
    Comparisons = $script:comparisons; ResultsSHA256 = $resultsHash; Appendix = 27
    Architecture = $architecture; PowerShell = $PSVersionTable.PSVersion.ToString()
    Runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
} | Export-Clixml -LiteralPath (Join-Path $work "execution-$architecture.clixml")
Write-Host "Portable SIMD: $script:comparisons bitwise/value comparisons passed; appendix=27; $architecture; PowerShell $($PSVersionTable.PSVersion); $([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription); results SHA-256=$resultsHash."
