@{
    RootModule           = 'Dev.MansfieldPlumbing.PowerShell.Lowering.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'b947c6a0-53d1-4e78-9e1d-88f219d3fbc9'
    Author               = 'MansfieldPlumbing'
    Description          = 'Typed PowerShell compiler toolchain lowering admitted methods into managed assemblies without C# or Roslyn.'
    PowerShellVersion    = '7.4'
    FunctionsToExport    = @(
        'Get-LoweringCapability',
        'ConvertTo-TypedExpression',
        'Export-LoweredAssembly',
        'Test-LoweredAssembly'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    PrivateData          = @{
        PSData = @{
            Tags = @('Compiler', 'Lowering', 'PersistedAssemblyBuilder', 'ILGenerator')
        }
    }
}
