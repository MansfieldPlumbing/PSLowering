Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Ast/AstTypeResolver.ps1')
. (Join-Path $PSScriptRoot 'Ast/AstValidator.ps1')
. (Join-Path $PSScriptRoot 'Ast/ClassModel.ps1')
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
        Compiles the classes of a typed PowerShell source file into a managed assembly.
    .DESCRIPTION
        Every class in the file is compiled into one assembly, so classes may
        use each other's types, fields, constructors and methods. Properties
        become public fields; their initial values run in the static
        initializer (static properties) or before each constructor body.
        -ClassName names the class whose methods are reported and which holds
        the -EntryPoint; it defaults to the first class.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SourcePath,
        [Parameter()][string] $ClassName,
        # Emit only these methods of -ClassName. A body that uses an omitted
        # method fails with an error naming it.
        [Parameter()][string[]] $MethodNames,
        [Parameter(Mandatory)][string] $OutputPath,
        [switch] $Deterministic = $true,

        # Name of a static method to make the program's entry point. It must
        # return [int] or [void] and take no parameters or one [string[]].
        # The output is then an executable with a runtime configuration
        # beside it, runnable with `dotnet <OutputPath>`.
        [Parameter()][string] $EntryPoint
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
    $targetClass = $parsed.ClassAst
    $classAsts = @($parsed.Ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $true))
    $model = @(Get-ClassModel -ClassAsts $classAsts)
    Use-ClassMirror -Ast $parsed.Ast
    $mirror = @{} + $script:LoweringClassTypes

    $assemblyName = [IO.Path]::GetFileNameWithoutExtension($OutputPath)
    $session = New-PersistedAssemblySession -AssemblyName $assemblyName
    $declared = [Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly'
    $script:IlMap = @{ Types = @{}; Members = @{} }
    try {
        # 1. Output types, so every signature can name any of them.
        foreach ($c in $model) {
            $tb = $session.Module.DefineType($c.Name, [Reflection.TypeAttributes]'Public,Class')
            $session.Types[$c.Name] = $tb
            $script:IlMap.Types[$mirror[$c.Name]] = $tb
        }

        # 2. Fields, constructors and methods, in source order.
        $plans = foreach ($c in $model) {
            $tb = $session.Types[$c.Name]
            $mirrorType = $mirror[$c.Name]
            foreach ($p in $c.Properties) {
                $mf = $mirrorType.GetField($p.Name, $declared)
                $script:IlMap.Members[$mf] = $tb.DefineField($mf.Name, (Get-IlType $mf.FieldType), $mf.Attributes)
            }
            $constructors = if ($c.Constructors.Count) { $c.Constructors } else { @($null) }
            $ctorPlans = foreach ($ctorAst in $constructors) {
                $types = if ($ctorAst) { Get-ParameterTypes $ctorAst } else { [Type[]]@() }
                $mc = $mirrorType.GetConstructor($declared, $null, $types, $null)
                $cb = $tb.DefineConstructor($mc.Attributes, [Reflection.CallingConventions]::Standard, [Type[]]@($types | ForEach-Object { Get-IlType $_ }))
                if ($ctorAst) {
                    for ($i = 0; $i -lt $ctorAst.Parameters.Count; $i++) { $null = $cb.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $ctorAst.Parameters[$i].Name.VariablePath.UserPath) }
                }
                $script:IlMap.Members[$mc] = $cb
                [pscustomobject]@{ Ast = $ctorAst; Builder = $cb }
            }
            foreach ($n in $c.NativeImports) {
                $types = Get-ParameterTypes $n.Ast
                $mm = $mirrorType.GetMethod($n.Ast.Name, $declared, $null, $types, $null)
                $names = [string[]]@($n.Ast.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
                $script:IlMap.Members[$mm] = Add-NativeImportMethod -TypeBuilder $tb -Name $mm.Name -Import $n.Import `
                    -ReturnType (Get-IlType $mm.ReturnType) -ParameterTypes ([Type[]]@($types | ForEach-Object { Get-IlType $_ })) -ParameterNames $names
            }
            $methods = @($c.Methods)
            if ($MethodNames -and $c.Name -eq $targetClass.Name) { $methods = @($methods | Where-Object { $_.Name -in $MethodNames }) }
            $methodPlans = foreach ($m in $methods) {
                $types = Get-ParameterTypes $m
                $mm = $mirrorType.GetMethod($m.Name, $declared, $null, $types, $null)
                $mb = $tb.DefineMethod($mm.Name, $mm.Attributes, (Get-IlType $mm.ReturnType), [Type[]]@($types | ForEach-Object { Get-IlType $_ }))
                for ($i = 0; $i -lt $m.Parameters.Count; $i++) { $null = $mb.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $m.Parameters[$i].Name.VariablePath.UserPath) }
                $script:IlMap.Members[$mm] = $mb
                [pscustomobject]@{ Ast = $m; Builder = $mb }
            }
            [pscustomobject]@{ Class = $c; Constructors = @($ctorPlans); Methods = @($methodPlans) }
        }

        # 3. Bodies.
        $emittedMethods = [System.Collections.Generic.List[string]]::new()
        $entryBuilder = $null
        foreach ($plan in $plans) {
            $c = $plan.Class
            $staticInits = @($c.Properties | Where-Object { $_.IsStatic -and $_.InitialValue })
            $instanceInits = @($c.Properties | Where-Object { -not $_.IsStatic -and $_.InitialValue })
            if ($staticInits.Count) {
                $lowered = Convert-InitializersToLambda -ClassAst $c.Ast -Initializers $staticInits -Static
                Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $session.Types[$c.Name].DefineTypeInitializer() -IsStatic
            }
            foreach ($ctor in $plan.Constructors) {
                $lowered = if ($ctor.Ast) { Convert-MethodAstToLambda -MethodAst $ctor.Ast -Initializers $instanceInits }
                           else { Convert-InitializersToLambda -ClassAst $c.Ast -Initializers $instanceInits }
                Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $ctor.Builder -HasThis -BaseConstructor
            }
            foreach ($method in $plan.Methods) {
                $lowered = Convert-MethodAstToLambda -MethodAst $method.Ast
                Write-IlMethodBody -Lambda $lowered.Lambda -MethodBuilder $method.Builder -IsStatic:$lowered.IsStatic -HasThis:$lowered.HasThis
                if ($c.Name -eq $targetClass.Name) {
                    $emittedMethods.Add($lowered.Name)
                    if ($EntryPoint -and $lowered.Name -ceq $EntryPoint) {
                        # ECMA-335 II.15.4.1.2: a static method returning int32 or void,
                        # taking no parameters or one string[].
                        $types = @($lowered.ParameterTypes)
                        $validReturn = $lowered.ReturnType -in [int], [void]
                        $validParams = $types.Count -eq 0 -or ($types.Count -eq 1 -and $types[0] -eq [string[]])
                        if (-not $lowered.IsStatic -or -not $validReturn -or -not $validParams) {
                            throw "[{0}:{1}] Entry point '{2}' must be static, return [int] or [void], and take no parameters or one [string[]]." -f `
                                $method.Ast.Extent.StartLineNumber, $method.Ast.Extent.StartColumnNumber, $EntryPoint
                        }
                        $entryBuilder = $method.Builder
                    }
                }
            }
        }
        if ($emittedMethods.Count -eq 0 -and $MethodNames) {
            throw "No matching methods found in class '$($targetClass.Name)' to export."
        }
        if ($EntryPoint -and -not $entryBuilder) {
            throw "Entry point '$EntryPoint' is not an exported method of class '$($targetClass.Name)'."
        }

        # 4. Save.
        $saveResult = Save-PersistedAssemblySession -Session $session -OutputPath $OutputPath -Deterministic:$Deterministic -EntryPoint $entryBuilder
    }
    finally {
        $script:IlMap = @{ Types = @{}; Members = @{} }
    }

    [pscustomobject]@{
        OutputPath     = $saveResult.OutputPath
        Length         = $saveResult.Length
        SHA256         = $saveResult.SHA256
        ClassName      = $targetClass.Name
        Classes        = [string[]]@($model | ForEach-Object Name)
        EmittedMethods = $emittedMethods.ToArray()
        Deterministic  = $saveResult.Deterministic
        EntryPoint     = $saveResult.EntryPoint
        RuntimeConfig  = $saveResult.RuntimeConfig
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
