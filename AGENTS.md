# PSLowering repository contract

Keep this repository narrow and evidence-led.

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
  framework's `LambdaCompiler` is used only as an oracle in tests.
- A construct outside the admitted subset is rejected before any artifact is
  written, with the source position and the reason. Nothing falls back to
  running the original script.
- Compiled methods mean what the same typed PowerShell method means.
  `tests/oracle/PowerShellSourceOracle.ps1` runs every fixture method as
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
