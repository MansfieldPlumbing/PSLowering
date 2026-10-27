param([string]$Device='SM-S911U',[Parameter(Mandatory)][string]$SourceRoot,[switch]$NativeAbiOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
if($PSVersionTable.PSVersion.ToString() -cne '7.7.0-preview.5' -or [object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion -notlike '11.0.0-rc.1.26425.128*') { throw 'Use the pinned verification toolchain.' }
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$work=Join-Path $root 'build/consumer-native/android'
$null=New-Item -ItemType Directory -Force $work
$adbPath=(Get-Command adb -CommandType Application | Select-Object -First 1).Source
$package='dev.mansfieldplumbing.pwsh'
$remoteDirectory='files/pslowering-consumer-spike'
$backup='files/Profile.pslowering-backup.ps1'
$manifest=Get-Content (Join-Path $root 'docs/native-reference-identities.json') -Raw | ConvertFrom-Json
$jni=Join-Path $SourceRoot 'Pwsh/scripts/probes/jni/Jni.ps1'
$expected=$manifest | Where-Object {$_.Repository -eq 'Pwsh' -and $_.Path -eq 'scripts/probes/jni/Jni.ps1'}
if((Get-FileHash $jni).Hash -cne $expected.SHA256) { throw 'JNI source digest mismatch.' }
$targets=@(foreach($line in (& $adbPath devices | Select-Object -Skip 1 | Where-Object {$_ -match "`tdevice$"})) {
    $identifier=($line -split "`t")[0]
    if((& $adbPath -s $identifier shell getprop ro.product.model).Trim() -eq $Device) { $identifier }
})
if($targets.Count -ne 1) { throw 'Select exactly one attached device by model.' }
$deviceId=$targets[0]
function Adb([Parameter(ValueFromRemainingArguments)][string[]]$Arguments) {
    $result=& $adbPath -s $deviceId @Arguments 2>&1
    if($LASTEXITCODE) { throw 'ADB operation failed; inspect local device state.' }
    $result
}
# File transfer follows Pwsh Invoke-DeviceScript's exec-in/run-as protocol.
# Process streams preserve bytes and keep identifiers out of command output.
function Transfer([string]$Local,[string]$Remote) {
    $info=[Diagnostics.ProcessStartInfo]::new($adbPath)
    foreach($argument in @('-s',$deviceId,'exec-in','run-as',$package,'sh','-c',"cat > $Remote")) { $info.ArgumentList.Add($argument) }
    $info.UseShellExecute=$false; $info.CreateNoWindow=$true; $info.RedirectStandardInput=$true; $info.RedirectStandardError=$true
    $process=[Diagnostics.Process]::Start($info)
    $stream=[IO.File]::OpenRead($Local)
    try {$stream.CopyTo($process.StandardInput.BaseStream)} finally {$stream.Dispose();$process.StandardInput.Close()}
    if(-not $process.WaitForExit(30000)) {$process.Kill();throw 'Device transfer timeout.'}
    if($process.ExitCode) { throw 'Byte-preserving device transfer failed.' }
    $process.Dispose()
    $remoteHash=((Adb @('shell','run-as',$package,'sha256sum',$Remote)) -split '\s+')[0]
    if($remoteHash -ine (Get-FileHash $Local).Hash) { throw 'Device transfer digest mismatch.' }
}
$null=Adb @('shell','run-as',$package,'true')
$listing=@(Adb @('shell','run-as',$package,'ls','files'))
if($listing -contains 'pslowering-consumer-spike' -or $listing -contains 'Profile.pslowering-backup.ps1') { throw 'Probe destination or recovery backup already exists; refusing to overwrite.' }
$hadProfile=$listing -contains 'Profile.ps1'
$profileHash=if($hadProfile){((Adb @('shell','run-as',$package,'sha256sum','files/Profile.ps1')) -split '\s+')[0]}else{$null}
$receipt=[ordered]@{Model=$Device;Abi=(Adb @('shell','getprop','ro.product.cpu.abi')).Trim();Android=(Adb @('shell','getprop','ro.build.version.release')).Trim();SDK=(Adb @('shell','getprop','ro.build.version.sdk')).Trim()}
$receipt.InstalledApkSourceCommit='UNVERIFIED; pinned binding scripts are staged separately'
$receipt.InstalledApks=@(foreach($location in (Adb @('shell','pm','path',$package))) {
    $apkPath=$location -replace '^package:',''
    if($apkPath -notmatch '^/data/app/.+\.apk$'){throw 'Unexpected installed APK location.'}
    [pscustomobject]@{Name=[IO.Path]::GetFileName($apkPath);SHA256=((Adb @('shell','sha256sum',$apkPath)) -split '\s+')[0]}
})
$null=& (Join-Path $root 'Export-LoweredAssembly.ps1') -SourcePath (Join-Path $PSScriptRoot 'PwshNativeFixture.ps1') -OutputPath (Join-Path $work 'PwshNativeFixture.dll')
& (Join-Path $PSScriptRoot 'Assert-ConsumerMetadata.ps1') -AssemblyPath (Join-Path $work 'PwshNativeFixture.dll') -Consumer Pwsh
[IO.File]::WriteAllText((Join-Path $work 'Profile.ps1'),'& ([IO.Path]::Combine($PSScriptRoot,''pslowering-consumer-spike/AndroidProfile.ps1''))')
if($NativeAbiOnly) { [IO.File]::AppendAllText((Join-Path $work 'Profile.ps1'),' -NativeAbiOnly') }
$staged=$false; $saved=$false
try {
    $null=Adb @('shell','am','force-stop',$package)
    if($hadProfile){$null=Adb @('shell','run-as',$package,'mv','files/Profile.ps1',$backup);$saved=$true}
    $null=Adb @('shell','run-as',$package,'mkdir',$remoteDirectory);$staged=$true
    foreach($item in @(@($jni,'Jni.ps1'),@((Join-Path $work 'PwshNativeFixture.dll'),'PwshNativeFixture.dll'),@((Join-Path $PSScriptRoot 'PwshNativeFixture.ps1'),'PwshNativeFixture.ps1'),@((Join-Path $PSScriptRoot 'AndroidProfile.ps1'),'AndroidProfile.ps1'))) {
        Transfer $item[0] "$remoteDirectory/$($item[1])"
    }
    Transfer (Join-Path $work 'Profile.ps1') 'files/Profile.ps1'
    $component=(Adb @('shell','cmd','package','resolve-activity','--brief','-c','android.intent.category.LAUNCHER',$package) | Select-Object -Last 1).Trim()
    if($component -notmatch '^dev\.mansfieldplumbing\.pwsh/') {throw 'Unexpected launcher component.'}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $started=(Adb @('shell','date','+%s')).Trim()
    $launch=Adb @('shell','am','start','-W','-n',$component)
    $receipt.LaunchMilliseconds=[int](($launch | Where-Object {$_ -match '^TotalTime:'}) -replace '\D','')
    $found=$false; $cycled=$false
    for($attempt=0;$attempt -lt 30;$attempt++) {
        Start-Sleep -Milliseconds 500
        $files=@(Adb @('shell','run-as',$package,'ls',$remoteDirectory))
        if($files -contains 'receipt.txt') {
            $progress=Adb @('shell','run-as',$package,'cat',"$remoteDirectory/receipt.txt")
            if($progress -contains 'Passed=RmFsc2U=') {$found=$true;break}
        }
        if($files -contains 'receipt.txt' -and -not $cycled -and $files -notcontains 'callback.txt') {
            # A surface may already exist before Profile runs. Ask Android to
            # background/resume this activity; never call the callback by hand.
            $null=Adb @('shell','input','keyevent','KEYCODE_HOME')
            Start-Sleep -Milliseconds 500
            $null=Adb @('shell','am','start','-W','-n',$component)
            $cycled=$true
        }
        if($files -contains 'receipt.txt' -and ($files -contains 'callback.txt' -or $clock.Elapsed.TotalSeconds -gt 12)) {$found=$true;break}
    }
    if(-not $found) {
        $processId=(Adb @('shell','pidof',$package)).Trim()
        Adb @('logcat','-d',"--pid=$processId",'-s','Pwsh:V') | Set-Content (Join-Path $work 'host.log')
        throw 'Device receipt timeout; full host evidence is under build/consumer-native/android/host.log.'
    }
    $payload=Adb @('shell','run-as',$package,'cat',"$remoteDirectory/receipt.txt")
    $payload | Set-Content (Join-Path $work 'payload-receipt.txt')
    $probeData=[ordered]@{Timings=@()}
    foreach($line in $payload) {
        $key,$value=$line -split '=',2
        if($key -eq 'Timing') {
            $side,$sample,$iterations,$elapsed=$value -split ','
            $probeData.Timings+=@([pscustomobject]@{Side=$side;Sample=[int]$sample;Iterations=[int]$iterations;Milliseconds=[double]::Parse($elapsed,[Globalization.CultureInfo]::InvariantCulture)})
            continue
        }
        $probeData[$key]=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($value))
    }
    $receipt.Probe=[pscustomobject]$probeData
    if($files -contains 'callback.txt') {
        $callback=(Adb @('shell','run-as',$package,'cat',"$remoteDirectory/callback.txt")).Trim().Split(',')
        $receipt.CallbackEvidence=$callback -join ','
        if($callback.Count -ne 3){throw 'Compiled NativeActivity callback reported an exception.'}
        $receipt.CallbackCount=[int]$callback[0]
        $receipt.CallbackThread=[int]$callback[1]
        $receipt.ProfileThread=[int]$callback[2]
    }
    $receipt.Alive=@(Adb @('shell','pidof',$package)).Count -gt 0
    $processId=(Adb @('shell','pidof',$package)).Trim()
    $receipt.CrashLines=@(Adb @('logcat','-d','-b','crash',"--pid=$processId",'-T',$started,'-v','raw') | Where-Object {$_ -and $_ -notmatch '^-+ beginning'}).Count
    $receipt.SurfaceLifecycleCycled=$cycled
    $receipt.AssemblySHA256=(Get-FileHash (Join-Path $work 'PwshNativeFixture.dll')).Hash
} finally {
    $null=Adb @('shell','am','force-stop',$package)
    if($saved){$null=Adb @('shell','run-as',$package,'mv',$backup,'files/Profile.ps1')}
    elseif(-not $hadProfile -and $staged){$null=Adb @('shell','run-as',$package,'rm','-f','files/Profile.ps1')}
    if($staged){
        # Fixed, exclusively created probe directory inside this package's files.
        $null=Adb @('shell','run-as',$package,'rm','-r',$remoteDirectory)
    }
    $receipt.ProfileRestored=if($hadProfile -and $saved){((Adb @('shell','run-as',$package,'sha256sum','files/Profile.ps1')) -split '\s+')[0] -ceq $profileHash}else{-not $hadProfile}
    $receipt | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $work 'receipt.json')
}
if($receipt.Probe.Passed -cne 'True'){throw "Device probe blocked: $($receipt.Probe.Blocker)"}
if(-not $receipt.Alive -or $receipt.CrashLines -ne 0 -or -not $receipt.ProfileRestored){throw 'Device lifecycle, crash or profile-restoration gate failed.'}
if(-not $receipt.Contains('CallbackCount') -or $receipt.CallbackCount -lt 1 -or $receipt.CallbackThread -ne $receipt.ProfileThread){throw 'NativeActivity callback execution/thread gate failed.'}
Write-Host "Android ARM64 ($($receipt.Probe.Mode)): $($receipt.Probe.ParityComparisons) binding comparisons passed; OS callback passed; profile restored."
