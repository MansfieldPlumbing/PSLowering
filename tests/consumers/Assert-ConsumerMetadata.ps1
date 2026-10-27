param([Parameter(Mandatory)][string]$AssemblyPath,[Parameter(Mandatory)][ValidateSet('QuickPS','Pwsh')][string]$Consumer)
$ErrorActionPreference='Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'NativeMetadata.ps1')
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'LegacyMetadata.ps1')
$metadata=Read-LegacyAssembly $AssemblyPath
if($metadata.References.Count -ne 1 -or $metadata.References[0].Name -cne 'System.Private.CoreLib'){throw 'Consumer adapter contains external references.'}
$typeName=if($Consumer -eq 'QuickPS'){'QuickPSComFixture'}else{'PwshNativeFixture'}
$type=[Reflection.Assembly]::LoadFile([IO.Path]::GetFullPath($AssemblyPath)).GetType($typeName,$true)
# Independent ECMA-335 decoding: Stdcall=02, Cdecl=01, Int32=08,
# UInt32=09, native int=18, void=01; function-pointer input is excluded.
$signatures=if($Consumer -eq 'QuickPS'){
    @{IntOut='0202081818';GetEvent='020308180918';QueueEvent='0205081808180818';SessionShutdown='02010818'}
}else{
    @{Int1='01010818';Int3='010308181818';Int4='01040818181818';Ptr4='01041818181818';WindowCall='0102011818'}
}
foreach($name in $signatures.Keys){
    $method=$type.GetMethod($name)
    $calls=@(Get-NativeInstructions $method | Where-Object Name -CEQ 'calli')
    if($calls.Count -ne 1 -or [Convert]::ToHexString($method.Module.ResolveSignature($calls[0].Token)) -cne $signatures[$name]){throw "Consumer ABI signature mismatch: $name"}
}
if($Consumer -eq 'Pwsh'){
    $method=$type.GetMethod('CreatedAddress')
    $targets=@(Get-NativeInstructions $method | Where-Object Name -CEQ 'ldftn')
    if($targets.Count -ne 1 -or $method.Module.ResolveMethod($targets[0].Token).Name -cne 'Created'){throw 'Consumer callback address does not use typed ldftn.'}
    $attributes=$type.GetMethod('Created').GetCustomAttributes([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)
    if($attributes.Count -ne 1 -or $attributes[0].CallConvs.Count -ne 1 -or $attributes[0].CallConvs[0] -ne [Runtime.CompilerServices.CallConvCdecl]){throw 'Consumer callback convention mismatch.'}
}
Write-Host "$Consumer consumer metadata: exact calli signatures and CoreLib-only references passed."
