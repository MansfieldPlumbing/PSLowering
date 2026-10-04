Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AstTypeResolver.ps1')

$script:NativeImportTypes = [Type[]]@([int], [uint], [long], [ulong], [short], [ushort], [byte], [sbyte], [single], [double], [IntPtr], [UIntPtr])

function Get-AttributeArgumentValue([System.Management.Automation.Language.ExpressionAst] $Argument) {
    # Constants, $true/$false, and static members such as [StringMarshalling]::Utf16.
    if ($Argument -is [System.Management.Automation.Language.MemberExpressionAst] -and $Argument.Static -and
        $Argument.Expression -is [System.Management.Automation.Language.TypeExpressionAst] -and
        $Argument.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        $type = Resolve-AstType $Argument.Expression.TypeName
        $field = $type.GetField($Argument.Member.Value, [Reflection.BindingFlags]'Public,Static')
        if ($field) { return $field.GetValue($null) }
        throw "[{0}:{1}] '{2}' is not a static field." -f $Argument.Extent.StartLineNumber, $Argument.Extent.StartColumnNumber, $Argument.Extent.Text
    }
    $Argument.SafeGetValue()
}

function Get-NativeImport {
    <#
    .SYNOPSIS
        Describes a method marked [System.Runtime.InteropServices.LibraryImport],
        or returns nothing for an ordinary method.
    .DESCRIPTION
        A native import is a static method whose body is a single throw, so it
        stays valid PowerShell and fails plainly if run interpreted. Its
        parameters and return are blittable (integers, floating point,
        IntPtr, UIntPtr), and [string] parameters need StringMarshalling Utf8
        or Utf16.
    #>
    param([Parameter(Mandatory)][System.Management.Automation.Language.FunctionMemberAst] $Function)

    $attribute = $Function.Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
        $_.TypeName.FullName -in 'System.Runtime.InteropServices.LibraryImport', 'System.Runtime.InteropServices.LibraryImportAttribute', 'LibraryImport', 'LibraryImportAttribute'
    } | Select-Object -First 1
    if (-not $attribute) { return }

    $where = { param($Message) "[{0}:{1}] Native import '{2}': {3}" -f $Function.Extent.StartLineNumber, $Function.Extent.StartColumnNumber, $Function.Name, $Message }
    if (-not $Function.IsStatic) { throw (& $where 'must be static.') }
    if ($attribute.PositionalArguments.Count -ne 1) { throw (& $where 'needs the library name as its one positional argument.') }
    $statements = @($Function.Body.EndBlock.Statements)
    if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) {
        throw (& $where 'its body must be a single throw statement.')
    }

    $import = [ordered]@{
        Library           = [string](Get-AttributeArgumentValue $attribute.PositionalArguments[0])
        EntryPoint        = $Function.Name
        StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]::Custom
    }
    $stringMarshallingSet = $false
    foreach ($named in $attribute.NamedArguments) {
        $value = if ($named.ExpressionOmitted) { $true } else { Get-AttributeArgumentValue $named.Argument }
        switch ($named.ArgumentName) {
            'EntryPoint'        { $import.EntryPoint = [string]$value }
            'StringMarshalling' { $import.StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]$value; $stringMarshallingSet = $true }
            'SetLastError'      { if ($value) { throw (& $where 'SetLastError is not supported yet.') } }
            default             { throw (& $where "argument '$($named.ArgumentName)' is not supported.") }
        }
    }

    $return = if ($Function.ReturnType) { Resolve-AstType $Function.ReturnType.TypeName } else { [void] }
    if ($return -ne [void] -and $return -notin $script:NativeImportTypes) { throw (& $where "return type '$($return.FullName)' is not blittable.") }
    $parameterTypes = Get-ParameterTypes $Function
    foreach ($type in $parameterTypes) {
        if ($type -eq [string]) {
            if (-not $stringMarshallingSet -or $import.StringMarshalling -notin 'Utf8', 'Utf16') {
                throw (& $where '[string] parameters need StringMarshalling Utf8 or Utf16.')
            }
            continue
        }
        if ($type -notin $script:NativeImportTypes) { throw (& $where "parameter type '$($type.FullName)' is not blittable.") }
    }
    [pscustomobject]$import
}

function Add-NativeImportMethod {
    # A P/Invoke method on a TypeBuilder: the platform-default calling convention,
    # [string] parameters marshalled as the import's StringMarshalling says.
    param([Reflection.Emit.TypeBuilder] $TypeBuilder, [string] $Name, $Import, [Type] $ReturnType, [Type[]] $ParameterTypes, [string[]] $ParameterNames)
    $charSet = if ($Import.StringMarshalling -eq 'Utf16') { [Runtime.InteropServices.CharSet]::Unicode } else { [Runtime.InteropServices.CharSet]::Ansi }
    $method = $TypeBuilder.DefinePInvokeMethod($Name, $Import.Library, $Import.EntryPoint,
        [Reflection.MethodAttributes]'Public,Static,HideBySig,PinvokeImpl', [Reflection.CallingConventions]::Standard,
        $ReturnType, $ParameterTypes, [Runtime.InteropServices.CallingConvention]::Winapi, $charSet)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    $marshalAs = [Runtime.InteropServices.MarshalAsAttribute].GetConstructor([Type[]]@([Runtime.InteropServices.UnmanagedType]))
    for ($i = 0; $i -lt $ParameterTypes.Length; $i++) {
        $parameter = $method.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $ParameterNames[$i])
        if ($ParameterTypes[$i] -eq [string] -and $Import.StringMarshalling -eq 'Utf8') {
            $parameter.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($marshalAs, [object[]]@([Runtime.InteropServices.UnmanagedType]::LPUTF8Str)))
        }
    }
    $method
}

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
            Constructors  = @($functions | Where-Object IsConstructor)
            Methods       = @($functions | Where-Object { -not $_.IsConstructor -and -not (Get-NativeImport -Function $_) })
            NativeImports = @($functions | Where-Object { -not $_.IsConstructor } | ForEach-Object {
                $import = Get-NativeImport -Function $_
                if ($import) { [pscustomobject]@{ Ast = $_; Import = $import } }
            })
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
        foreach ($n in $c.NativeImports) {
            $return = if ($n.Ast.ReturnType) { Resolve-AstType $n.Ast.ReturnType.TypeName } else { [void] }
            $names = [string[]]@($n.Ast.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
            $null = Add-NativeImportMethod -TypeBuilder $tb -Name $n.Ast.Name -Import $n.Import -ReturnType $return -ParameterTypes (Get-ParameterTypes $n.Ast) -ParameterNames $names
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
