Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AstTypeResolver.ps1')

function Get-ClassModel {
    <#
    .SYNOPSIS
        Describes the classes compiled together: properties, constructors and methods.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.TypeDefinitionAst[]] $ClassAsts)

    foreach ($class in $ClassAsts) {
        $properties = @($class.Members | Where-Object { $_ -is [System.Management.Automation.Language.PropertyMemberAst] })
        $functions = @($class.Members | Where-Object { $_ -is [System.Management.Automation.Language.FunctionMemberAst] })
        foreach ($p in $properties) {
            if (-not $p.PropertyType) {
                throw "[{0}:{1}] Property `${2} of class {3} needs a type." -f $p.Extent.StartLineNumber, $p.Extent.StartColumnNumber, $p.Name, $class.Name
            }
        }
        if ($class.BaseTypes.Count) {
            throw "[{0}:{1}] Class {2} derives from another type; only classes deriving from System.Object are supported." -f `
                $class.Extent.StartLineNumber, $class.Extent.StartColumnNumber, $class.Name
        }
        [pscustomobject]@{
            Name         = $class.Name
            Ast          = $class
            Properties   = $properties
            Constructors = @($functions | Where-Object IsConstructor)
            Methods      = @($functions | Where-Object { -not $_.IsConstructor })
        }
    }
}

function Get-ParameterTypes([System.Management.Automation.Language.FunctionMemberAst] $Function) {
    , [Type[]]@($Function.Parameters | ForEach-Object {
        $tc = $_.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
        if (-not $tc) {
            throw "[{0}:{1}] Parameter `${2} needs a type." -f $_.Extent.StartLineNumber, $_.Extent.StartColumnNumber, $_.Name.VariablePath.UserPath
        }
        Resolve-AstType $tc.TypeName
    })
}

function New-ClassMirror {
    <#
    .SYNOPSIS
        Defines every class's shape as a real runtime type in a collectible
        in-memory assembly, so method bodies can be lowered against it.
    .DESCRIPTION
        Expression factories validate members by reflection, which classes
        still being emitted cannot answer. The mirror has the same fields,
        constructors and method signatures; its bodies only throw. The emitter
        maps each mirror member to the output assembly's member.
        Registers the mirror types for Resolve-AstType.
    #>
    param([Parameter(Mandatory)][object[]] $Model)

    $name = [Reflection.AssemblyName]::new("PSLoweringMirror$([Guid]::NewGuid().ToString('N'))")
    $assembly = [Reflection.Emit.AssemblyBuilder]::DefineDynamicAssembly($name, [Reflection.Emit.AssemblyBuilderAccess]::RunAndCollect)
    $module = $assembly.DefineDynamicModule($name.Name)
    $notSupported = [NotSupportedException].GetConstructor([Type[]]@())
    $objectCtor = [object].GetConstructor([Type[]]@())

    $builders = [ordered]@{}
    foreach ($c in $Model) {
        $builders[$c.Name] = $module.DefineType($c.Name, [Reflection.TypeAttributes]'Public,Class')
        $script:LoweringClassTypes[$c.Name] = $builders[$c.Name]
    }

    function Write-ThrowBody([Reflection.Emit.ILGenerator] $IL) {
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj, $notSupported)
        $IL.Emit([Reflection.Emit.OpCodes]::Throw)
    }

    foreach ($c in $Model) {
        $tb = $builders[$c.Name]
        foreach ($p in $c.Properties) {
            $attributes = [Reflection.FieldAttributes]::Public
            if ($p.IsStatic) { $attributes = $attributes -bor [Reflection.FieldAttributes]::Static }
            $null = $tb.DefineField($p.Name, (Resolve-AstType $p.PropertyType.TypeName), $attributes)
        }
        $constructors = if ($c.Constructors.Count) { $c.Constructors } else { @($null) }
        foreach ($ctorAst in $constructors) {
            $types = if ($ctorAst) { Get-ParameterTypes $ctorAst } else { [Type[]]@() }
            $cb = $tb.DefineConstructor([Reflection.MethodAttributes]'Public,HideBySig,SpecialName,RTSpecialName',
                [Reflection.CallingConventions]::Standard, $types)
            $il = $cb.GetILGenerator()
            $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
            $il.Emit([Reflection.Emit.OpCodes]::Call, $objectCtor)
            Write-ThrowBody $il
        }
        foreach ($m in $c.Methods) {
            $attributes = [Reflection.MethodAttributes]'Public,HideBySig'
            $attributes = $attributes -bor $(if ($m.IsStatic) { [Reflection.MethodAttributes]::Static } else { [Reflection.MethodAttributes]::Virtual })
            $return = if ($m.ReturnType) { Resolve-AstType $m.ReturnType.TypeName } else { [void] }
            $mb = $tb.DefineMethod($m.Name, $attributes, $return, (Get-ParameterTypes $m))
            Write-ThrowBody $mb.GetILGenerator()
        }
    }

    foreach ($c in $Model) {
        $script:LoweringClassTypes[$c.Name] = $builders[$c.Name].CreateType()
    }
    $types = [ordered]@{}
    foreach ($c in $Model) { $types[$c.Name] = $script:LoweringClassTypes[$c.Name] }
    $types
}

$script:ClassMirrorCache = [System.Runtime.CompilerServices.ConditionalWeakTable[object, hashtable]]::new()

function Use-ClassMirror {
    <#
    .SYNOPSIS
        Makes the classes of the source an AST belongs to resolvable: builds
        their mirror once per parsed source and registers it for Resolve-AstType.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Ast)
    $root = $Ast
    while ($root.Parent) { $root = $root.Parent }
    $types = $null
    if (-not $script:ClassMirrorCache.TryGetValue($root, [ref]$types)) {
        $classes = @($root.FindAll({ param($n) $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass }, $true))
        $script:LoweringClassTypes = @{}
        $mirror = New-ClassMirror -Model @(Get-ClassModel -ClassAsts $classes)
        $types = @{}
        foreach ($name in $mirror.Keys) { $types[$name] = $mirror[$name] }
        $script:ClassMirrorCache.Add($root, $types)
    }
    $script:LoweringClassTypes = @{} + $types
}
