# PSLowering repository contract

Keep this repository narrow and evidence-led.

## Purpose and current priority

- Purpose: compile typed PowerShell into IL that keeps PowerShell's meaning
  and references only `System.Private.CoreLib`, so PowerShell-authored code
  runs at compiled speed on CoreCLR without the PowerShell engine.
- Current priority: `ROADMAP.md` item 1.2 (calls through function pointers
  and native callbacks), then 1.1 (the compiled Kokoro session driver).
  Work on anything else only when the owner asks.
- Toolchain: PowerShell 7.7.0-preview.5 on .NET 11.0.0-rc.1.26425.128, from
  `tools/Get-PowerShell.ps1`. No other version is a test target.
- A test that did not run is reported as not run, never as passing.
- Push the day work is done, with the owner's approval; nothing lives only in
  a local clone. Names describe the mechanism.

## What the repository holds

- `src/`: a compiler that lowers methods of a typed PowerShell class to
  managed IL. It parses with authentic `System.Management.Automation`,
  admits a declared typed subset, lowers each admitted method to a
  `System.Linq.Expressions` tree, writes the IL with its own emitter through
  public `System.Reflection.Emit` APIs, and saves the assembly with
  `PersistedAssemblyBuilder`.
- `experiments/`: the bounded experiment that persists expression trees
  produced by SMA's own compiler. It is the baseline the compiler is
  compared with, not the product.
- `probes/`: read-only runtime observation probes.
- `tests/`: executable verification, run together by
  `tests/Test-ConsolidatedRunner.ps1`.
- `build/`: generated output; never source.

## Rules

- The compiler is authored in PowerShell. No C#, no Roslyn, no `Add-Type`
  source compilation, no other implementation language.
- Compiled output must not depend on SMA at run time, must contain no dynamic
  call sites, and must not run PowerShell or reparse source when invoked.
- No private reflection into the framework or SMA in the compiler. The
  framework's `LambdaCompiler` is used only in tests, as a second compiler to compare against.
- A construct outside the admitted subset is rejected before any artifact is
  written, with the source position and the reason. Nothing falls back to
  running the original script.
- Compiled methods mean what the same typed PowerShell method means.
  `tests/parity/PowerShellParity.ps1` runs every fixture method as
  PowerShell and as compiled IL on the same inputs; a divergence is a defect
  in the compiler, never a reason to change the expected result. Where exact
  agreement is impossible, the difference is stated in the README.
- Describe the compiler by its admitted subset. It is not a general
  PowerShell compiler or script-to-DLL converter; do not describe it as one.
- Every capability claim names the test that proves it and the PowerShell
  and .NET versions it ran on.

Do not vendor upstream repositories, generated assemblies, SDK headers, donor
code, graphics work, JavaScript parsing work, Android packaging, or unrelated
application archaeology here.
