param(
    [switch] $FailFast = $true,
    [string] $PwshPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$pwshExe = if ($PwshPath) { $PwshPath } else { [Environment]::ProcessPath }
$repoRoot = Split-Path $PSScriptRoot -Parent
$buildDir = Join-Path $repoRoot 'build'
if (-not (Test-Path $buildDir)) {
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
}

$testSuites = @(
    @{ Name = 'Baseline: Authentic-SMA Persistence Proof'; Path = 'tests/Test-OneParameterPersistence.ps1'; Args = @() }
    @{ Name = 'Baseline: Two-Parameter SMA Persistence';    Path = 'tests/Test-TwoParameterPersistence.ps1'; Args = @() }
    @{ Name = 'Baseline: Authentic-SMA Compiler Probe';   Path = 'probes/Test-SmaCompilation.ps1';           Args = @('-BaselineOnly') }
    @{ Name = 'Slice 1: Basic Signatures & Constants';     Path = 'tests/Test-Slice1.ps1';                  Args = @() }
    @{ Name = 'Slices 2-3: Params, Locals, Arithmetic';    Path = 'tests/Test-Slice2.ps1';                  Args = @() }
    @{ Name = 'Slice 4: IEEE 754 & Boolean Logic';         Path = 'tests/Test-Slice4.ps1';                  Args = @() }
    @{ Name = 'Slice 5: Control Flow, Loops, Early Return';Path = 'tests/Test-Slice5.ps1';                  Args = @() }
    @{ Name = 'Slice 6: Typed Arrays & Indexing';          Path = 'tests/Test-Slice6.ps1';                  Args = @() }
    @{ Name = 'Slice 7: Reflected Calls & Constructors';   Path = 'tests/Test-Slice7.ps1';                  Args = @() }
    @{ Name = 'Slice 8: Structured Exceptions & Regions';  Path = 'tests/Test-Slice8.ps1';                  Args = @() }
    @{ Name = 'Slice 9: Kokoro VoiceRowIndex Contract';    Path = 'tests/Test-Slice9.ps1';                  Args = @() }
    @{ Name = 'Slice 10: Microsoft LambdaCompiler Oracle'; Path = 'tests/oracle/MicrosoftLambdaCompilerOracle.ps1'; Args = @() }
    @{ Name = 'Slice 11: Fresh Zero-SMA Host Smoke Test';  Path = 'tests/Test-ZeroSmaHost.ps1';             Args = @() }
    @{ Name = 'Slice 12: PowerShell Source Oracle';        Path = 'tests/oracle/PowerShellSourceOracle.ps1'; Args = @() }
    @{ Name = 'Consumer: Pwsh Persisted-Method Admission';  Path = 'tests/consumers/Test-PwshAdmission.ps1'; Args = @() }
)

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " PSPersistence Consolidated Verification Suite" -ForegroundColor Cyan
Write-Host " PowerShell: $pwshExe" -ForegroundColor Cyan
Write-Host " Runtime:    $([Runtime.InteropServices.RuntimeInformation]::FrameworkDescription)" -ForegroundColor Cyan
Write-Host " OS:         $([Runtime.InteropServices.RuntimeInformation]::OSDescription)" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$results = [System.Collections.Generic.List[psobject]]::new()
$allPassed = $true
$swTotal = [System.Diagnostics.Stopwatch]::StartNew()

foreach ($suite in $testSuites) {
    $scriptFullPath = Join-Path $repoRoot $suite.Path
    Write-Host "`n>>> Running: $($suite.Name) [$($suite.Path)]..." -ForegroundColor Yellow

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $cmdArgs = @('-NoProfile', '-File', $scriptFullPath) + $suite.Args

    $outputLines = [System.Collections.Generic.List[string]]::new()
    $exitCode = 0
    try {
        $pinfo = [System.Diagnostics.ProcessStartInfo]::new()
        $pinfo.FileName = $pwshExe
        foreach ($arg in $cmdArgs) {
            $pinfo.ArgumentList.Add($arg)
        }
        $pinfo.WorkingDirectory = $repoRoot
        $pinfo.RedirectStandardOutput = $true
        $pinfo.RedirectStandardError = $true
        $pinfo.UseShellExecute = $false

        $proc = [System.Diagnostics.Process]::Start($pinfo)
        $stdOutTask = $proc.StandardOutput.ReadToEndAsync()
        $stdErrTask = $proc.StandardError.ReadToEndAsync()
        $proc.WaitForExit()

        $exitCode = $proc.ExitCode
        $stdout = $stdOutTask.Result
        $stderr = $stdErrTask.Result

        if ($stdout) {
            Write-Host $stdout.TrimEnd()
            $outputLines.Add($stdout)
        }
        if ($stderr) {
            Write-Host $stderr.TrimEnd() -ForegroundColor DarkRed
            $outputLines.Add($stderr)
        }
    }
    catch {
        $exitCode = -1
        $err = $_.Exception.ToString()
        Write-Host $err -ForegroundColor Red
        $outputLines.Add($err)
    }
    $sw.Stop()

    $status = if ($exitCode -eq 0) { 'PASS' } else { 'FAIL' }
    if ($status -eq 'FAIL') {
        $allPassed = $false
    }

    $res = [pscustomobject]@{
        Name        = $suite.Name
        ScriptPath  = $suite.Path
        Status      = $status
        ExitCode    = $exitCode
        DurationMs  = [math]::Round($sw.Elapsed.TotalMilliseconds, 1)
    }
    $results.Add($res)

    Write-Host "--- Result: $status (ExitCode=$exitCode, Duration=$($res.DurationMs)ms)" -ForegroundColor $(if ($status -eq 'PASS') { 'Green' } else { 'Red' })

    if ($status -eq 'FAIL' -and $FailFast) {
        Write-Host "`n[FATAL] Suite failed with FailFast enabled. Halting runner." -ForegroundColor Red
        break
    }
}

$swTotal.Stop()

Write-Host "`n================================================================================" -ForegroundColor Cyan
Write-Host " Verification Summary" -ForegroundColor Cyan
Write-Host "================================================================================" -ForegroundColor Cyan

$results | Format-Table -Property Name, Status, ExitCode, DurationMs -AutoSize

$receipt = [pscustomobject]@{
    Timestamp          = [DateTime]::UtcNow.ToString('o')
    OverallStatus      = if ($allPassed) { 'PASS' } else { 'FAIL' }
    TotalDurationMs    = [math]::Round($swTotal.Elapsed.TotalMilliseconds, 1)
    TotalSuites        = $testSuites.Count
    SuitesRun          = $results.Count
    SuitesPassed       = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
    SuitesFailed       = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
    PowerShellVersion  = $PSVersionTable.PSVersion.ToString()
    RuntimeDescription = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
    Architecture       = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
    Results            = $results.ToArray()
}

$receiptPath = Join-Path $buildDir 'verification-receipt.json'
$receiptJson = $receipt | ConvertTo-Json -Depth 5
[IO.File]::WriteAllText($receiptPath, $receiptJson)

Write-Host "Verification receipt written to: $receiptPath" -ForegroundColor Cyan
Write-Host "Overall Result: $($receipt.OverallStatus) ($($receipt.SuitesPassed)/$($receipt.TotalSuites) suites passed in $($receipt.TotalDurationMs)ms)" -ForegroundColor $(if ($allPassed) { 'Green' } else { 'Red' })

if (-not $allPassed) {
    exit 1
}
