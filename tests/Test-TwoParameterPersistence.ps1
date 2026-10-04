[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$experiment = Join-Path $repositoryRoot 'experiments/Invoke-OneParameterPersistenceProof.ps1'
$source = Join-Path $PSScriptRoot 'fixtures/TwoParameterProbe.ps1'
$buildRoot = Join-Path $repositoryRoot 'build'
$outputDirectory = Join-Path $buildRoot 'two-parameter-proof'
$outputAssembly = Join-Path $outputDirectory 'TwoParameterProbe.dll'

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$exportResult = & $experiment `
    -SourcePath $source `
    -ClassName TwoParameterProbe `
    -MethodName AddTwo `
    -OutputPath $outputAssembly

if (@($exportResult).Count -ne 1 -or
    -not $exportResult.FileWritten -or
    $exportResult.DynamicNodesAfter -ne 0) {
    throw 'The two-parameter persistence experiment did not return one successful structured result.'
}

$assembly = [Reflection.Assembly]::LoadFrom($outputAssembly)
$type = $assembly.GetType('TwoParameterProbe', $true)
$instance = [Activator]::CreateInstance($type)
$result = $type.GetMethod('AddTwo').Invoke($instance, [object[]]@(40, 2))

if ($result -ne 42) {
    throw "Reloaded TwoParameterProbe.AddTwo(40, 2) returned '$result', not 42."
}

"TWO_PARAMETER_PERSISTENCE=PASS"
"POWERSHELL_VERSION=$($PSVersionTable.PSVersion)"
"RUNTIME=$([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
"ASSEMBLY=$outputAssembly"
