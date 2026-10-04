class NativeImportsFixture {
    [System.Runtime.InteropServices.LibraryImport('kernel32.dll', EntryPoint = 'GetCurrentProcessId')]
    static [uint] CurrentProcessId() { throw [System.NotSupportedException]::new('native import') }

    [System.Runtime.InteropServices.LibraryImport('kernel32.dll', EntryPoint = 'lstrlenW', StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]::Utf16)]
    static [int] Utf16Length([string] $text) { throw [System.NotSupportedException]::new('native import') }

    [System.Runtime.InteropServices.LibraryImport('kernel32.dll', EntryPoint = 'lstrlenA', StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]::Utf8)]
    static [int] Utf8ByteLength([string] $text) { throw [System.NotSupportedException]::new('native import') }

    [System.Runtime.InteropServices.LibraryImport('kernel32.dll')]
    static [long] GetTickCount64() { throw [System.NotSupportedException]::new('native import') }

    static [bool] IsCurrentProcess([uint] $id) {
        return [NativeImportsFixture]::CurrentProcessId() -eq $id
    }

    static [int] TotalLength([string] $a, [string] $b) {
        return [NativeImportsFixture]::Utf16Length($a) + [NativeImportsFixture]::Utf16Length($b)
    }
}
