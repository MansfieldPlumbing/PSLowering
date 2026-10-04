<#
.SYNOPSIS
    Checks native imports declared with [System.Runtime.InteropServices.LibraryImport].
.DESCRIPTION
    Mainline PowerShell keeps LibraryImport as plain metadata and runs the
    method's throw, so the source oracle cannot check these methods. Each is
    checked here against an independent answer from .NET instead: the process
    ID, String.Length, UTF-8 byte counts and a monotonic tick count. Windows
    only (kernel32). Invalid declarations must be rejected before output.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { Write-Host 'Native import test needs kernel32; skipped on this platform.'; return }

$repoRoot = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $repoRoot 'src/Dev.MansfieldPlumbing.PowerShell.Lowering.psd1') -Force
$outDir = Join-Path $repoRoot 'build/native-imports'
$null = New-Item -ItemType Directory -Force -Path $outDir

$dll = Join-Path $outDir 'NativeImportsFixture.dll'
$null = Export-LoweredAssembly -SourcePath (Join-Path $PSScriptRoot 'fixtures/NativeImportsFixture.ps1') -ClassName NativeImportsFixture -OutputPath $dll -Deterministic
$type = [Reflection.Assembly]::LoadFile($dll).GetType('NativeImportsFixture', $true)

$failures = [Collections.Generic.List[string]]::new()
function Check([string] $Name, $Actual, $Expected) {
    if (-not [object]::Equals($Actual, $Expected)) { $failures.Add("${Name}: got '$Actual' ($($Actual.GetType().Name)), expected '$Expected' ($($Expected.GetType().Name))") }
}

foreach ($name in 'CurrentProcessId', 'Utf16Length', 'Utf8ByteLength', 'GetTickCount64') {
    $m = $type.GetMethod($name)
    if (-not $m.Attributes.HasFlag([Reflection.MethodAttributes]::PinvokeImpl)) { $failures.Add("${name}: not emitted as a P/Invoke method") }
}

Check 'CurrentProcessId' $type.GetMethod('CurrentProcessId').Invoke($null, @()) ([uint][Environment]::ProcessId)
foreach ($text in 'abc', '', 'héllo wörld', 'ಠ_ಠ') {
    Check "Utf16Length('$text')" $type.GetMethod('Utf16Length').Invoke($null, @($text)) $text.Length
    Check "Utf8ByteLength('$text')" $type.GetMethod('Utf8ByteLength').Invoke($null, @($text)) ([Text.Encoding]::UTF8.GetByteCount($text))
}
$t1 = $type.GetMethod('GetTickCount64').Invoke($null, @()); $t2 = $type.GetMethod('GetTickCount64').Invoke($null, @())
if ($t1 -le 0 -or $t2 -lt $t1) { $failures.Add("GetTickCount64 not monotonic: $t1 then $t2") }
Check 'IsCurrentProcess($PID)' $type.GetMethod('IsCurrentProcess').Invoke($null, @([uint][Environment]::ProcessId)) $true
Check 'IsCurrentProcess(0)' $type.GetMethod('IsCurrentProcess').Invoke($null, @([uint]0)) $false
Check 'TotalLength' $type.GetMethod('TotalLength').Invoke($null, @('ab', 'cde')) 5

# Invalid declarations: each must fail with a source position and write nothing.
$header = "[System.Runtime.InteropServices.LibraryImport('kernel32.dll'"
$cases = [ordered]@{
    InstanceImport  = @("    $header)]`n    [uint] M() { throw [System.NotSupportedException]::new() }", 'must be static')
    BodyNotThrow    = @("    $header)]`n    static [uint] M() { return 0 }", 'single throw statement')
    BoolParameter   = @("    $header)]`n    static [int] M([bool] `$b) { throw [System.NotSupportedException]::new() }", 'not blittable')
    StringNoMarshal = @("    $header)]`n    static [int] M([string] `$s) { throw [System.NotSupportedException]::new() }", 'need StringMarshalling')
    SetLastError    = @("    $header, SetLastError = `$true)]`n    static [uint] M() { throw [System.NotSupportedException]::new() }", 'SetLastError is not supported')
}
foreach ($name in $cases.Keys) {
    $member, $expected = $cases[$name]
    $source = Join-Path $outDir "Reject$name.ps1"
    $output = Join-Path $outDir "Reject$name.dll"
    Set-Content -LiteralPath $source -Value "class Reject$name {`n$member`n}"
    $message = $null
    try { Export-LoweredAssembly -SourcePath $source -ClassName "Reject$name" -OutputPath $output | Out-Null } catch { $message = $_.Exception.Message }
    if ($null -eq $message) { $failures.Add("${name}: compiled; expected rejection"); continue }
    if ($message -notmatch '\[\d+:\d+\]' -or $message -notmatch $expected) { $failures.Add("${name}: '$message'") }
    if (Test-Path -LiteralPath $output) { $failures.Add("${name}: output was written") }
}

$failures | ForEach-Object { Write-Host "  FAIL $_" }
[pscustomobject]@{ Suite = 'NativeImports'; Rejections = $cases.Count; Failures = $failures.Count; Status = if ($failures.Count) { 'FAIL' } else { 'PASS' } }
if ($failures.Count) { exit 1 }
