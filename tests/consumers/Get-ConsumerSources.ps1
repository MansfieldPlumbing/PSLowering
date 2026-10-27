param([string]$Destination)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
if(-not $Destination){$Destination=Join-Path $root 'build/consumer-native/sources'}
$manifest=Get-Content (Join-Path $root 'docs/native-reference-identities.json') -Raw | ConvertFrom-Json
$manifest+=@(Get-Content (Join-Path $root 'docs/consumer-native-inputs.json') -Raw | ConvertFrom-Json)
$selected=@($manifest | Where-Object {
    ($_.Repository -eq 'QuickPS' -and $_.Path -in @('src/Native.ps1','src/managed/MediaSessionEvents.ps1','src/managed/AudioCapture.ps1')) -or
    ($_.Repository -eq 'Pwsh' -and $_.Path -in @('scripts/probes/jni/Jni.ps1','modules/AndroidCanvas.psm1','lib/jni.h','lib/native_activity.h'))
})
if($selected.Count -ne 7){throw 'Consumer source manifest is incomplete.'}
foreach($record in $selected){
    $path=Join-Path $Destination "$($record.Repository)/$($record.Path)"
    if(Test-Path $path){
        if((Get-FileHash $path).Hash -cne $record.SHA256){throw 'Cached consumer source digest mismatch; refusing to replace it.'}
        continue
    }
    $response=& gh api "repos/MansfieldPlumbing/$($record.Repository)/contents/$($record.Path)?ref=$($record.Commit)"
    if($LASTEXITCODE){throw 'Immutable source acquisition failed.'}
    $data=$response | ConvertFrom-Json
    $bytes=[Convert]::FromBase64String($data.content)
    $blob=[Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")+$bytes)).ToLowerInvariant()
    $digest=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))
    if($blob -cne $record.GitBlob -or $digest -cne $record.SHA256){throw 'Immutable source integrity mismatch.'}
    $null=New-Item -ItemType Directory -Force (Split-Path $path)
    [IO.File]::WriteAllBytes($path,$bytes)
}
Write-Host "consumer sources: $($selected.Count) immutable files verified."
