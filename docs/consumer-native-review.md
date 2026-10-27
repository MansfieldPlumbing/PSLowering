# Review of the pending native consumer probes

Reviewed on 2026-10-27 separately from the portable SIMD change. The pending
`docs/consumer-native-inputs.json`, `tests/consumers/` fixtures and
`docs/consumer-native-spike.md` document real consumers of the admitted native
call/callback subset. They are useful independent consumer verification, not
an alternative compiler or a request to vendor consumer implementations.

The original spike observation in `consumer-native-receipt.json` identifies
its compiler and consumer commits. It remains historical evidence: in
particular its preview.4 Android observation and admitted receiver defect
are not rewritten as current results.

The following commands were rerun on Windows x64 using PowerShell
7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128 and the pinned standalone runtime:

- `Get-ConsumerSources.ps1`: seven immutable source files passed Git/SHA-256
  integrity verification from their existing cache.
- `Test-ConsumerHeaders.ps1`: five JNI, one NativeActivity and five COM
  slots passed independent pinned-header checks.
- `Test-QuickPSCom.ps1`: unchanged AudioCapture/MediaSessionEvents classes
  were admitted; 12 HRESULT/out-value comparisons and the zero-SMA COM
  executable passed. Emitted unmanaged signatures passed metadata checks.
- `Test-AndroidCanvasAdmission.ps1`: the original function module remains
  rejected before output; the typed adapter is a separate source fixture.
- `Measure-ValueTypeReceiver.ps1`: the original Format(0) reproducer now
  agrees with PowerShell after the portable SIMD receiver correction.

The original JNI/callback device probe was not rerun in this review. The
separate portable SIMD regression was run on the current Android arm64 host;
it does not replace the native callback lifecycle check. No QuickPS, Pwsh or
Kokoro source checkout or dependency pin was changed.

These consumer probes remain local opt-in commands. They use Windows COM or
an explicitly selected Android app and are not silently added to hosted CI.
