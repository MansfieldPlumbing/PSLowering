# PSPersistence

PSPersistence is a small research repository for preserving selected artifacts
produced by PowerShell's real `System.Management.Automation` (SMA) compiler as
reloadable .NET assemblies.

The repository currently contains one narrow end-to-end persistence experiment
and one independent observation probe. It is not a PowerShell compiler, a
general script-to-DLL converter, or a supported production library.

## What is demonstrated

`experiments/Invoke-OneParameterPersistenceProof.ps1` demonstrates one specific
boundary:

1. Parse a PowerShell class through SMA.
2. Ask SMA for the optimized expression tree of one typed instance method.
3. Replace the method parameter's tuple access with a CLR parameter.
4. Replace supported SMA dynamic-expression binders with persisted call sites.
5. Emit the resulting method into a reloadable assembly.
6. Reload the assembly and verify that the sample method returns `42`.

`probes/Test-SmaCompilation.ps1` separately demonstrates that authentic SMA
expression trees can be compiled and prepared by the runtime. It does not prove
native-code persistence, native-code size, portability, or independence from
PowerShell at run time.

## Verified boundary

The persistence experiment currently requires all of the following:

- PowerShell running on a .NET version that provides
  `System.Reflection.Emit.PersistedAssemblyBuilder`;
- a PowerShell class with one typed, non-static method;
- exactly one typed method parameter;
- SMA's optimized compilation path;
- an expression shape and SMA binder types handled by the experiment;
- a method that produces `42` when invoked with the value `41`, because the
  current command is an executable proof rather than a general exporter.

Other methods, binders, control-flow shapes, constructors, static methods, and
multiple parameters are not claimed to work.

## Run the verification

From the repository root:

```powershell
pwsh -NoLogo -NoProfile -File ./tests/Test-OneParameterPersistence.ps1
pwsh -NoLogo -NoProfile -File ./probes/Test-SmaCompilation.ps1 -BaselineOnly
```

Generated assemblies and diagnostic expression-tree views are written beneath
`build/`, which is ignored by Git.

## Related repositories

- [QuickPS](https://github.com/MansfieldPlumbing/QuickPS) explores graphics and
  native Windows bindings from PowerShell.
- [JS2PS](https://github.com/MansfieldPlumbing/JS2PS) contains JavaScript parsing
  and conformance research. It does not claim a finished converter.

## Status

Exploratory. Private SMA and expression-compiler implementation details can
change between PowerShell and .NET releases. Passing verification describes the
tested runtime and specimen only.

## License

[MIT](LICENSE)
