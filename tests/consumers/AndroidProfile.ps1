# Local-only Profile payload. Staged into a fresh private directory by the
# device probe; never invoked by GitHub Actions. The host owns the UI thread.
param([switch]$NativeAbiOnly)
$ErrorActionPreference='Stop'
$receipt=[ordered]@{PowerShell=$PSVersionTable.PSVersion.ToString();CoreLib=[object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion;Passed=$false;ParityComparisons=0}
$receiptPath=[IO.Path]::Combine($PSScriptRoot,'receipt.txt')
try {
    $receipt.SMA=[Management.Automation.PowerShell].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute],$false)[0].InformationalVersion
    if($receipt.CoreLib -notlike '11.0.0-rc.1.26425.128*' -or ($receipt.PowerShell -ne '7.7.0-preview.5' -and -not $NativeAbiOnly)) { throw 'Installed app does not contain the pinned verification toolchain.' }
    $receipt.Mode=if($NativeAbiOnly){'Native ABI observation only'}else{'Pinned parity'}
    $receipt.PowerShellParity=if($NativeAbiOnly){'NOT RUN'}else{'Pending'}
    if([IntPtr]::Size -ne 8) { throw 'This device spike admits ARM64 only.' }
    . ([IO.Path]::Combine($PSScriptRoot,'Jni.ps1'))
    Complete-NativeImports
    $fixture=[Reflection.Assembly]::LoadFile(([IO.Path]::Combine($PSScriptRoot,'PwshNativeFixture.dll'))).GetType('PwshNativeFixture',$true)
    if(-not $NativeAbiOnly) {
        . ([IO.Path]::Combine($PSScriptRoot,'PwshNativeFixture.ps1'))
        $sourceType='PwshNativeFixture' -as [Type]
    }
    $envPointer=$global:JniEnv
    function Address([string]$JniName) { $fixture.GetMethod('Address').Invoke($null,@($envPointer,[int]$global:JniSlot[$JniName])) }
    function Check($actual,$expected) {
        if(-not [object]::Equals($actual,$expected)) { throw 'JNI value/type parity failed.' }
        $receipt.ParityComparisons++
    }
    $versionOracle=(Get-Jni GetVersion ([int]) @([IntPtr])).Invoke($envPointer)
    Check ($fixture.GetMethod('Int1').Invoke($null,@((Address GetVersion),$envPointer))) $versionOracle
    Check $versionOracle ([int]0x00010006)
    $build=Get-JClass 'android/os/Build$VERSION'
    $sdkField=Get-JField $build 'SDK_INT' 'I' -Static
    $sdkOracle=$global:Jni.GetStaticIntField.Invoke($envPointer,$build,$sdkField)
    Check ($fixture.GetMethod('Int3').Invoke($null,@((Address GetStaticIntField),$envPointer,$build,$sdkField))) $sdkOracle
    Check $sdkOracle ([Runtime.InteropServices.Marshal]::ReadInt32($global:JniActivity,6 * [IntPtr]::Size))
    $rectClass=Get-JClass 'android/graphics/Rect'
    $rect=Invoke-JniA $global:Jni.NewObjectA $rectClass (Get-JMethod $rectClass '<init>' '(IIII)V') @([int]-9,[int]7,[int]31,[int]29)
    try {
        foreach($name in @('left','top','right','bottom')) {
            $field=Get-JField $rectClass $name 'I'
            $delegate=Get-Jni GetIntField ([int]) @([IntPtr],[IntPtr],[IntPtr])
            $expected=$delegate.Invoke($envPointer,$rect,$field)
            Check ($fixture.GetMethod('Int3').Invoke($null,@((Address GetIntField),$envPointer,$rect,$field))) $expected
        }
        foreach($name in @('width','height')) {
            $method=Get-JMethod $rectClass $name '()I'
            $expected=Invoke-JniA $global:Jni.CallIntMethodA $rect $method
            Check ($fixture.GetMethod('Int4').Invoke($null,@((Address CallIntMethodA),$envPointer,$rect,$method,[IntPtr]::Zero))) $expected
            Check $expected ([int]$(if($name -eq 'width'){40}else{22}))
        }
        # Object results are independent local references; compare their Java
        # strings and delete both references, rather than compare JNI handles.
        $activityClass=$global:Jni.GetObjectClass.Invoke($envPointer,$global:JniActivityObject)
        $packageMethod=Get-JMethod $activityClass 'getPackageName' '()Ljava/lang/String;'
        $expectedObject=Invoke-JniA $global:Jni.CallObjectMethodA $global:JniActivityObject $packageMethod
        $actualObject=$fixture.GetMethod('Ptr4').Invoke($null,@((Address CallObjectMethodA),$envPointer,$global:JniActivityObject,$packageMethod,[IntPtr]::Zero))
        Check (ConvertFrom-JString $actualObject) (ConvertFrom-JString $expectedObject)
        Check (ConvertFrom-JString $actualObject) 'dev.mansfieldplumbing.pwsh'
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$actualObject)
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$expectedObject)
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$activityClass)
        Assert-NoJavaException 'consumer parity'
        $callAddress=Address CallIntMethodA
        $widthMethod=Get-JMethod $rectClass 'width' '()I'
        $compiled=$fixture.GetMethod('Int4')
        $compiledParameters=[object[]]@($callAddress,$envPointer,$rect,$widthMethod,[IntPtr]::Zero)
        $oracle=$global:Jni.CallIntMethodA.GetType().GetMethod('Invoke')
        $oracleParameters=[object[]]@($envPointer,$rect,$widthMethod,[IntPtr]::Zero)
        $receipt.Timings=@(foreach($side in @('PwshDelegate','Lowered')) {
            $method=if($side -eq 'Lowered'){$compiled}else{$oracle}
            $target=if($side -eq 'Lowered'){$null}else{$global:Jni.CallIntMethodA}
            $parameters=if($side -eq 'Lowered'){$compiledParameters}else{$oracleParameters}
            for($i=0;$i -lt 100;$i++){ $null=$method.Invoke($target,$parameters) }
            foreach($sample in 1..5) {
                $timer=[Diagnostics.Stopwatch]::StartNew()
                for($i=0;$i -lt 1000;$i++){ $null=$method.Invoke($target,$parameters) }
                [pscustomobject]@{Side=$side;Sample=$sample;Iterations=1000;Milliseconds=$timer.Elapsed.TotalMilliseconds}
            }
        })
    } finally {
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$rect)
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$rectClass)
        $global:Jni.DeleteLocalRef.Invoke($envPointer,$build)
    }
    # Ordinary body parity never invokes an UnmanagedCallersOnly method from
    # managed code. The callback itself is entered later by NativeActivity.
    if(-not $NativeAbiOnly) {
        $sourceType.GetMethod('CreatedBody').Invoke($null,@($global:JniActivity,[IntPtr]::Zero))
        $fixture.GetMethod('CreatedBody').Invoke($null,@($global:JniActivity,[IntPtr]::Zero))
        Check ($fixture.GetField('CreatedCount').GetValue($null)) ($sourceType.GetProperty('CreatedCount').GetValue($null))
        Check ($fixture.GetField('CallbackThread').GetValue($null)) ($sourceType.GetProperty('CallbackThread').GetValue($null))
        $receipt.PowerShellParity='Callback body passed'
    }
    $fixture.GetField('CreatedCount').SetValue($null,[int]0)
    $fixture.GetField('ReceiptPath').SetValue($null,([IO.Path]::Combine($PSScriptRoot,'callback.txt')))
    $fixture.GetField('ProfileThread').SetValue($null,[Environment]::CurrentManagedThreadId)
    $table=$global:JniM::ReadIntPtr($global:JniActivity)
    $slot=7 * [IntPtr]::Size # native_activity.h onNativeWindowCreated
    $original=$global:JniM::ReadIntPtr($table,$slot)
    $fixture.GetField('OriginalCreated').SetValue($null,$original)
    $global:JniM::WriteIntPtr($table,$slot,$fixture.GetMethod('CreatedAddress').Invoke($null,@()))
    $receipt.CallbackInstalled=$true
    $receipt.Passed=$true
    Write-AndroidLog 'PSLowering consumer JNI PASS; compiled NativeActivity callback installed'
} catch {
    $receipt.Blocker=$_.Exception.Message
    $receipt.Position=$_.InvocationInfo.PositionMessage
} finally {
    $lines=[Collections.Generic.List[string]]::new()
    foreach($entry in $receipt.GetEnumerator()) {
        if($entry.Key -eq 'Timings') { continue }
        $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$entry.Value))
        $lines.Add($entry.Key+'='+$encoded)
    }
    if($receipt.Contains('Timings')) {
        foreach($sample in $receipt.Timings) { $lines.Add('Timing='+$sample.Side+','+$sample.Sample.ToString()+','+$sample.Iterations.ToString()+','+$sample.Milliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)) }
    }
    [IO.File]::WriteAllLines($receiptPath,$lines)
}
