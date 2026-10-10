# Runs only after copying the compiler and input to an unrelated directory.
param()
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$scriptPath=Join-Path $PSScriptRoot 'Export-LoweredAssembly.ps1'
$null=& $scriptPath -Mode Compile -SourcePath ./input.ps1 -OutputPath ./Isolated.dll
$report=& $scriptPath -Mode Inspect -AssemblyPath ./Isolated.dll
if($report.SmaReferenced -or -not $report.MVID) { throw 'Isolated output invalid.' }
if(-not (& $scriptPath -Mode Capability)) { throw 'Capability mode failed.' }
$source=[Management.Automation.Language.Parser]::ParseFile("$PSScriptRoot/input.ps1",[ref]$null,[ref]$null)
$method=$source.Find({param($n) $n -is [Management.Automation.Language.FunctionMemberAst] -and $n.Name -ceq 'GetAnswer'},$true)
$expression=& $scriptPath -Mode Expression -MethodAst $method
if($expression.Lambda.Compile().DynamicInvoke() -ne 42) { throw 'Expression mode failed.' }
$help=Get-Help -Name $scriptPath -Full | Out-String
$switchHelp=& $scriptPath -Help | Out-String
if($help -notmatch 'SourcePath' -or $switchHelp -notmatch 'Capability') { throw 'Script help failed.' }
$null=& $scriptPath -SourcePath ./native.ps1 -OutputPath ./NativeIsolated.dll -EntryPoint Main
$native=& $scriptPath -Mode Inspect -AssemblyPath ./NativeIsolated.dll
if($native.SmaReferenced -or ($native.AssemblyReferences -join '|') -cne 'System.Private.CoreLib') { throw 'Isolated native compilation failed.' }
$null=& dotnet exec ./NativeIsolated.dll 2>&1
if($LASTEXITCODE) { throw 'Isolated native zero-SMA execution failed.' }
