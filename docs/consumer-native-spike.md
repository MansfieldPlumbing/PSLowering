# Native consumer integration spike

Measured on 2026-10-09 from PSLowering main
`3b68b12f062da5edc58c444122c1b58ecdfb5ed1`. The compiler, frozen legacy
baseline and hosted workflow are unchanged. This branch adds independent
consumer fixtures, local probes and an observation receipt. It does not adopt
the adapters into either consumer product.

Sources are QuickPS `f1b1c9083d448c3ee893f878122de758849d4022` and Pwsh
`3110a85a63a48b2dc1500364cb508d06f3ea3f91`. Existing
[source identities](native-reference-identities.json) and the additional
[header identities](consumer-native-inputs.json) pin every downloaded input.
No external checkout was modified. Acquired source and full diagnostic evidence
remain under ignored `build/consumer-native/`.

## Results

| Boundary | Evidence | Result |
| --- | --- | --- |
| QuickPS original typed classes | `Test-QuickPSCom.ps1` compiles unchanged `AudioCapture.ps1` and `MediaSessionEvents.ps1` | Both admitted |
| QuickPS COM calls | Real Media Session `GetEvent` slot 3; real Media Event `GetType` slot 33 and `GetStatus` slot 35; original SMA `QuickPSMediaSessionEvents.Call` and QuickPS Native delegate binding as oracle | 12 HRESULT/out-value comparisons passed, including empty queue failure and signed HRESULT edges |
| Standalone COM execution | `QuickPSComFixture.Main` under the pinned standalone dotnet host | Passed; SMA absent, assembly references only CoreLib |
| Android JNI | Actual installed Pwsh app, original pinned `scripts/probes/jni/Jni.ps1` delegate bindings versus compiled `calli` | 14 binding comparisons passed: JNI version, SDK field, four Rect fields, Rect width/height and activity package string |
| Android reverse callback | Real NativeActivity `onNativeWindowCreated` slot 7 points to compiled `ldftn` / `UnmanagedCallersOnly` code | OS called it once after Profile returned; callback and Profile managed thread IDs both 1 |
| Device lifecycle | ARM64 SM-S911U, Android 16 / SDK 36, debuggable installed app | Alive after probe, 0 crash-buffer lines; previous Profile restored with matching SHA-256 |
| ABI independence | `Test-ConsumerHeaders.ps1` decodes pinned JNI / NativeActivity headers and Windows SDK 10.0.26100.0 COM vtables; `Assert-ConsumerMetadata.ps1` decodes emitted signatures | 5 JNI, 1 NativeActivity and 5 COM slots verified; exact unmanaged signatures and callback convention passed |
| Existing verification | `Test-ConsolidatedRunner.ps1` on PowerShell 7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128 | 22/22 suites; 52 legacy outputs, 14 diagnostics, 0 regressions; ratchet negative controls passed |

Windows compilation and parity used SMA `149ab5cd6cad34869177f86ef9a3da8414f85dc6`
and CoreLib `3551975be08744f0418857c5bed8ab1545c5dd47`. Android has that exact
CoreLib but PowerShell **7.7.0-preview.4**. With explicit authorization, the
device run was a **native ABI observation only**, using preview.5-built IL.
Pinned device PowerShell parity remains **NOT RUN**. The default strict probe
still exits 1 on that installed host; `-NativeAbiOnly` does not change the
compiler qualification target.

The Windows parity harness initializes COM in its existing STA and balances
the successful `CoInitializeEx` call. The fresh standalone host initializes
an MTA explicitly. The installed Android APK's binary SHA-256 is recorded;
its source commit is unverified. The binding oracle scripts have independently
verified immutable identities. This is not qualification of that installed APK
as a build of the pinned Pwsh commit.

The callback assembly is loaded noncollectibly and stays rooted for the process
lifetime. It chains a prior created-window callback when present, contains
exceptions, and retains no borrowed window pointer. Cleanup stops the probe
process before restoring Profile and removing its exclusively created private
directory. It does not clear device logs, replace modules, install an APK or
rebuild Pwsh. The app is left stopped with its original Profile restored.

## Timings

Five samples of 1,000 calls per side, after 100 warmup calls per side. Values
below are median milliseconds per sample. Every sample is retained in the
[machine-readable observation](consumer-native-receipt.json).

| Actual operation | Original path | Lowered adapter |
| --- | ---: | ---: |
| Windows IMFMediaEvent.GetType | 172.18 ms, original PowerShell `Call` | 30.20 ms |
| ARM64 JNI Rect.width | 6.43 ms, original Pwsh delegate | 6.13 ms |

Both paths are invoked through reflection from a PowerShell harness. These
measurements include dispatch overhead and use different adapter argument
lists; they are not isolated native-call latency measurements or a release
performance threshold. They do not measure audio capture, media playback or
Canvas frame rendering.

## Exact blockers and limits

1. **Device qualification:** `AndroidProfile.ps1:9:135` rejected the installed
   preview.4 host with `Installed app does not contain the pinned verification
   toolchain.` The strict probe exited 1. A debuggable preview.5 Pwsh build is
   required for the deferred device PowerShell parity run.
2. **Original module admission:** unadapted `AndroidCanvas.psm1` is a function
   module, outside the compiler's typed-class entrypoint. It rejects with
   `No class definition found in source.` before writing any artifact.
   `Test-AndroidCanvasAdmission.ps1` checks that boundary. The typed fixture is
   explicitly an adapter; successful adapter emission is not admission of the
   original module.
3. **Admitted value-type receiver defect:** `ValueTypeReceiverFixture.Format(0)`
   returns string `"0"` under pinned PowerShell but throws
   `System.NullReferenceException` in emitted IL. The source is line 2, column 51,
   `$value.ToString()`. `Measure-ValueTypeReceiver.ps1` reproduces it and exits
   **1** while the divergence exists. This also affected the initial callback
   receipt formatter. The native probe uses semantically equivalent
   `Convert.ToString(int)` calls. The compiler defect remains unresolved;
   neither the source oracle nor the historical baseline was changed to bless
   it. A focused compiler correction requires separate parity and historical
   output verification.

The original QuickPS classes were admitted, but their complete worker threads,
audio devices and window notification lifecycle were not executed. This spike
proves selected real ABI boundaries. Android callback drawing behavior and full
consumer adoption remain separate work. No compiler capability expansion was
needed for the selected native signatures.

## Reproduction

Run from the repository with the pinned PowerShell and standalone dotnet runtime
on PATH (`DOTNET_ROOT` pointing at that runtime). These consumer probes are
local commands; the hosted workflow does not invoke them or access devices.

```powershell
$pwsh = './build/cache/pwsh/7.7.0-preview.5/pwsh.exe'
$sources = './build/consumer-native/sources'
& $pwsh -NoProfile -File tests/consumers/Get-ConsumerSources.ps1
& $pwsh -NoProfile -File tests/consumers/Test-ConsumerHeaders.ps1 -SourceRoot $sources
& $pwsh -NoProfile -File tests/consumers/Test-QuickPSCom.ps1 -SourceRoot $sources
& $pwsh -NoProfile -File tests/consumers/Test-AndroidCanvasAdmission.ps1 -SourceRoot $sources
# Local device authorization required; never invoke from Actions.
& $pwsh -NoProfile -File tests/consumers/Invoke-AndroidConsumer.ps1 -SourceRoot $sources -Device SM-S911U -NativeAbiOnly
# Expected exit 1 for the unresolved defect; excluded from passing-suite counts.
& $pwsh -NoProfile -File tests/consumers/Measure-ValueTypeReceiver.ps1
& $pwsh -NoProfile -File tests/Test-ConsolidatedRunner.ps1 -Sanitized
```

Omit `-NativeAbiOnly` to require the pinned device host. Header verification
requires the SHA-pinned Windows SDK headers and accepts `-WindowsSdkInclude`.
Source acquisition verifies existing cached files and refuses mismatches.
Probe receipts are observations, never compiler-generated expected results.

Platform contracts: [Media Foundation event generators](https://learn.microsoft.com/en-us/windows/win32/medfound/media-event-generators),
[QueueEvent](https://learn.microsoft.com/en-us/windows/win32/api/mfobjects/nf-mfobjects-imfmediaeventgenerator-queueevent),
[Media Session ownership](https://learn.microsoft.com/en-us/windows/win32/api/mfidl/nf-mfidl-mfcreatemediasession)
and [NativeActivity callbacks](https://developer.android.com/ndk/reference/struct/a-native-activity-callbacks).
