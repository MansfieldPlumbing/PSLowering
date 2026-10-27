param([Parameter(Mandatory)][string]$SourceRoot,[string]$WindowsSdkInclude='C:/Program Files (x86)/Windows Kits/10/Include/10.0.26100.0/um')
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$pins=Get-Content (Join-Path $root 'docs/consumer-native-inputs.json') -Raw | ConvertFrom-Json
foreach($pin in $pins) {
    if((Get-FileHash (Join-Path $SourceRoot "$($pin.Repository)/$($pin.Path)")).Hash -cne $pin.SHA256){throw 'ABI header integrity mismatch.'}
}
$jni=[IO.File]::ReadAllText((Join-Path $SourceRoot 'Pwsh/lib/jni.h'))
$body=[regex]::Match($jni,'(?s)struct JNINativeInterface \{(.*?)\n\};').Groups[1].Value
$names=@([regex]::Matches($body,'reserved\d|\(\*(\w+)\)') | ForEach-Object {if($_.Groups[1].Success){$_.Groups[1].Value}else{$_.Value}})
foreach($entry in @{GetVersion=4;CallObjectMethodA=36;CallIntMethodA=51;GetIntField=100;GetStaticIntField=150}.GetEnumerator()) {
    if($names[$entry.Value] -cne $entry.Key){throw "JNI header slot mismatch: $($entry.Key)"}
}
$activity=[IO.File]::ReadAllText((Join-Path $SourceRoot 'Pwsh/lib/native_activity.h'))
$body=[regex]::Match($activity,'(?s)typedef struct ANativeActivityCallbacks \{(.*?)\} ANativeActivityCallbacks;').Groups[1].Value
$names=@([regex]::Matches($body,'\(\*(on\w+)\)') | ForEach-Object {$_.Groups[1].Value})
if($names[7] -cne 'onNativeWindowCreated'){throw 'NativeActivity header callback slot mismatch.'}
$sdkPins=@{'mfobjects.h'='D0610F9BCEA912D6AC4F37851CA2BE2095C507F868DA8F530BAC985B0EB82754';'mfidl.h'='38AD7DE0F51C912541BC7B06B1280EF4E76DAF74546EFA6FFE76D98013F39D94'}
foreach($header in $sdkPins.Keys) {
    if((Get-FileHash (Join-Path $WindowsSdkInclude $header)).Hash -cne $sdkPins[$header]){throw 'Windows SDK header integrity mismatch.'}
}
$objects=[IO.File]::ReadAllText((Join-Path $WindowsSdkInclude 'mfobjects.h'))
$interfaces=[IO.File]::ReadAllText((Join-Path $WindowsSdkInclude 'mfidl.h'))
foreach($entry in @(@('IMFMediaEvent',@{GetType=33;GetStatus=35},$objects),@('IMFMediaEventGenerator',@{GetEvent=3;QueueEvent=6},$objects),@('IMFMediaSession',@{Shutdown=13},$interfaces))) {
    $body=[regex]::Match($entry[2],'(?s)typedef struct '+$entry[0]+'Vtbl\s*\{(.*?)\} '+$entry[0]+'Vtbl;').Groups[1].Value
    $names=@([regex]::Matches($body,'\*\s*(\w+)\s*\)\s*\(') | ForEach-Object {$_.Groups[1].Value})
    foreach($slot in $entry[1].GetEnumerator()){if($names[$slot.Value] -cne $slot.Key){throw "COM header slot mismatch: $($slot.Key)"}}
}
Write-Host 'Consumer ABI headers: 5 JNI slots, 1 NativeActivity slot and 5 COM slots independently verified.'
