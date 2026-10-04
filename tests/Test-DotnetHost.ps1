<#
.SYNOPSIS
    Runs a compiled program with the dotnet host alone, with no PowerShell in the process.
.DESCRIPTION
    Compiles tests/fixtures/DotnetHostProgram.ps1 with -EntryPoint Main into an
    executable and its runtime configuration, then starts it as
    `dotnet exec <program>.dll <count>`. The process is the dotnet host and
    the compiled IL; the program itself checks that no
    System.Management.Automation assembly is loaded. Also checks that an
    entry point with an invalid signature is rejected.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force
$outDir = Join-Path $repoRoot 'build/dotnet-host'
$null = New-Item -ItemType Directory -Force -Path $outDir
$program = Join-Path $outDir 'DotnetHostProgram.dll'

$result = Export-LoweredAssembly -SourcePath (Join-Path $PSScriptRoot 'fixtures/DotnetHostProgram.ps1') `
    -ClassName DotnetHostProgram -OutputPath $program -EntryPoint Main -Deterministic
if (-not (Test-Path -LiteralPath $result.RuntimeConfig)) { throw 'No runtime configuration was written beside the program.' }

# The image is an executable: no DLL flag, and an entry point token.
$stream = [IO.File]::OpenRead($program)
try {
    $pe = [Reflection.PortableExecutable.PEReader]::new($stream)
    $isDll = $pe.PEHeaders.CoffHeader.Characteristics.HasFlag([Reflection.PortableExecutable.Characteristics]::Dll)
    $entryToken = $pe.PEHeaders.CorHeader.EntryPointTokenOrRelativeVirtualAddress
}
finally { $stream.Dispose() }
if ($isDll -or $entryToken -eq 0) { throw "Program image: Dll flag $isDll, entry point token 0x$($entryToken.ToString('X8'))." }

$dotnet = (Get-Command dotnet -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$cases = @(
    @{ Argument = '42';  ExitCode = 41;  Output = 'row 41' }
    @{ Argument = '1';   ExitCode = 0;   Output = 'row 0' }
    @{ Argument = '510'; ExitCode = 509; Output = 'row 509' }
)
foreach ($case in $cases) {
    $output = & $dotnet exec $program $case.Argument 2>&1
    $code = $LASTEXITCODE
    if ($code -eq 3) { throw 'The program found a System.Management.Automation assembly loaded in its process.' }
    if ($code -ne $case.ExitCode -or ("$output".Trim() -cne $case.Output)) {
        throw "dotnet exec DotnetHostProgram.dll $($case.Argument): exit $code, output '$output'; expected exit $($case.ExitCode), '$($case.Output)'."
    }
}

# An out-of-range count throws inside the program, which the host reports as a failure.
$null = & $dotnet exec $program '0' 2>&1
if ($LASTEXITCODE -eq 0 -or $LASTEXITCODE -eq 3) { throw "An out-of-range count exited with $LASTEXITCODE; expected an unhandled exception." }

# An entry point with an invalid signature is rejected before anything is written.
$badSource = Join-Path $outDir 'BadEntryPoint.ps1'
Set-Content -LiteralPath $badSource -Value "class BadEntryPoint {`n    static [string] Main([int] `$x) {`n        return 'x'`n    }`n}"
$badOutput = Join-Path $outDir 'BadEntryPoint.dll'
$rejected = $false
try { Export-LoweredAssembly -SourcePath $badSource -ClassName BadEntryPoint -OutputPath $badOutput -EntryPoint Main | Out-Null }
catch { $rejected = $_.Exception.Message -match 'must be static, return \[int\] or \[void\]' }
if (-not $rejected -or (Test-Path -LiteralPath $badOutput)) { throw 'An entry point returning [string] was not rejected before output.' }

[pscustomobject]@{
    Suite      = 'DotnetHost'
    Host       = $dotnet
    Runtime    = (Get-Content -LiteralPath $result.RuntimeConfig -Raw | ConvertFrom-Json).runtimeOptions.framework.version
    Cases      = $cases.Count + 2
    Status     = 'PASS'
}
