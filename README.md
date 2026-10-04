# PSPersistence

PSPersistence compiles methods written as typed PowerShell classes into
managed .NET assemblies, without C#, Roslyn or `Add-Type`. The compiler is
itself written in PowerShell.

It compiles a declared typed subset of the language, not arbitrary scripts.
Compiled methods run without PowerShell: the output's only assembly reference
is `System.Private.CoreLib`.

## How it works

1. Parse the class with `System.Management.Automation`'s parser.
2. Admit or reject each method (`src/Ast/AstValidator.ps1`). Commands,
   pipelines, script blocks and expandable strings are rejected with their
   source position.
3. Lower each method to a `System.Linq.Expressions` tree with PowerShell's
   meaning (`src/Ast/AstLoweringVisitor.ps1`).
4. Write the IL with the compiler's own emitter through public
   `System.Reflection.Emit` APIs (`src/Emitter/IlEmitter.ps1`).
5. Save the assembly with `PersistedAssemblyBuilder` and a deterministic MVID
   (`src/Packaging`).

```powershell
Import-Module ./src/PSPersistence.psd1
Export-LoweredAssembly -SourcePath ./Contract.ps1 -ClassName Contract -OutputPath ./build/Contract.dll -Deterministic
Get-LoweringCapability
```

## Supported subset

Exercised by the fixtures in `tests/fixtures`:

- static and instance methods with zero or more typed parameters and typed
  returns, including `[void]`;
- constants, typed locals, assignment, increment and decrement;
- arithmetic, comparison and Boolean operators on operands of the same type;
- `if`/`elseif`/`else`, `while`, `for` and early `return`;
- typed arrays: creation, literals, indexing, element assignment and
  `Length`;
- calls to .NET static and instance methods, properties and constructors,
  bound by exact signature;
- `throw` and `try`/`catch`/`finally`.

`foreach`, `do`, `switch`, `break` and `continue` are rejected with their source
position.

## Semantics

A compiled method returns what the same typed PowerShell method returns.
`tests/oracle/PowerShellSourceOracle.ps1` checks this by running every
fixture method as PowerShell and as compiled IL on the same inputs
(`tests/oracle/OracleVectors.ps1`).

- Integral `+`, `-`, `*`, `++`, `--` and negation throw `OverflowException` on
  overflow. PowerShell widens the intermediate result and then fails
  converting it back to the method's type, so both sides throw; the
  exception types differ.
- Integral `/` divides as `Double`: `7/2` is `3.5`, and `4` when returned as
  `[int]`. Division by zero throws.
- Conversion from floating point to an integral type rounds half to even and
  throws when out of range or NaN. Integral narrowing throws on overflow.
- String `-eq`, `-ne`, `-lt`, `-le`, `-gt` and `-ge` compare with the
  invariant culture, ignoring case unless the operator is case-sensitive
  (`-ceq` and so on).

Known difference: an integral expression that overflows but is never stored
in or returned as a typed value throws in compiled code, while PowerShell
continues with a `Double`.

## Verification

```powershell
pwsh -NoLogo -NoProfile -File ./tests/Test-ConsolidatedRunner.ps1
```

The runner executes 14 suites, each in its own process:

- the SMA persistence baselines;
- slices 1-9: signatures, arithmetic, comparisons, control flow, arrays,
  .NET calls, exceptions and the Kokoro `VoiceRowIndex` consumer contract;
- the LambdaCompiler oracle, which compiles the same expression trees with
  the framework's compiler and compares results;
- a fresh-process host that loads every compiled assembly without SMA;
- the PowerShell source oracle.

All 14 pass on PowerShell 7.7.0-preview.4 with .NET
11.0.0-preview.6.26359.118. CI runs the pinned PowerShell 7.6.6 .NET tool.

Generated assemblies are written beneath `build/`, which Git ignores.

## The SMA persistence experiment

`experiments/Invoke-OneParameterPersistenceProof.ps1` takes the other route:
it asks SMA's own compiler for a method's expression tree, rewrites parameter
access, persists SMA's dynamic call sites and saves the result. Its output
keeps SMA's semantics and therefore depends on SMA at run time. It is kept as
the baseline the compiler is compared with, verified by
`tests/Test-OneParameterPersistence.ps1` and
`tests/Test-TwoParameterPersistence.ps1`. It relies on private SMA
implementation details that can change between releases.

## Related repositories

- [QuickPS](https://github.com/MansfieldPlumbing/QuickPS) explores graphics and
  native Windows bindings from PowerShell.
- [JS2PS](https://github.com/MansfieldPlumbing/JS2PS) contains JavaScript parsing
  and conformance research. It does not claim a finished converter.

## License

[MIT](LICENSE)
