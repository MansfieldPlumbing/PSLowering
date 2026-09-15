[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repositoryRoot = Split-Path $PSScriptRoot -Parent
$experiment = Join-Path $repositoryRoot 'experiments/Invoke-OneParameterPersistenceProof.ps1'
$source = Join-Path $PSScriptRoot 'fixtures/OneParameterProbe.ps1'
$outputDirectory = Join-Path $repositoryRoot 'build/one-parameter-proof'
$outputAssembly = Join-Path $outputDirectory 'OneParameterProbe.dll'

New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null

$exportResult = & $experiment `
    -SourcePath $source `
    -ClassName OneParameterProbe `
    -MethodName AddOne `
    -OutputPath $outputAssembly

if (@($exportResult).Count -ne 1 -or
    -not $exportResult.FileWritten -or
    $exportResult.DynamicNodesAfter -ne 0) {
    throw 'The persistence experiment did not return one successful structured result.'
}

$assembly = [Reflection.Assembly]::LoadFrom($outputAssembly)
$type = $assembly.GetType('OneParameterProbe', $true)
$instance = [Activator]::CreateInstance($type)
$result = $type.GetMethod('AddOne').Invoke($instance, [object[]]@(41))

if ($result -ne 42) {
    throw "Reloaded OneParameterProbe.AddOne(41) returned '$result', not 42."
}

"ONE_PARAMETER_PERSISTENCE=PASS"
"POWERSHELL_VERSION=$($PSVersionTable.PSVersion)"
"RUNTIME=$([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)"
"ASSEMBLY=$outputAssembly"
