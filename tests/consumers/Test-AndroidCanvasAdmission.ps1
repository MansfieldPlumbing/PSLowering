param([Parameter(Mandatory)][string]$SourceRoot)
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$source=Join-Path $SourceRoot 'Pwsh/modules/AndroidCanvas.psm1'
$manifest=Get-Content (Join-Path $root 'docs/native-reference-identities.json') -Raw | ConvertFrom-Json
$identity=$manifest | Where-Object {$_.Repository -eq 'Pwsh' -and $_.Path -eq 'modules/AndroidCanvas.psm1'}
if((Get-FileHash $source).Hash -cne $identity.SHA256){throw 'AndroidCanvas source integrity mismatch.'}
$work=Join-Path $root 'build/consumer-native/android'
$null=New-Item -ItemType Directory -Force $work
$output=Join-Path $work ('AndroidCanvas-'+[guid]::NewGuid().ToString('N')+'.dll')
try {
    $null=& (Join-Path $root 'Export-LoweredAssembly.ps1') -SourcePath $source -OutputPath $output
    throw 'Unexpected admission of an unadapted function module.'
} catch {
    $diagnostic=$_.Exception.Message
    if($diagnostic -cne 'No class definition found in source.'){throw}
    if(Test-Path $output){throw 'Rejected module wrote an artifact.'}
    [ordered]@{Source='Pwsh/modules/AndroidCanvas.psm1';Commit=$identity.Commit;Admitted=$false;Diagnostic=$diagnostic;ArtifactWritten=$false;Classification='Typed class entrypoint boundary; the native adapter is a separate fixture.'} | ConvertTo-Json | Set-Content (Join-Path $work 'admission.json')
    Write-Host 'Pwsh AndroidCanvas: original function module rejected before output; typed adapter is measured separately.'
}
