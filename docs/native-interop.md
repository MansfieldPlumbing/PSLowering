# Native indirect calls and callbacks

The implementation remains entirely in `Export-LoweredAssembly.ps1`.
`tests/Test-NativeInterop.ps1` verifies this subset on Windows x64 with
PowerShell 7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128. These tests do not
establish Android, x86 or ARM execution.

An indirect-call declaration uses the existing CoreLib attribute as a
compiler convention. Its first parameter must be `IntPtr`; the remaining
parameters and return declare the exact unmanaged signature. The body is
one throw, so interpreting the stub fails explicitly:

```powershell
[System.Runtime.InteropServices.UnmanagedCallConv(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
static [int] Compare([IntPtr] $functionPointer, [IntPtr] $left, [IntPtr] $right) {
    throw [NotSupportedException]::new()
}
```

Only explicit `CallConvCdecl` and `CallConvStdcall` are admitted. PowerShell
attribute syntax accepts a single literal type here; emission writes the
corresponding convention to the unmanaged `calli` signature. The stub's
pointer is omitted from that native signature. A null pointer throws before
native entry. Native addresses are opaque: the caller must supply a live
address whose ABI matches the declaration, keep its library loaded, and
respect buffer sizes and ownership. `IntPtr` and `UIntPtr` preserve the
executing process's pointer width; integer pointer declarations are rejected.
This is neither pointer provenance checking nor automatic marshaling.

A callback is a static method with an explicit convention:

```powershell
[System.Runtime.InteropServices.UnmanagedCallersOnly(CallConvs=[System.Runtime.CompilerServices.CallConvCdecl])]
static [int] Callback([IntPtr] $left, [IntPtr] $right) {
    return [Example]::CompareValues($left, $right)
}
static [IntPtr] CallbackAddress() {
    return [Example].GetMethod('Callback').MethodHandle.GetFunctionPointer()
}
```

The address expression must name one unambiguous callback in the same
compilation. Its reflected signature is validated and its method token is
emitted with `ldftn`; runtime reflection is eliminated from this expression.
An omitted or ordinary managed target is rejected. Callback parameters and
returns admit only signed/unsigned 8/16/32/64-bit integers, Single, Double,
IntPtr and UIntPtr, with void also allowed as a return. References, arrays,
bool, char and byrefs are rejected. Direct managed calls and callback entry
points are rejected. Callbacks must not let exceptions escape into native
code. The compiled assembly must remain loaded while native code retains
its callback address; the fixtures use noncollectible assemblies.

Native stubs and callback address acquisition require Compile mode.
Expression mode rejects these operations with a source position; ordinary
callback bodies can still be inspected as expressions. Mainline PowerShell
can parse these declarations, but a method carrying UnmanagedCallersOnly
must never be invoked through managed reflection or a PowerShell wrapper.
Parity tests therefore run the ordinary typed body on identical inputs,
then invoke the compiled callback through the native ABI.

The worker fixture follows QuickPS's `MethodInfo.CreateDelegate` instance
worker path. Constructors and instance delegates already used the ordinary
reflected-call emitter; the missing capability was a ThreadStart literal as
a value. Only that concrete literal was added (`ldtoken` plus
`Type.GetTypeFromHandle`). The fixture uses an explicit constructor and
checks synchronous PowerShell parity, CLR thread execution and a fresh
zero-SMA dotnet host. Implicit constructor calls inside compiled source
remain outside this fixture's proved contract.

The native suite independently checks exact standalone signature bytes and
`ldftn` targets, emitted callback metadata, OS process identity, mixed
integer/floating-point arguments, pointer values above 32 bits, void results,
CRT qsort reverse calls, PowerShell body parity and zero-SMA execution.
Its ABI oracle uses public Reflection.Emit delegate metadata and OS/CRT
exports, without the compiler's expression tree or IL emitter. Native
fixtures live in `tests/native-fixtures`; the older Pwsh expression admission
oracle applies to the legacy fixtures and does not understand native plans.

## Sources

`native-reference-identities.json` records full commits, Git blob identities
and SHA-256 digests of the read-only references. No platform implementation
is imported. Relevant contracts are:

- QuickPS `f1b1c9083d448c3ee893f878122de758849d4022`, `src/Native.ps1:41-62`
  (explicit StdCall delegates), `src/managed/AudioCapture.ps1:108-119` and
  `src/managed/MediaSessionEvents.ps1:43-51` (COM function-table calls),
  `src/Capture.Windows.ps1:55-56` and `src/MediaSessionEvents.Windows.ps1:48-49`
  (typed instance ThreadStart delegates).
- Pwsh `3110a85a63a48b2dc1500364cb508d06f3ea3f91`,
  `modules/AndroidCanvas.psm1:37-62` and `scripts/probes/jni/Jni.ps1:240-269`
  (typed native/JNI signatures), `setup.ps1`, `docs/lowering.md` and
  `ROADMAP.md` (persisted managed execution and delivery boundaries).
- [ECMA-335](https://ecma-international.org/publications-and-standards/standards/ecma-335/),
  II.23.2.3/II.23.1.16 (standalone signatures), III.3.20 and III.3.41
  (`calli`, `ldftn`).
- [UnmanagedCallersOnly](https://learn.microsoft.com/dotnet/api/system.runtime.interopservices.unmanagedcallersonlyattribute)
  and [unmanaged calling conventions](https://learn.microsoft.com/dotnet/standard/native-interop/calling-conventions).

External assembly references, broader console admission, an in-memory
compilation API and consumer platform integration remain deferred.
