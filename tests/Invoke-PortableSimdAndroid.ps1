<#
.SYNOPSIS
    Executes the Windows-built portable SIMD regressions in an isolated Android
    app process, restoring and verifying the original startup files afterwards.
#>
param(
    [Parameter(Mandatory)][string] $Adb,
    [string] $Device = '0',
    [string] $Package = 'dev.mansfieldplumbing.kokoro'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($Package -notmatch '^dev\.mansfieldplumbing\.(kokoro|pwsh)$') { throw 'Unrecognized test package.' }
$root = Split-Path $PSScriptRoot -Parent
$artifacts = Join-Path $root 'build/portable-simd'
$identity = 'pslowering-portable-' + [Guid]::NewGuid().ToString('N')
$staging = "/data/local/tmp/$identity"
$target = "files/$identity"
$work = Join-Path $artifacts $identity
$null = New-Item -ItemType Directory -Path $work
function Invoke-AdbClient {
    # The pinned client's response contract uses absent optional properties.
    Set-StrictMode -Off
    & $Adb @args
}
function Invoke-Android([string] $Command) {
    $result = Invoke-AdbClient shell -Api -Device $Device $Command
    if ($result.ExitCode) { throw 'Android test operation failed; original startup files are retained in the probe backup.' }
    return ([string]$result.Stdout).Trim()
}
$null = Invoke-Android "run-as $Package mkdir $target"
$null = Invoke-Android "mkdir $staging"
$startup = [ordered]@{}
$changed = $false
try {
    foreach ($name in @('Start.ps1', 'PROFILE.PS1', 'Profile.ps1')) {
        $present = (Invoke-Android "if run-as $Package test -f files/$name; then echo yes; fi") -ceq 'yes'
        $digest = if ($present) { (Invoke-Android "run-as $Package sha256sum files/$name").Split(' ')[0] } else { $null }
        if ($present) { $null = Invoke-Android "run-as $Package cp files/$name $target/$name.original" }
        $startup[$name] = [pscustomobject]@{ Present = $present; SHA256 = $digest }
    }
    $files = [ordered]@{
        'tests/Test-PortableSimd.ps1' = (Join-Path $PSScriptRoot 'Test-PortableSimd.ps1')
        'tests/PortableStructSupport.ps1' = (Join-Path $PSScriptRoot 'PortableStructSupport.ps1')
        'tests/fixtures/PortableVectorFixture.ps1' = (Join-Path $PSScriptRoot 'fixtures/PortableVectorFixture.ps1')
        'tests/fixtures/PortableStructFixture.ps1' = (Join-Path $PSScriptRoot 'fixtures/PortableStructFixture.ps1')
        'artifacts/PortableVectorFixture.dll' = (Join-Path $artifacts 'PortableVectorFixture.dll')
        'artifacts/PortableStructFixture.dll' = (Join-Path $artifacts 'PortableStructFixture.dll')
        'artifacts/PortableStructSupport.dll' = (Join-Path $artifacts 'PortableStructSupport.dll')
    }
    # This authored wrapper contains no downloaded text or input-driven code.
    $wrapper = Join-Path $work 'Run.ps1'
    $wrapperText = @'
$ErrorActionPreference = 'Stop'
$probe = [IO.Path]::Combine($PSScriptRoot, '__PROBE__')
$receipt = [ordered]@{ Status = 'FAIL'; PowerShell = $PSVersionTable.PSVersion.ToString(); Runtime = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription; Architecture = [Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString() }
try {
    $receipt.Detail = (& ([IO.Path]::Combine($probe, 'tests/Test-PortableSimd.ps1')) -ExecuteOnly -ArtifactDirectory ([IO.Path]::Combine($probe, 'artifacts')) 6>&1 | Out-String).Trim()
    $receipt.Execution = Import-Clixml -LiteralPath ([IO.Path]::Combine($probe, 'artifacts/execution-Arm64.clixml'))
    $receipt.Status = 'PASS'
} catch { $receipt.Detail = $_.Exception.Message }
[pscustomobject]$receipt | Export-Clixml -LiteralPath ([IO.Path]::Combine($probe, 'receipt.clixml'))
'@
    # Substitute one declared directory token in this generated build wrapper.
    [IO.File]::WriteAllText($wrapper, $wrapperText.Replace('__PROBE__', $identity))
    $files['Run.ps1'] = $wrapper
    foreach ($entry in $files.GetEnumerator()) {
        $name = [IO.Path]::GetFileName($entry.Key)
        $null = Invoke-AdbClient push -Api -Device $Device $entry.Value "$staging/$name"
        $parent = [IO.Path]::GetDirectoryName($entry.Key).Replace('\', '/')
        if ($parent) { $null = Invoke-Android "run-as $Package mkdir -p $target/$parent" }
        $null = Invoke-Android "run-as $Package cp $staging/$name $target/$($entry.Key)"
        $digest = (Invoke-Android "run-as $Package sha256sum $target/$($entry.Key)").Split(' ')[0]
        if ($digest -ine (Get-FileHash -LiteralPath $entry.Value).Hash) { throw 'Android test transfer digest mismatch.' }
    }
    # Fatal invalid IL can abort the CLR. Use one fresh process for this test
    # run, rather than expose an active numeric job to a regression failure.
    $null = Invoke-Android "am force-stop $Package"
    $changed = $true
    foreach ($name in $startup.Keys) { $null = Invoke-Android "run-as $Package cp $target/Run.ps1 files/$name" }
    $null = Invoke-Android "monkey -p $Package -c android.intent.category.LAUNCHER 1"
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        Start-Sleep -Milliseconds 500
        $complete = (Invoke-Android "if run-as $Package test -f $target/receipt.clixml; then echo yes; fi") -ceq 'yes'
    } while (-not $complete -and $clock.Elapsed.TotalSeconds -lt 60)
    if (-not $complete) { throw 'Android SIMD test did not produce a receipt within 60 seconds.' }
    $bytes = [byte[]](Invoke-AdbClient exec-out -Api -Device $Device "run-as $Package cat $target/receipt.clixml")
    $receiptPath = Join-Path $artifacts 'android-receipt.clixml'
    [IO.File]::WriteAllBytes($receiptPath, $bytes)
    $result = Import-Clixml -LiteralPath $receiptPath
    $windows = Import-Clixml -LiteralPath (Join-Path $artifacts 'execution-X64.clixml')
    if ($result.Status -ceq 'PASS' -and $result.Execution.ResultsSHA256 -cne $windows.ResultsSHA256) { throw 'Android results differ from the Windows x64 results.' }
    $result | Format-List
    if ($result.Status -cne 'PASS' -or $result.Architecture -cne 'Arm64') { throw 'Android portable SIMD qualification failed.' }
} finally {
    if ($changed) { $null = Invoke-Android "am force-stop $Package" }
    foreach ($name in $startup.Keys) {
        if ($startup[$name].Present) {
            if ($changed) { $null = Invoke-Android "run-as $Package cp $target/$name.original files/$name" }
            $digest = (Invoke-Android "run-as $Package sha256sum files/$name").Split(' ')[0]
            if ($digest -cne $startup[$name].SHA256) { throw 'Original startup hash differs; probe backup retained.' }
        } elseif ($changed) { $null = Invoke-Android "run-as $Package rm -f files/$name" }
    }
    # Both directories were created exclusively for this run with fixed roots.
    if ($target -match '^files/pslowering-portable-[0-9a-f]{32}$' -and $staging -match '^/data/local/tmp/pslowering-portable-[0-9a-f]{32}$') {
        $null = Invoke-Android "run-as $Package rm -r $target"
        $null = Invoke-Android "rm -r $staging"
    }
    Write-Host 'Android test startup files restored and SHA-256 verified.'
}
