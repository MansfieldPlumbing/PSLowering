# Typed adapters for AndroidCanvas/Jni.ps1; no platform implementation is copied.
class PwshNativeFixture {
    static [IntPtr] Address([IntPtr] $env,[int] $slot) {
        return [Runtime.InteropServices.Marshal]::ReadIntPtr([Runtime.InteropServices.Marshal]::ReadIntPtr($env),$slot * [IntPtr]::Size)
    }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [int] Int1([IntPtr] $address,[IntPtr] $env) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [int] Int3([IntPtr] $address,[IntPtr] $env,[IntPtr] $target,[IntPtr] $field) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [int] Int4([IntPtr] $address,[IntPtr] $env,[IntPtr] $target,[IntPtr] $method,[IntPtr] $values) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [IntPtr] Ptr4([IntPtr] $address,[IntPtr] $env,[IntPtr] $target,[IntPtr] $method,[IntPtr] $values) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [void] WindowCall([IntPtr] $address,[IntPtr] $activity,[IntPtr] $window) { throw [NotSupportedException]::new() }
    static [IntPtr] $OriginalCreated
    static [string] $ReceiptPath
    static [int] $ProfileThread
    static [int] $CreatedCount
    static [int] $CallbackThread
    static [void] CreatedBody([IntPtr] $activity,[IntPtr] $window) {
        [PwshNativeFixture]::CreatedCount=[PwshNativeFixture]::CreatedCount + 1
        [PwshNativeFixture]::CallbackThread=[Environment]::CurrentManagedThreadId
    }
    [System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
    static [void] Created([IntPtr] $activity,[IntPtr] $window) {
        try {
            [PwshNativeFixture]::CreatedBody($activity,$window)
            if([PwshNativeFixture]::OriginalCreated -ne [IntPtr]::Zero) {
                [PwshNativeFixture]::WindowCall([PwshNativeFixture]::OriginalCreated,$activity,$window)
            }
            [IO.File]::WriteAllText([PwshNativeFixture]::ReceiptPath,[Convert]::ToString([PwshNativeFixture]::CreatedCount) + ',' + [Convert]::ToString([PwshNativeFixture]::CallbackThread) + ',' + [Convert]::ToString([PwshNativeFixture]::ProfileThread))
        } catch {
            try { [IO.File]::WriteAllText([PwshNativeFixture]::ReceiptPath,'ERROR') } catch { }
        }
    }
    static [IntPtr] CreatedAddress() { return [PwshNativeFixture].GetMethod('Created').MethodHandle.GetFunctionPointer() }
}
