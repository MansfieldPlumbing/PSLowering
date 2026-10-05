# PSLowering roadmap

The single plan for this repository. Each item names why it matters, what
done means, and how it is checked. Work items in order unless a consumer is
blocked; a checked item names the commit and the test that proves it.

## Where things stand (2026-10-04, `26fe7a8`)

- The compiler: typed PowerShell classes compile to IL through PSLowering's
  own emitter (`src/`, about 2,800 lines). Every class in a source file
  compiles into one assembly through a mirror of runtime types
  (`src/Ast/ClassModel.ps1`).
- Supported: static and instance methods; typed properties as fields with
  initializers; constructors; `$this`; classes that use each other, including
  in generic types; locals; assignment and compound assignment on variables,
  fields, properties and array elements; checked integral arithmetic,
  Double integral division, round-half-to-even conversion; bitwise operators;
  string comparison through the invariant culture; string concatenation;
  `if`/`elseif`/`else`, `while`, `for`, `foreach` over typed arrays, `break`,
  `continue`, `return`; typed arrays with negative indexing; .NET calls and
  constructors; `throw`, `try`/`catch`/`finally`; native imports through
  `[LibraryImport]`; executables through `-EntryPoint`.
- Verification: 18 suites in `tests/Test-ConsolidatedRunner.ps1`, passing on
  PowerShell 7.6.6 (.NET 10.0.8, the CI tool) and 7.7.0-preview.4 (.NET
  11.0.0-preview.6). The PowerShell source oracle runs 221 calls over 16
  fixtures with no divergence. CI on GitHub runs the same suite.
- On devices: PSLowering output (`25427b2`) compiled on Windows matched
  PowerShell running on the device for all 196 oracle calls of that commit,
  on the x86-64 emulator, an arm64 physical device and an arm32 device, each
  on .NET 11.0.0-rc.1 (Pwsh `157852c`, `scripts/probes/lowering`).
- Against the real workload: 39 of the 70 class methods in Pwsh's
  `modules/Console.psm1` lower (from 3 before classes landed).
- Consumers: Pwsh (managed host, console core, Recovery) and Kokoro-Hexagon
  (the managed DSP and audio session). Kokoro is waiting on items 1.1 and
  1.2.

## Principles

1. **PowerShell defines the meaning.** A compiled method returns what the
   same PowerShell method returns, or both throw. The source oracle is the
   judge; a divergence is a compiler defect, never a reason to change an
   expected result.
2. **Stay a strict subset.** Every PSLowering source is valid PowerShell
   that runs unchanged in mainline PowerShell. Extend through what the
   language already allows: attributes, conventions, and intrinsics written
   as ordinary method calls. Never add syntax. Never fork SMA.
3. **The workload chooses features.** A construct is added because a
   consumer's code needs it, ranked by measured lines unlocked (the
   admission report), never for parity with C#.
4. **Reject, never guess.** Anything outside the subset fails before output,
   with line, column and reason. Nothing falls back to running the script.
5. **Staging is the design.** PowerShell runs at build time with full power
   (data, tables, device facts) and generates small, specialized, typed code;
   the compiled subset stays small because PowerShell does the thinking
   before compilation.
6. **Use the .NET library; do not rebuild the language.** Collections,
   generics and math are calls into the base library.
7. **Measure before optimizing.** Profiles and device timings choose
   performance work.

### Not doing (until a consumer's measured need moves an item)

Inheritance hierarchies; interfaces beyond what interop needs; events;
`async`/`await`; operator overloading; defining generic types or generic
methods; properties with custom accessors; pipelines and cmdlets inside
compiled code; script blocks as values; dynamic member access.

## Phase 1: unblock the consumers

### 1.1 Kokoro consumer template and handoff
Why: Kokoro-Hexagon (`9f3d2e37`) binds its native calls through delegates
invoked with `DynamicInvoke` (`src/runspace/Audio.AAudio.psm1`,
`FastRpcProbe.ps1`, `FastRpcDirectIoctlProbe.ps1`); compiled P/Invoke methods
replace that per-call reflection.
Done when:
- `tests/fixtures/KokoroToneSessionFixture.ps1` expresses the session's
  managed half as a typed class with `[LibraryImport]` bindings, signatures
  from pinned headers:
  - DSP session setup through `libcdsprpc.so`, once: `remote_session_control`,
    `remote_handle64_open`, `remote_handle64_close` (qualcomm/fastrpc
    `d2475196`, `inc/remote.h:803,871,935`);
  - per-job packets through the same library's queue: `dspqueue_create`,
    `dspqueue_export`, `dspqueue_write`, `dspqueue_read`, `dspqueue_close`
    (`inc/dspqueue.h`), with a blocking timed read, no polling;
  - the direct route, libc `open`, `ioctl` and `close` with
    `SetLastError = $true` (bionic `e4df46f2`: `ioctl(int, int, ...)`);
  - `libaaudio.so` builder, stream, write, state and close (frameworks/av
    `e2f09893`).
  `Marshal` allocation and cleanup in `try`/`finally`; handles returned
  through buffers (by-reference parameters are not supported). The drain is
  `AAudioStream_requestStop` then `AAudioStream_waitForStateChange` to
  STOPPED; that call is a futex wait that also wakes at least every 20 ms
  (`AudioStream.cpp:445-466`), so it removes the application's sleep loop but
  is not purely event-driven. The data callback is, and needs 1.2.
- A compile-only test (the libraries exist only on Android) checks that it
  compiles, that every import is a P/Invoke method with the declared library,
  entry point and last-error flag, and that Pwsh's admission rule accepts it.
- `docs/handoff/kokoro.md` names the pinned commit, the template, the
  out-parameter pattern and the drain.
Done so far: `SetLastError` on native imports, tested against kernel32
`SetLastError` on both runtimes.
Device: none here; the Kokoro agent runs its own device test.

### 1.2 Callbacks and function-pointer calls
Why: event-driven native code (AAudio data callbacks, window and input
callbacks) calls into managed code; exports resolved at run time and
function tables (COM, JNI, Vulkan) need calls through a pointer.
Done when:
- A static method marked
  `[System.Runtime.InteropServices.UnmanagedCallersOnly]` compiles with that
  attribute, blittable signature only, and its address can be taken through
  an intrinsic written as an ordinary method call (emitting `ldftn`).
- A function-pointer call intrinsic emits unmanaged `calli` with a declared
  signature, blittable only.
- Both stay valid PowerShell (the intrinsics must be callable, even if they
  throw, in mainline PowerShell).
- Test (Windows, no device): compile a callback, take its address, call it
  back through the function-pointer intrinsic, and pass it to a Windows API
  that calls back (for example `EnumWindows`), checking results against
  .NET.

### 1.3 References between emitted assemblies
Why: composable parts. Assembly B compiles against assembly A's real types
and calls A directly.
Done when: `Export-LoweredAssembly -Reference <path>` resolves types and
members from referenced assemblies loaded by path; the output carries a
normal assembly reference; a two-assembly test runs in a fresh process and
under `dotnet exec`.

### 1.4 Console core gaps (from the admission report)
Why: Pwsh ROADMAP R3. Remaining categories in `modules/Console.psm1`:
- indexing into `List` (`get_Item`/`set_Item`) and `foreach` over
  collections that are not arrays (5 + 4 methods, about 200 lines);
- PowerShell's numeric promotion for mixed operand types, matched exactly
  and checked by the oracle (7 methods);
- `if` used as a value, and the remaining expression forms (9 methods);
- conversions the CLR has no operator for (2 methods).
Done when: the admission report reaches the target the console work needs,
with every new construct carrying oracle vectors. Rewrite the remaining
script block and expandable-string uses in the console source rather than
supporting them.
How to measure: parse `Console.psm1` from a pinned Pwsh commit, run every
class method through `ConvertTo-TypedExpression`, and group the rejection
messages with their positions and quoted source removed; report methods
lowered, lines lowered, and lines per rejection category. Make this a
script under `tools/` the first time it is needed again, so the number is
reproducible.

### 1.5 Typed functions
Why: `Console.psm1` has 81 functions beside its 70 class methods, and the
drawing path is mostly functions.
Done when: a function with typed parameters, `[OutputType(...)]` and output
only through `return` compiles to a static method of a generated class; a
function that emits anything else to its output stream is rejected. Oracle
vectors compare against calling the function in PowerShell.

## Phase 2: adoption (in the consumer repositories)

These are done in Pwsh and Kokoro-Hexagon, each taking PSLowering from GitHub
at a pinned commit and digest. Listed here so the compiler work serves them.
- Pwsh `setup.ps1` replaces its hand-built expression trees
  (`New-FindProfileMethod`, `New-ManagedHostAssemblyBytes`) with PSLowering;
  gate: the managed host behaves the same and gates 2a-2d pass on all three
  backends.
- Kokoro replaces its copy of the private LambdaCompiler helper.
- Pwsh R3: compile the console core's hot paths; measure compiled against
  interpreted on the arm64 and arm32 test devices.
- Pwsh R6: Recovery as an assembly with no SMA reference, run as
  `Test-DotnetHost` proves.

## Phase 3: speed and self-sufficiency

### 3.1 Compiler profile
Measured 2026-10-04 (classes fixture, PowerShell 7.7): module import
707 ms; mirror 656 ms; lowering 12 methods 1,939 ms cold; whole export
3,572 ms cold, 748-937 ms warm. Most of the cost is PowerShell interpreting
the compiler. Each test suite runs in a fresh process and pays the cold cost.

### 3.2 Self-hosting
Rewrite the compiler's own source into its subset (typed classes or typed
functions; hashtables and `[pscustomobject]` records become typed classes or
`Dictionary`s; pipelines become loops) and compile it with itself.
Done when: two generations of the self-compiled compiler produce
byte-identical output, and compile times are measured against 3.1.

### 3.3 Publishing
The module to the PowerShell Gallery, later the self-compiled DLL to
nuget.org, under `Dev.MansfieldPlumbing.*`. Each publish needs the owner's
approval; versions are permanent.

## Phase 4: reach

- **Gradual typing** (second output mode, needs SMA at run time): untyped
  operations compile to call sites into SMA's binders, typed code to plain
  IL; values flowing into typed variables convert with PowerShell's rules.
  The route for users' untyped scripts. The SMA persistence experiment in
  `experiments/` is the starting point for the call-site half.
- **Speculative compilation** (alternative, entry-guarded only): record
  parameter types in SMA, compile a typed copy, check types at entry, fall
  back to the original script block. Only for functions whose every type
  follows from the parameters.
- **Captured native leaves**: PSLowering output, then RyuJIT, then capture
  of leaf methods (no calls, no GC references, no memory-resident constants)
  under Pwsh AGENTS.md's rule, with every instruction decoded and checked.
  First consumer: a calculator whose logic is one leaf over a fixed state
  layout (needs a raw memory load/store intrinsic), packaged by the
  RyuJitDetach PE writer; console version first.
- **JIT recording**: SuperPMI's collector on a debuggable build as evidence
  of what RyuJIT does per architecture; an oracle, never a producer.

## Practices for agents working here

- Run the full suite on both runtimes before every commit:
  `pwsh -NoProfile -File ./tests/Test-ConsolidatedRunner.ps1` and
  `dotnet tool run pwsh -- -NoLogo -NoProfile -File ./tests/Test-ConsolidatedRunner.ps1`.
- New constructs come with oracle vectors in `tests/oracle/OracleVectors.ps1`
  and, where PowerShell cannot run them (native imports, callbacks), a test
  against an independent answer.
- Run code from files with `-File`; load assemblies by path. A Defender or
  AMSI detection stops the work and is reported.
- Edit through files, not long inline commands: the agent shell evaluates
  commands as strings, and text such as `*` or `/=` can be read as a path.
  Edit scripts that replace exact text must fail when their anchor is not
  found exactly once.
- `$Node.Operator` and similar AST values are enums, not strings; convert
  with `[string]` before string operations. A function returning `, $array`
  must be assigned before it is looped over.
- Commit in small steps with plain factual messages; no AI attribution.
  Push only with the owner's approval.
