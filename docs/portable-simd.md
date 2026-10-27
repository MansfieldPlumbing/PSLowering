# Portable SIMD calls and struct receivers

`tests/Test-PortableSimd.ps1` executes the appendix `PortableVectorProbe.Sum4`
and compares the emitted methods with the same source running in PowerShell.
Single and Double lanes are compared through `BitConverter.SingleToInt32Bits`
and `DoubleToInt64Bits`, including signed zero, infinities and subnormals.
The appendix returns Single `27`.

## Admitted mechanisms

- Static generic methods infer type parameters structurally from arguments,
  including nested constructed generics and arrays. Every occurrence of a
  type parameter must agree. Uninferred parameters, conflicting bindings,
  constraint failures and ambiguous applicable generic methods reject before
  output. Diagnostics include the source position and candidates tried.
  Existing non-generic exact/compatible matches take precedence. This is a
  structural subset, not the complete C# or PowerShell overload binder.
- Closed generic method arguments referring to classes in the compilation
  are remapped from the class mirror to the emitted types.
- Struct instance calls and property accessors receive managed addresses:
  `ldloca`, `ldarga`, `ldflda`, `ldsflda` or `ldelema`. Computed values and
  readonly fields use a temporary evaluated once. Virtual and interface
  dispatch on value receivers uses `constrained.` followed by `callvirt`.
- Explicit closed-struct `op_Addition` / `op_Multiply` and the existing
  PowerShell arithmetic lowering use the reflected operator methods.

The regression covers Vector128 float/int creation, Add, Multiply, Subtract,
ConvertToSingle, GetElement and indexers; Vector256 float/double creation,
Add, Multiply, GetLower, GetUpper and indexers; Vector<T>; parameters, locals,
instance/static fields, array elements and temporary receivers; and a
PowerShell-emitted consumer struct with a method, property, indexer, setters
and inherited virtual dispatch. It also checks nested/array inference,
non-generic preference, class-mirror remapping and rejected inference.

Span<T> element access was not admitted by the existing expression path and
is not added here. Generic inference does not infer through a different
generic definition, an implemented interface or a base class.

## Execution and inspection

`Inspect` / `Test-LoweredAssembly` still reports assembly references and
metadata. `ClrOnlyAdmitted` does not certify IL verification or safe invocation.
It cannot invoke arbitrary consumer methods without inputs and side effects.
The consolidated suite now executes the SIMD regression in a child process,
so an invalid-IL CLR abort fails the suite. No ILVerify dependency is added.

The runtime contracts used by the emitter are documented in
[OpCodes.Constrained](https://learn.microsoft.com/en-us/dotnet/api/system.reflection.emit.opcodes.constrained)
and [MethodInfo.MakeGenericMethod](https://learn.microsoft.com/en-us/dotnet/api/system.reflection.methodinfo.makegenericmethod).
Actual qualification uses the pinned runtime below.

## Verification on 2026-10-27

All 96 bitwise/value comparisons passed on each architecture. The aggregate
result SHA-256 was identical:
`BAA6BF3B7FE8960D0FCBE4A081D33BA5F0A107C343AD019CB32529DD4E8700D8`.

- Windows x64: PowerShell 7.7.0-preview.5, .NET 11.0.0-rc.1.26425.128.
- Android arm64: the installed Kokoro app's CoreCLR runspace, the same
  PowerShell and .NET versions. `tests/Invoke-PortableSimdAndroid.ps1` runs
  the Windows-built artifacts, checks transfer SHA-256, compares the result
  digest with x64, and restores all three startup filenames with hash checks.
  The installed APK's source commit is not qualified by this test.
- `tests/Test-ConsolidatedRunner.ps1`: 23 suites, including execution of
  `tests/Test-PortableSimd.ps1` and the unchanged frozen legacy ratchet.
- `tests/Test-LegacyRatchet.ps1`: all 52 immutable assembly SHA-256 values
  and all 14 rejection diagnostics remain unchanged; both negative controls
  pass. A wider before/after inventory found 383 unchanged DLLs out of 386.
  The differences were the intentionally corrected consumer receiver probe
  and two authentic-SMA persistence proofs outside deterministic product
  emission (`one-parameter-proof`, `two-parameter-proof`).

Use `tools/Get-PowerShell.ps1` for Windows. For the standalone-host suites,
put `build/cache/dotnet/11.0.0-rc.1.26425.128` on PATH and set DOTNET_ROOT to
that directory. A system dotnet lacking this runtime fails qualification.
Android runs are local, with the shared phone lock; hosted CI has no device.

Execution receipts are generated under `build/portable-simd/` as CLIXML.
`execution-X64.clixml` and the Android receipt contain the aggregate bit/value
digest and comparison count. No consumer repository pin is changed here.
