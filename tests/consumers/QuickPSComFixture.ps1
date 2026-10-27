# Adapter for QuickPSMediaSessionEvents.Call's GetType/GetStatus signatures.
# IMFMediaEvent inherits 30 IMFAttributes methods after IUnknown: slots 33,35.
class QuickPSComFixture {
    [System.Runtime.InteropServices.LibraryImport('ole32.dll',EntryPoint='CoInitializeEx')]
    static [int] InitializeCom([IntPtr] $reserved,[uint] $flags) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.LibraryImport('ole32.dll',EntryPoint='CoUninitialize')]
    static [void] UninitializeCom() { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.LibraryImport('mfplat.dll',EntryPoint='MFStartup')]
    static [int] Startup([uint] $version,[uint] $flags) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.LibraryImport('mfplat.dll',EntryPoint='MFShutdown')]
    static [int] Shutdown() { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.LibraryImport('mfplat.dll',EntryPoint='MFCreateMediaEvent')]
    static [int] CreateEvent([int] $kind,[IntPtr] $extended,[int] $status,[IntPtr] $value,[IntPtr] $result) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.LibraryImport('mf.dll',EntryPoint='MFCreateMediaSession')]
    static [int] CreateSession([IntPtr] $configuration,[IntPtr] $result) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [int] GetEvent([IntPtr] $address,[IntPtr] $instance,[uint] $flags,[IntPtr] $result) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [int] QueueEvent([IntPtr] $address,[IntPtr] $instance,[int] $kind,[IntPtr] $extended,[int] $status,[IntPtr] $value) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [int] SessionShutdown([IntPtr] $address,[IntPtr] $instance) { throw [NotSupportedException]::new() }
    [System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvStdcall])]
    static [int] IntOut([IntPtr] $address,[IntPtr] $instance,[IntPtr] $result) { throw [NotSupportedException]::new() }
    static [int] ReadEvent([IntPtr] $instance,[int] $slot,[IntPtr] $result) {
        [IntPtr] $table=[Runtime.InteropServices.Marshal]::ReadIntPtr($instance)
        [IntPtr] $address=[Runtime.InteropServices.Marshal]::ReadIntPtr($table,$slot * [IntPtr]::Size)
        return [QuickPSComFixture]::IntOut($address,$instance,$result)
    }
    static [int] Main() {
        foreach($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if($assembly.GetName().Name -eq 'System.Management.Automation') { return 1 }
        }
        [int] $co=[QuickPSComFixture]::InitializeCom([IntPtr]::Zero,[uint]0)
        if($co -lt 0) { return 8 }
        [int] $hr=[QuickPSComFixture]::Startup([uint]131184,[uint]0)
        if($hr -lt 0) { [QuickPSComFixture]::UninitializeCom(); return 2 }
        [IntPtr] $scratch=[Runtime.InteropServices.Marshal]::AllocHGlobal(40)
        [IntPtr] $event=[IntPtr]::Zero
        try {
            for([int]$i=0;$i -lt 40;$i++) { [Runtime.InteropServices.Marshal]::WriteByte($scratch,$i,[byte]0) }
            $hr=[QuickPSComFixture]::CreateEvent(111,$scratch,-2147467259,[IntPtr]::Zero,[IntPtr]::Add($scratch,24))
            if($hr -lt 0) { return 3 }
            $event=[Runtime.InteropServices.Marshal]::ReadIntPtr($scratch,24)
            if([QuickPSComFixture]::ReadEvent($event,33,$scratch) -ne 0) { return 4 }
            if([Runtime.InteropServices.Marshal]::ReadInt32($scratch) -ne 111) { return 5 }
            if([QuickPSComFixture]::ReadEvent($event,35,$scratch) -ne 0) { return 6 }
            if([Runtime.InteropServices.Marshal]::ReadInt32($scratch) -ne -2147467259) { return 7 }
            return 0
        } finally {
            if($event -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::Release($event) }
            [Runtime.InteropServices.Marshal]::FreeHGlobal($scratch)
            [QuickPSComFixture]::Shutdown()
            [QuickPSComFixture]::UninitializeCom()
        }
    }
}
