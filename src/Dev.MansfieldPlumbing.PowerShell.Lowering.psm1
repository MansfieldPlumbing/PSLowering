Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Ast/AstTypeResolver.ps1')
. (Join-Path $PSScriptRoot 'Ast/AstValidator.ps1')
. (Join-Path $PSScriptRoot 'Ast/AstLoweringVisitor.ps1')
. (Join-Path $PSScriptRoot 'Packaging/DeterministicMvid.ps1')
. (Join-Path $PSScriptRoot 'Packaging/AssemblyBuilder.ps1')
. (Join-Path $PSScriptRoot 'Emitter/IlEmitter.ps1')

function Get-LoweringCapability {
    <#
    .SYNOPSIS
        Reports compiler capabilities, runtime versions, and supported contracts.
    #>
    [CmdletBinding()]
    param()

    [pscustomobject]@{
        Product                 = 'Dev.MansfieldPlumbing.PowerShell.Lowering'
        PowerShellVersion       = $PSVersionTable.PSVersion.ToString()
        RuntimeVersion          = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        PersistedAssemblyBuilder = $null -ne ([Type]::GetType('System.Reflection.Emit.PersistedAssemblyBuilder, System.Reflection.Emit'))
        EmitterEngine           = 'PowerShell.IlEmitter'
        SupportedModes          = @('ClrOnly')
        SemanticContract        = 'Typed PowerShell semantics: checked integral arithmetic, Double integral division, round-half-to-even integral conversion, invariant-culture string comparison, IEEE 754 floats, exact reflected member binding'
        DependencyContract      = 'Zero runtime SMA dependencies for ClrOnly output'
    }
}

function ConvertTo-TypedExpression {
    <#
    .SYNOPSIS
        Lowers a PowerShell class method AST into a validated System.Linq.Expressions.LambdaExpression.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.Management.Automation.Language.FunctionMemberAst] $MethodAst
    )

    Convert-MethodAstToLambda -MethodAst $MethodAst
}

function Export-LoweredAssembly {
    <#
    .SYNOPSIS
        Lowers typed PowerShell source and emits a reloadable managed assembly.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter()][string] $ClassName,
        [Parameter()][string[]] $MethodNames,
        [Parameter(Mandatory)][string] $OutputPath,
        [switch] $Deterministic = $true
    )

    $fullSourcePath = if ([IO.Path]::IsPathFullyQualified($SourcePath)) {
        [IO.Path]::GetFullPath($SourcePath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $SourcePath))
    }

    if (-not [IO.File]::Exists($fullSourcePath)) {
        throw "Source file not found: '$fullSourcePath'."
    }

    $source = [IO.File]::ReadAllText($fullSourcePath)
    $parsed = Read-PowerShellClass -Source $source -ClassName $ClassName
    $classAst = $parsed.ClassAst

    $assemblyName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $session = New-PersistedAssemblySession -AssemblyName $assemblyName

    $typeAttrs = [Reflection.TypeAttributes]'Public,Class'
    $tb = $session.Module.DefineType($classAst.Name, $typeAttrs)
    $session.Types[$classAst.Name] = $tb

    # Define public parameterless constructor
    $null = $tb.DefineDefaultConstructor([Reflection.MethodAttributes]'Public')

    $methods = @($classAst.Members | Where-Object {
        $_ -is [System.Management.Automation.Language.FunctionMemberAst] -and -not $_.IsConstructor
    })

    if ($MethodNames -and $MethodNames.Count -gt 0) {
        $methods = @($methods | Where-Object { $_.Name -in $MethodNames })
    }

    if ($methods.Count -eq 0) {
        throw "No matching methods found in class '$($classAst.Name)' to export."
    }

    $emittedMethods = [System.Collections.Generic.List[string]]::new()

    foreach ($m in $methods) {
        $lowered = Convert-MethodAstToLambda -MethodAst $m

        $mAttrs = [Reflection.MethodAttributes]'Public,HideBySig'
        if ($lowered.IsStatic) {
            $mAttrs = $mAttrs -bor [Reflection.MethodAttributes]::Static
        }
        else {
            $mAttrs = $mAttrs -bor [Reflection.MethodAttributes]::Virtual
        }

        $mb = $tb.DefineMethod(
            $lowered.Name,
            $mAttrs,
            $lowered.ReturnType,
            $lowered.ParameterTypes
        )

        for ($i = 0; $i -lt $lowered.ParameterNames.Count; $i++) {
            $null = $mb.DefineParameter(
                ($i + 1),
                [Reflection.ParameterAttributes]::None,
                $lowered.ParameterNames[$i]
            )
        }

        Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $mb -IsStatic:$lowered.IsStatic
        $emittedMethods.Add($lowered.Name)
    }

    $saveResult = Save-PersistedAssemblySession -Session $session -OutputPath $OutputPath -Deterministic:$Deterministic

    [pscustomobject]@{
        OutputPath     = $saveResult.OutputPath
        Length         = $saveResult.Length
        SHA256         = $saveResult.SHA256
        ClassName      = $classAst.Name
        EmittedMethods = $emittedMethods.ToArray()
        Deterministic  = $saveResult.Deterministic
    }
}

function Test-LoweredAssembly {
    <#
    .SYNOPSIS
        Inspects an emitted assembly, validates zero SMA dependencies, and generates a receipt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $AssemblyPath
    )

    $fullPath = [IO.Path]::GetFullPath($AssemblyPath)
    if (-not [IO.File]::Exists($fullPath)) {
        throw "Assembly file not found: '$fullPath'."
    }

    $bytes = [IO.File]::ReadAllBytes($fullPath)
    $sha256 = [BitConverter]::ToString([Security.Cryptography.SHA256]::HashData($bytes)).Replace('-', '')

    $stream = [IO.MemoryStream]::new($bytes, $false)
    $peReader = [Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $meta = [Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $mvid = $meta.GetGuid($meta.GetModuleDefinition().Mvid).ToString()

        $assemblyRefs = [System.Collections.Generic.List[string]]::new()
        foreach ($handle in $meta.AssemblyReferences) {
            $ref = $meta.GetAssemblyReference($handle)
            $refName = $meta.GetString($ref.Name)
            $assemblyRefs.Add($refName)
        }
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    $smaReferenced = $assemblyRefs -contains 'System.Management.Automation'

    [pscustomobject]@{
        AssemblyPath       = $fullPath
        Length             = $bytes.Length
        SHA256             = $sha256
        MVID               = $mvid
        AssemblyReferences = $assemblyRefs.ToArray()
        SmaReferenced      = $smaReferenced
        ClrOnlyAdmitted    = (-not $smaReferenced)
    }
}

Export-ModuleMember -Function Get-LoweringCapability, ConvertTo-TypedExpression, Export-LoweredAssembly, Test-LoweredAssembly
