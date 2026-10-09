# PSLowering

PSLowering lets PowerShell be the language you write managed code in. You
write a typed PowerShell class; PSLowering compiles its methods ahead of time
into a .NET assembly whose methods run as ordinary IL, with no PowerShell
engine, no C#, no Roslyn and no `Add-Type`. The compiler is itself written in
PowerShell.

The complete compiler is the directly executable `Export-LoweredAssembly.ps1`.

## Script operations

Call the script with `&` in the current process to retain live AST and
expression objects. No module import, dot-sourced implementation, helper
script or compiler DLL is required.

| Mode | Result |
|---|---|
| `Compile` (default) | Existing compilation receipt; accepts `SourcePath`, `ClassName`, `MethodNames`, `OutputPath`, `EntryPoint`, `Deterministic` |
| `Expression` | Existing typed-expression object with a live `Lambda`; accepts `MethodAst`, including pipeline input |
| `Inspect` | Existing assembly metadata receipt; accepts `AssemblyPath` |
| `Capability` | Existing capability object |

Use `& ./Export-LoweredAssembly.ps1 -Help` or
`Get-Help ./Export-LoweredAssembly.ps1 -Full` for script help.
`tests/Test-Slice1.ps1` checks a copied standalone script from an unrelated
working directory, deterministic output, all four operations and live
expression inspection. The complete 19-suite runner checks semantic
parity, LambdaCompiler parity, native imports, rejection boundaries,
consumer admission and execution without SMA on PowerShell
7.7.0-preview.5 / .NET 11.0.0-rc.1.26425.128.

The single-file execution model follows read-only `Pwsh/setup.ps1` at
[`3110a85a63a48b2dc1500364cb508d06f3ea3f91`](https://github.com/MansfieldPlumbing/Pwsh/blob/3110a85a63a48b2dc1500364cb508d06f3ea3f91/setup.ps1).
Its source SHA-256 is
`B95525F003601335A79AD0539D6147BF0AD384D4D4CB2E3D8981C49039B6F035`.
Its application functionality is outside this compiler's scope.

## Why it exists

Projects that keep every line of their implementation in PowerShell still
need managed code in places where a PowerShell runspace cannot be used: code
that runs before the engine starts, code that must keep working when it
fails to load, and hot paths that run per frame or per sample. Until now that
code had to be written by hand as `System.Linq.Expressions` trees, node by
node, which is slow to write and hard to review.

PSLowering replaces that with the same method written as typed PowerShell.
Its first consumers:

- **[Pwsh](https://github.com/MansfieldPlumbing/Pwsh)**, PowerShell on Android: the methods of its emitted managed host,
  the console core it lowers for performance, and a recovery path that must
  run without the PowerShell engine. Pwsh's `FindProfile` is here as a
  fixture: 12 lines of typed PowerShell in place of the expression-tree code
  that builds it today, admitted by Pwsh's own persisted-method check.
- **[Kokoro-Hexagon](https://github.com/MansfieldPlumbing/Kokoro-Hexagon)**, a text-to-speech engine:
  the managed control code around its model, such as the `VoiceRowIndex` contract in the fixtures.

## Example

```powershell
# Contract.ps1
class Contract {
    static [int] VoiceRowIndex([int] $phonemeCount) {
        if ($phonemeCount -lt 1 -or $phonemeCount -gt 510) {
            throw [System.ArgumentOutOfRangeException]::new('phonemeCount')
        }
        return $phonemeCount - 1
    }
}
```

```powershell
& ./Export-LoweredAssembly.ps1 -SourcePath ./Contract.ps1 -ClassName Contract -OutputPath ./build/Contract.dll -Deterministic

$type = [Reflection.Assembly]::LoadFile("$PWD/build/Contract.dll").GetType('Contract')
$type.GetMethod('VoiceRowIndex').Invoke($null, @(42))   # 41
```

With `-EntryPoint <method>`, the output is an executable with a runtime
configuration beside it, run with `dotnet <file>.dll`. The entry method must
be static, return `[int]` or `[void]`, and take no parameters or one
`[string[]]`.

`-Mode Capability` reports the PowerShell and .NET versions in use and
the semantic contract. `-Mode Expression` returns a method's
lowered expression tree for inspection, and `-Mode Inspect` checks a
compiled assembly.

## What it compiles

A declared typed subset, exercised by the fixtures in `tests/fixtures`:

- every class in the source file, compiled into one assembly, so classes can
  use each other's types and members, including in generic types such as
  `List[CellBox]`;
- typed properties, compiled as public fields, with initial values; static
  properties are initialized by the type initializer, instance properties
  before each constructor body;
- constructors with typed parameters, and `$this` in constructors and
  instance methods;
- static and instance methods with zero or more typed parameters and typed
  returns, including `[void]`;
- constants, typed locals, assignment, compound assignment (`+=`, `-=`, `*=`,
  `/=`, `%=`) on variables, fields, properties and array elements, increment
  and decrement;
- arithmetic, comparison and Boolean operators on operands of the same type,
  string concatenation with `+`, and the bitwise operators `-band`, `-bor`,
  `-bxor`, `-bnot`, `-shl` and `-shr`;
- `if`/`elseif`/`else`, `while`, `for`, `foreach` over a typed array,
  `break`, `continue` and early `return`;
- typed arrays: creation, literals (typed by their target), indexing with
  PowerShell's negative indexes (`$a[-1]` is the last element), element
  assignment and `Length`;
- calls to .NET static and instance methods, properties, constants and
  constructors, bound by exact signature;
- `throw` and `try`/`catch`/`finally`;
- native imports: a static method marked
  `[System.Runtime.InteropServices.LibraryImport('library', EntryPoint = 'name')]`
  whose body is a single `throw` compiles to a P/Invoke method. Parameters and
  returns are blittable (integers, floating point, `IntPtr`, `UIntPtr`);
  `[string]` parameters need `StringMarshalling` `Utf8` or `Utf16`.
  `SetLastError = $true` keeps errno (or the Win32 last error) for
  `[Runtime.InteropServices.Marshal]::GetLastPInvokeError()`. Mainline
  PowerShell keeps the attribute as metadata and runs the `throw`, so the
  source stays valid PowerShell.

Anything else is rejected before an assembly is written, with its line,
column and reason: commands, pipelines, script blocks, expandable strings,
`do`, `switch`, labeled `break` and `continue`, `break` or `continue`
outside a loop, `foreach` over anything but a typed one-dimensional array,
operators on mixed types, classes deriving from anything but
`System.Object`, untyped properties and parameters, and base constructor
calls with arguments (`tests/Test-Rejections.ps1`). Nothing falls back to
running the original script.

## Guarantees and how they are checked

| Guarantee | Checked by |
| --- | --- |
| A compiled method returns what the same PowerShell method returns, or both throw | `tests/parity/PowerShellParity.ps1`: every fixture method run as PowerShell and as IL on the same inputs (221 calls) |
| The emitter writes the IL the framework's own compiler would accept for the same tree | `tests/parity/LambdaCompilerParity.ps1`: the same trees compiled by `LambdaCompiler`, results compared |
| Output references no `System.Management.Automation` type and no dynamic call site; its only assembly reference is `System.Private.CoreLib` | `tests/Test-ZeroSmaHost.ps1` |
| The same input builds byte-identical assemblies with the same MVID | slices 1, 2, 4 and 5, which build twice and compare SHA-256 and MVID |
| Output passes Pwsh's persisted-method admission | `tests/consumers/Test-PwshAdmission.ps1`: `Test-ExpressionGraph` from Pwsh's `setup.ps1` at a pinned commit and SHA-256 |
| Compiled code runs with the `dotnet` host alone: no PowerShell engine assembly in the process | `tests/Test-DotnetHost.ps1`: a program compiled with `-EntryPoint Main` is run by `dotnet exec`, checks the loaded assemblies itself, and returns the expected exit codes |
| Native imports call the native function with the declared marshalling | `tests/Test-NativeImports.ps1` (Windows): process ID, UTF-16 and UTF-8 string lengths and a tick count against .NET's own answers; invalid declarations rejected |
| The Kokoro `VoiceRowIndex` contract holds | `tests/Test-Slice9.ps1`: all counts 1-510, the out-of-range and Int32 extremes, the exception's parameter name |

## Semantics

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

The runner executes 19 suites, each in its own process, on the one pinned
PowerShell: 7.7.0-preview.5 with .NET 11.0.0-rc.1.26425.128.
`tools/Get-PowerShell.ps1` downloads it (or takes `-ArchivePath` to a copy
already downloaded), checks the SHA-256 GitHub publishes for the release
asset, and extracts it beneath `build/cache`. The pin moves to preview.6 or
to the 7.7 release when either is published. Generated assemblies are
written beneath `build/`, which Git ignores.

Use `-Sanitized` on the existing runner for CI: it reports suite names,
pass/fail results and aggregate metrics. Complete child output and failure
details stay under ignored `build/verification-diagnostics/`; receipts
stay under ignored `build/`. No verification artifacts are uploaded.
GitHub Actions runs the complete suite on hosted Windows runners for
pushes and pull requests, using integrity-verified pinned PowerShell and
standalone .NET runtime archives. Local dotnet-host verification also needs
standalone runtime 11.0.0-rc.1.26425.128 available through `PATH`; the runtime
bundled with PowerShell does not install that standalone host.

## Status and next steps

Version 0.1. Compiled output matched PowerShell on the device for every
parity call of `25427b2` on the x86-64 emulator, an arm64 device and an arm32
device (Pwsh `scripts/probes/lowering`). The ordered plan, with acceptance
gates, principles and the list of what is deliberately not supported, is
[ROADMAP.md](ROADMAP.md).

## Repository layout

- `Export-LoweredAssembly.ps1`: the complete compiler, parameters and execution driver.
- `tests/`: fixtures, parity checks, consumer tests and the consolidated runner.
- `experiments/`: the earlier approach, which persists the expression trees
  SMA's own compiler produces. Its output keeps SMA's semantics and depends
  on SMA at run time; it is kept as a comparison baseline.
- `probes/`: read-only runtime observation.

## License

[MIT](LICENSE)
