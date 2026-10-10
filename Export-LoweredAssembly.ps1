<#
.SYNOPSIS
    Compiles admitted typed PowerShell classes into managed IL.
.DESCRIPTION
    Self-contained compiler with four operations. Compile emits an assembly;
    Expression returns live AST and expression objects in the calling process;
    Inspect reads assembly metadata; Capability reports the admitted contract.
    No module import or external implementation source is required.
.PARAMETER Mode
    Compile (default), Expression, Inspect or Capability.
.PARAMETER SourcePath
    Source file containing typed PowerShell classes.
.PARAMETER ClassName
    Class whose exported methods are reported; defaults to the first class.
.PARAMETER MethodNames
    Optional method selection for ClassName.
.PARAMETER OutputPath
    Destination assembly path; filename determines the assembly name.
.PARAMETER EntryPoint
    Optional static entry point returning int or void, with no parameters or
    one string[] parameter. Writes a runtime configuration beside output.
.PARAMETER Deterministic
    Produces deterministic bytes and MVID. Enabled by default.
.PARAMETER MethodAst
    FunctionMemberAst to lower in Expression mode. Accepts pipeline input.
.PARAMETER AssemblyPath
    Assembly to inspect in Inspect mode.
.PARAMETER Help
    Displays full script help without compiling.
.EXAMPLE
    & ./Export-LoweredAssembly.ps1 -SourcePath ./tests/fixtures/Slice1Fixture.ps1 -ClassName Slice1Fixture -OutputPath ./build/Example.dll -Deterministic
.EXAMPLE
    & ./Export-LoweredAssembly.ps1 -Mode Expression -MethodAst $method
.EXAMPLE
    & ./Export-LoweredAssembly.ps1 -Mode Inspect -AssemblyPath ./build/Example.dll
.EXAMPLE
    & ./Export-LoweredAssembly.ps1 -Mode Capability
#>
[CmdletBinding()]
param(
    [ValidateSet('Compile', 'Expression', 'Inspect', 'Capability')]
    [string] $Mode = 'Compile',
    [string] $SourcePath,
    [string] $ClassName,
    [string[]] $MethodNames,
    [string] $OutputPath,
    [string] $EntryPoint,
    [switch] $Deterministic = $true,
    [Parameter(ValueFromPipeline)]
    [System.Management.Automation.Language.FunctionMemberAst] $MethodAst,
    [string] $AssemblyPath,
    [switch] $Help
)

begin {
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Validate the invocation before parsing source or constructing an assembly.
if (-not $Help) {
    switch ($Mode) {
        'Compile' {
            if ([string]::IsNullOrEmpty($SourcePath)) { throw 'Compile requires -SourcePath.' }
            if ([string]::IsNullOrEmpty($OutputPath)) { throw 'Compile requires -OutputPath.' }
        }
        'Inspect' {
            if ([string]::IsNullOrEmpty($AssemblyPath)) { throw 'Inspect requires -AssemblyPath.' }
        }
    }
}

# Class name -> mirror type for the classes being compiled together; set by
# Export-LoweredAssembly for the duration of one compilation.
$script:LoweringClassTypes = @{}

function Resolve-AstType {
    <#
    .SYNOPSIS
        Resolves an AST TypeName or string into a concrete CLR Type.
    #>
    param(
        [Parameter(Mandatory)]
        $TypeName
    )

    if ($TypeName -is [Type]) {
        return $TypeName
    }

    # Classes compiled together resolve to their mirror types first, so a
    # same-named PowerShell class loaded in this session is never chosen.
    if ($TypeName -is [System.Management.Automation.Language.TypeName] -or $TypeName -is [string]) {
        $simple = if ($TypeName -is [string]) { $TypeName.Trim().Trim('[', ']') } else { $TypeName.FullName }
        if ($script:LoweringClassTypes -and $script:LoweringClassTypes.ContainsKey($simple)) {
            return $script:LoweringClassTypes[$simple]
        }
    }

    # Generic and array names resolve structurally, so their arguments can be
    # classes compiled together: [System.Collections.Generic.List[ConsoleCell]].
    if ($TypeName -is [System.Management.Automation.Language.GenericTypeName]) {
        $arguments = [Type[]]@($TypeName.GenericArguments | ForEach-Object { Resolve-AstType $_ })
        $definitionName = '{0}`{1}' -f $TypeName.TypeName.FullName, $arguments.Count
        $definition = Resolve-AstType $definitionName
        return $definition.MakeGenericType($arguments)
    }
    if ($TypeName -is [System.Management.Automation.Language.ArrayTypeName]) {
        $element = Resolve-AstType $TypeName.ElementType
        return $(if ($TypeName.Rank -eq 1) { $element.MakeArrayType() } else { $element.MakeArrayType($TypeName.Rank) })
    }

    if ($TypeName -is [System.Management.Automation.Language.ITypeName]) {
        $reflectionType = $TypeName.GetReflectionType()
        if ($null -ne $reflectionType) {
            return $reflectionType
        }
        $nameString = $TypeName.FullName
    }
    elseif ($TypeName -is [string]) {
        $nameString = $TypeName
    }
    else {
        throw "Cannot resolve type from unexpected object of type '$($TypeName.GetType().FullName)'."
    }

    $trimmed = $nameString.Trim()
    if ($trimmed.StartsWith('[') -and $trimmed.EndsWith(']') -and -not $trimmed.EndsWith('[]')) {
        $trimmed = $trimmed.Substring(1, $trimmed.Length - 2).Trim()
    }

    if ($trimmed.EndsWith('[]')) {
        $elemName = $trimmed.Substring(0, $trimmed.Length - 2).Trim()
        $elemType = Resolve-AstType $elemName
        return $elemType.MakeArrayType()
    }

    # Common primitive aliases
    switch ($trimmed.ToLowerInvariant()) {
        'void'    { return [void] }
        'int'     { return [int] }
        'int32'   { return [int] }
        'long'    { return [long] }
        'int64'   { return [long] }
        'short'   { return [short] }
        'int16'   { return [short] }
        'byte'    { return [byte] }
        'sbyte'   { return [sbyte] }
        'uint'    { return [uint] }
        'uint32'  { return [uint] }
        'ulong'   { return [ulong] }
        'uint64'  { return [ulong] }
        'ushort'  { return [ushort] }
        'uint16'  { return [ushort] }
        'float'   { return [single] }
        'single'  { return [single] }
        'double'  { return [double] }
        'bool'    { return [bool] }
        'boolean' { return [bool] }
        'char'    { return [char] }
        'string'  { return [string] }
        'object'  { return [object] }
    }

    $clrType = [Type]::GetType($nameString, $false, $true)
    if ($null -ne $clrType) {
        return $clrType
    }

    # Search loaded assemblies
    foreach ($asm in [AppDomain]::CurrentDomain.GetAssemblies()) {
        $found = $asm.GetType($nameString, $false, $true)
        if ($null -ne $found) {
            return $found
        }
    }

    throw "Type '$nameString' could not be resolved to a loaded CLR Type."
}

function Test-AstAdmitted {
    <#
    .SYNOPSIS
        Validates that a PowerShell AST node is within the admitted typed subset.
    .DESCRIPTION
        Rejects pipelines, commands, dynamic resolution, closures, ambient state,
        and unsupported expressions fail-closed with source extent diagnostics.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Ast
    )

    $violations = [System.Collections.Generic.List[pscustomobject]]::new()

    # Disallowed AST node types in compiled methods
    $disallowed = $Ast.FindAll({
        param($node)
        $node -is [System.Management.Automation.Language.CommandAst] -or
        ($node -is [System.Management.Automation.Language.PipelineAst] -and $node.PipelineElements.Count -gt 1) -or
        $node -is [System.Management.Automation.Language.ScriptBlockExpressionAst] -or
        $node -is [System.Management.Automation.Language.ExpandableStringExpressionAst]
    }, $true)

    foreach ($bad in $disallowed) {
        $reason = switch ($bad.GetType().Name) {
            'CommandAst' { "Commands and cmdlets are not allowed in compiled methods." }
            'CommandExpressionAst' { "Command expressions are not allowed in compiled methods." }
            'PipelineAst' { "Multi-element pipelines are not allowed in compiled methods." }
            'ScriptBlockExpressionAst' { "Nested script blocks or lambdas are not allowed in compiled methods." }
            'ExpandableStringExpressionAst' { "Expandable double-quoted strings are not allowed; use string concatenation or single-quoted literals." }
            default { "Unsupported AST node '$($bad.GetType().Name)'." }
        }

        $violations.Add([pscustomobject]@{
            File   = $bad.Extent.File
            Line   = $bad.Extent.StartLineNumber
            Column = $bad.Extent.StartColumnNumber
            Text   = $bad.Extent.Text
            Reason = $reason
        })
    }

    if ($violations.Count -gt 0) {
        $msg = ($violations | ForEach-Object {
            "[{0}:{1}] {2} (near '{3}')" -f $_.Line, $_.Column, $_.Reason, $_.Text
        }) -join "`n"
        throw "AST admission failed:`n$msg"
    }

    return
}

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
        or Utf16. SetLastError = $true keeps errno (or the Win32 last error)
        for [Runtime.InteropServices.Marshal]::GetLastPInvokeError().
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
        SetLastError      = $false
    }
    $stringMarshallingSet = $false
    foreach ($named in $attribute.NamedArguments) {
        if ($named.ArgumentName -notin 'EntryPoint', 'StringMarshalling', 'SetLastError') {
            throw (& $where "argument '$($named.ArgumentName)' is not supported.")
        }
        $value = if ($named.ExpressionOmitted) { $true } else { Get-AttributeArgumentValue $named.Argument }
        switch ($named.ArgumentName) {
            'EntryPoint'        { $import.EntryPoint = [string]$value }
            'StringMarshalling' { $import.StringMarshalling = [System.Runtime.InteropServices.StringMarshalling]$value; $stringMarshallingSet = $true }
            'SetLastError'      { $import.SetLastError = [bool]$value }
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
    # DefinePInvokeMethod cannot set SetLastError; on the persisted builder the
    # DllImport pseudo-attribute replaces the import data with every field
    # (System.Reflection.Emit MethodBuilderImpl.SetCustomAttributeCore,
    # runtime ab19415702aa8139d5369e47c73edb47343c34ad). The mirror's imports
    # are only call targets during lowering, so they never carry it.
    param([Reflection.Emit.TypeBuilder] $TypeBuilder, [string] $Name, $Import, [Type] $ReturnType, [Type[]] $ParameterTypes, [string[]] $ParameterNames, [switch] $Persisted)
    $charSet = if ($Import.StringMarshalling -eq 'Utf16') { [Runtime.InteropServices.CharSet]::Unicode } else { [Runtime.InteropServices.CharSet]::Ansi }
    $method = $TypeBuilder.DefinePInvokeMethod($Name, $Import.Library, $Import.EntryPoint,
        [Reflection.MethodAttributes]'Public,Static,HideBySig,PinvokeImpl', [Reflection.CallingConventions]::Standard,
        $ReturnType, $ParameterTypes, [Runtime.InteropServices.CallingConvention]::Winapi, $charSet)
    $method.SetImplementationFlags([Reflection.MethodImplAttributes]::PreserveSig)
    if ($Persisted -and $Import.SetLastError) {
        $dllImport = [Runtime.InteropServices.DllImportAttribute]
        $fields = [Reflection.FieldInfo[]]@('EntryPoint', 'CharSet', 'CallingConvention', 'SetLastError', 'PreserveSig' | ForEach-Object { $dllImport.GetField($_) })
        $values = [object[]]@($Import.EntryPoint, $charSet, [Runtime.InteropServices.CallingConvention]::Winapi, $true, $true)
        $method.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($dllImport.GetConstructor([Type[]]@([string])), [object[]]@($Import.Library), $fields, $values))
    }
    $marshalAs = [Runtime.InteropServices.MarshalAsAttribute].GetConstructor([Type[]]@([Runtime.InteropServices.UnmanagedType]))
    for ($i = 0; $i -lt $ParameterTypes.Length; $i++) {
        $parameter = $method.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $ParameterNames[$i])
        if ($ParameterTypes[$i] -eq [string] -and $Import.StringMarshalling -eq 'Utf8') {
            $parameter.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($marshalAs, [object[]]@([Runtime.InteropServices.UnmanagedType]::LPUTF8Str)))
        }
    }
    $method
}

# Native expressions retain typed plans for the existing IL emitter.
# No runtime helper or implementation dependency is emitted.
$script:NativeExpressions = [Runtime.CompilerServices.ConditionalWeakTable[object, object]]::new()

function Get-NativeMethodContract {
    param([System.Management.Automation.Language.FunctionMemberAst] $Function)
    $attrs = @($Function.Attributes | Where-Object {
        $_ -is [System.Management.Automation.Language.AttributeAst] -and
        $_.TypeName.FullName -match '(^|\.)(UnmanagedCallersOnly|UnmanagedCallConv)(Attribute)?$'
    })
    if (-not $attrs.Count) { return }
    $where = '[{0}:{1}] Native method ''{2}'': ' -f $Function.Extent.StartLineNumber, $Function.Extent.StartColumnNumber, $Function.Name
    if ($attrs.Count -ne 1) { throw ($where + 'exactly one native contract is allowed.') }
    $a = $attrs[0]
    if ($a.TypeName.FullName -notin 'UnmanagedCallersOnly','UnmanagedCallersOnlyAttribute','System.Runtime.InteropServices.UnmanagedCallersOnly','System.Runtime.InteropServices.UnmanagedCallersOnlyAttribute',
        'UnmanagedCallConv','UnmanagedCallConvAttribute','System.Runtime.InteropServices.UnmanagedCallConv','System.Runtime.InteropServices.UnmanagedCallConvAttribute') {
        throw ($where + 'native contract must name the CoreLib interop attribute.')
    }
    $kind = if ($a.TypeName.FullName -match 'UnmanagedCallersOnly') { 'Callback' } else { 'Calli' }
    if (-not $Function.IsStatic -or $Function.IsConstructor) { throw ($where + 'must be a static method.') }
    if (Get-NativeImport $Function) { throw ($where + 'cannot also be a library import.') }
    if ($a.PositionalArguments.Count -or $a.NamedArguments.Count -ne 1 -or $a.NamedArguments[0].ArgumentName -cne 'CallConvs') {
        throw ($where + 'requires exactly one explicit CallConvs type (Cdecl or Stdcall).')
    }
    $types = @($a.NamedArguments[0].Argument.FindAll({param($n) $n -is [System.Management.Automation.Language.TypeExpressionAst]},$true))
    $text = $a.NamedArguments[0].Argument.Extent.Text
    if ($types.Count -ne 1 -or $text -notmatch '^\[[\w.]+\]$') { throw ($where + 'CallConvs must be one literal convention type.') }
    $convType = Resolve-AstType $types[0].TypeName
    $conv = if ($convType -eq [Runtime.CompilerServices.CallConvCdecl]) { [Runtime.InteropServices.CallingConvention]::Cdecl }
            elseif ($convType -eq [Runtime.CompilerServices.CallConvStdcall]) { [Runtime.InteropServices.CallingConvention]::StdCall }
            else { throw ($where + 'only Cdecl and Stdcall are supported.') }
    $return = if ($Function.ReturnType) { Resolve-AstType $Function.ReturnType.TypeName } else { [void] }
    $parameters = Get-ParameterTypes $Function
    if ($return -ne [void] -and $return -notin $script:NativeImportTypes) { throw ($where + 'return type must be a blittable scalar.') }
    foreach ($t in $parameters) {
        if ($t -notin $script:NativeImportTypes) { throw ($where + 'parameters must be blittable scalars; bool, char, references and byrefs are not supported.') }
    }
    if ($kind -eq 'Calli') {
        if ($parameters.Count -lt 1 -or $parameters[0] -ne [IntPtr]) { throw ($where + 'first parameter must be IntPtr (native pointer width).') }
        $statements = @($Function.Body.EndBlock.Statements)
        if ($statements.Count -ne 1 -or $statements[0] -isnot [System.Management.Automation.Language.ThrowStatementAst]) { throw ($where + 'indirect-call stub body must be a single throw statement.') }
    }
    [pscustomobject]@{Kind=$kind; Convention=$conv; ConventionType=$convType; ReturnType=$return; ParameterTypes=$parameters}
}

function Set-NativeCallbackAttribute {
    param([Reflection.Emit.MethodBuilder]$Builder,$Contract)
    if ($Contract -and $Contract.Kind -eq 'Callback') {
        $type=[Runtime.InteropServices.UnmanagedCallersOnlyAttribute]
        $Builder.SetCustomAttribute([Reflection.Emit.CustomAttributeBuilder]::new($type.GetConstructor([Type[]]@()), [object[]]@(),
            [Reflection.FieldInfo[]]@($type.GetField('CallConvs')), [object[]]@(,[Type[]]@($Contract.ConventionType))))
    }
}

function Convert-NativeAddressExpression {
    param([System.Management.Automation.Language.InvokeMemberExpressionAst]$Node)
    # Exact form: [LocalClass].GetMethod('UniqueCallback').MethodHandle.GetFunctionPointer().
    if ($Node.Static -or $Node.Member.Extent.Text -cne 'GetFunctionPointer' -or $Node.Arguments) { return }
    $handle=$Node.Expression
    if ($handle -isnot [System.Management.Automation.Language.MemberExpressionAst] -or $handle.Static -or $handle.Member.Extent.Text -cne 'MethodHandle') { return }
    $lookup=$handle.Expression
    if ($lookup -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -or $lookup.Static -or
        $lookup.Member.Extent.Text -cne 'GetMethod' -or $lookup.Expression -isnot [System.Management.Automation.Language.TypeExpressionAst] -or
        $lookup.Arguments.Count -ne 1 -or $lookup.Arguments[0] -isnot [System.Management.Automation.Language.StringConstantExpressionAst]) { return }
    $where='[{0}:{1}] Function pointer: ' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber
    $type=Resolve-AstType $lookup.Expression.TypeName
    if ($type -notin $script:LoweringClassTypes.Values) { throw ($where+'target must be a class in this compilation.') }
    $methods=@($type.GetMethods([Reflection.BindingFlags]'Public,Static,Instance,DeclaredOnly') | Where-Object Name -CEQ $lookup.Arguments[0].Value)
    if ($methods.Count -ne 1 -or -not $methods[0].IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) { throw ($where+'target must be one unambiguous UnmanagedCallersOnly method.') }
    $method=$methods[0]
    if ($Mode -eq 'Expression') { throw ($where+'native address acquisition requires Compile mode.') }
    if ($script:IlMap.Members.Count -and -not $script:IlMap.Members.ContainsKey($method)) { throw ($where+'callback target was omitted from this compilation.') }
    $constant=[Linq.Expressions.Expression]::Constant($method,[Reflection.MethodInfo])
    $expr=[Linq.Expressions.Expression]::Call([Linq.Expressions.Expression]::Property($constant,'MethodHandle'),[RuntimeMethodHandle].GetMethod('GetFunctionPointer',[Type[]]@()))
    $script:NativeExpressions.Add($expr,[pscustomobject]@{Kind='Address';Method=$method})
    $expr
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
        foreach ($f in $functions) { $null = Get-NativeMethodContract $f }
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
            Set-NativeCallbackAttribute -Builder $mb -Contract (Get-NativeMethodContract $m)
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

$script:ExpressionNewMethod = [Linq.Expressions.Expression].GetMethod(
    'New',
    [Type[]]@([Reflection.ConstructorInfo], [System.Collections.Generic.IEnumerable[Linq.Expressions.Expression]])
)

# PowerShell's numeric semantics, expressed with CLR operations only. The
# PowerShell parity check (tests/parity/PowerShellParity.ps1) checks
# every rule here against PowerShell itself.
$script:IntegralTypes = [Type[]]@([int], [long], [short], [sbyte], [byte], [ushort], [uint], [ulong])
$script:FloatingTypes = [Type[]]@([double], [single])

function ConvertTo-PowerShellType {
    <#
    .SYNOPSIS
        Converts an expression to a type the way a PowerShell typed assignment,
        cast, argument or return does.
    .DESCRIPTION
        Floating to integral rounds half to even and throws OverflowException
        when out of range or NaN (System.Convert, as PowerShell's numeric
        conversion does). Integral narrowing throws on overflow. A reference
        (an [object], a [string]) converts to a number or [char] through
        System.Convert with the invariant culture: boxed numbers, $null,
        $true/$false and plain numeric text match PowerShell; text PowerShell
        reads but Convert does not ('0x10', '1e3', '5.5') throws instead of
        producing a different value. A reference to [bool] stays an unboxing
        conversion, because PowerShell's [bool]'false' is $true and
        Convert.ToBoolean's is not. Other conversions are plain CLR conversions.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expression,
        [Parameter(Mandatory)][Type] $Type
    )
    $from = $Expression.Type
    if ($from -eq $Type) { return $Expression }
    if ($from -in $script:FloatingTypes -and $Type -in $script:IntegralTypes) {
        $convert = [Convert].GetMethod("To$($Type.Name)", [Type[]]@($from))
        return [Linq.Expressions.Expression]::Call($convert, $Expression)
    }
    if ($from -in $script:IntegralTypes -and $Type -in $script:IntegralTypes) {
        return [Linq.Expressions.Expression]::ConvertChecked($Expression, $Type)
    }
    if (-not $from.IsValueType -and ($Type -in $script:IntegralTypes -or $Type -in $script:FloatingTypes -or $Type -eq [char])) {
        $convert = [Convert].GetMethod("To$($Type.Name)", [Type[]]@([object], [IFormatProvider]))
        $culture = [Linq.Expressions.Expression]::Property($null, [Globalization.CultureInfo].GetProperty('InvariantCulture'))
        $boxed = if ($from -eq [object]) { $Expression } else { [Linq.Expressions.Expression]::Convert($Expression, [object]) }
        return [Linq.Expressions.Expression]::Call($convert, $boxed, $culture)
    }
    [Linq.Expressions.Expression]::Convert($Expression, $Type)
}

function New-PowerShellStringComparison {
    <#
    .SYNOPSIS
        Compares two strings as PowerShell's comparison operators do: through
        the invariant culture's CompareInfo, ignoring case unless the operator
        is case-sensitive (SMA LanguagePrimitives.Equals and Compare).
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right,
        [Parameter(Mandatory)][bool] $CaseSensitive
    )
    $culture = [Linq.Expressions.Expression]::Property($null, [Globalization.CultureInfo].GetProperty('InvariantCulture'))
    $compareInfo = [Linq.Expressions.Expression]::Property($culture, 'CompareInfo')
    $compare = [Globalization.CompareInfo].GetMethod('Compare', [Type[]]@([string], [string], [Globalization.CompareOptions]))
    $options = if ($CaseSensitive) { [Globalization.CompareOptions]::None } else { [Globalization.CompareOptions]::IgnoreCase }
    [Linq.Expressions.Expression]::Call($compareInfo, $compare, $Left, $Right,
        [Linq.Expressions.Expression]::Constant($options, [Globalization.CompareOptions]))
}

function New-PowerShellArithmetic {
    <#
    .SYNOPSIS
        Integral +, -, * fail on overflow where PowerShell would leave the
        type (in a typed method PowerShell then fails converting back).
        Integral / divides as Double, as PowerShell does, after failing on a
        zero divisor. Floating arithmetic is plain IEEE 754.
    #>
    param(
        [Parameter(Mandatory)][string] $Operator,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Left,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Right
    )
    if ($Left.Type -eq [string]) {
        if ($Operator -ne 'Plus') { throw "Operator '$Operator' is not defined for strings." }
        $concat = [string].GetMethod('Concat', [Type[]]@([string], [string]))
        return [Linq.Expressions.Expression]::Call($concat, $Left, $Right)
    }
    $integral = $Left.Type -in $script:IntegralTypes
    switch ($Operator) {
        'Plus'     { if ($integral) { return [Linq.Expressions.Expression]::AddChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Add($Left, $Right) }
        'Minus'    { if ($integral) { return [Linq.Expressions.Expression]::SubtractChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Subtract($Left, $Right) }
        'Multiply' { if ($integral) { return [Linq.Expressions.Expression]::MultiplyChecked($Left, $Right) }; return [Linq.Expressions.Expression]::Multiply($Left, $Right) }
        'Rem'      { return [Linq.Expressions.Expression]::Modulo($Left, $Right) }
        'Divide' {
            if (-not $integral) { return [Linq.Expressions.Expression]::Divide($Left, $Right) }
            $zero = [Linq.Expressions.Expression]::Constant([Convert]::ChangeType(0, $Right.Type), $Right.Type)
            $throw = [Linq.Expressions.Expression]::Throw(
                $script:ExpressionNewMethod.Invoke($null, [object[]]@([DivideByZeroException].GetConstructor([Type[]]@()), [Linq.Expressions.Expression[]]@())), [double])
            $quotient = [Linq.Expressions.Expression]::Divide(
                [Linq.Expressions.Expression]::Convert($Left, [double]),
                [Linq.Expressions.Expression]::Convert($Right, [double]))
            return [Linq.Expressions.Expression]::Condition(
                [Linq.Expressions.Expression]::Equal($Right, $zero), $throw, $quotient)
        }
    }
}

function Get-AstArrayElements($node) {
    if ($node -is [System.Management.Automation.Language.ArrayLiteralAst]) {
        return @($node.Elements)
    }
    if ($node -is [System.Management.Automation.Language.ArrayExpressionAst]) {
        if ($node.SubExpression -and $node.SubExpression.Statements.Count -gt 0) {
            $first = $node.SubExpression.Statements[0]
            if ($first -is [System.Management.Automation.Language.PipelineAst] -and
                $first.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst] -and
                $first.PipelineElements[0].Expression -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                return @($first.PipelineElements[0].Expression.Elements)
            }
            if ($first -is [System.Management.Automation.Language.PipelineAst] -and
                $first.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
                return @($first.PipelineElements[0].Expression)
            }
        }
    }
    return @($node)
}

function New-PowerShellArrayIndex {
    <#
    .SYNOPSIS
        Array element access with PowerShell's index rule: a negative index
        counts from the end ($a[-1] is the last element). Returns the setup
        expressions and the element access; the array and index are evaluated
        once.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Array,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Index,
        [Parameter(Mandatory)][hashtable] $Scope
    )
    $setup = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
    if ($Index.Type -ne [int]) { $Index = ConvertTo-PowerShellType -Expression $Index -Type ([int]) }
    if ($Index -is [Linq.Expressions.ConstantExpression] -and [int]$Index.Value -ge 0) {
        return [pscustomobject]@{ Setup = $setup; Access = [Linq.Expressions.Expression]::ArrayAccess($Array, $Index) }
    }
    $id = $Scope.DeclaredLocals.Count
    if ($Array -isnot [Linq.Expressions.ParameterExpression]) {
        $arrayTemp = [Linq.Expressions.Expression]::Variable($Array.Type, "indexArray$id")
        $Scope.DeclaredLocals.Add($arrayTemp)
        $setup.Add([Linq.Expressions.Expression]::Assign($arrayTemp, $Array))
        $Array = $arrayTemp
    }
    if ($Index -isnot [Linq.Expressions.ParameterExpression]) {
        $indexTemp = [Linq.Expressions.Expression]::Variable([int], "indexValue$id")
        $Scope.DeclaredLocals.Add($indexTemp)
        $setup.Add([Linq.Expressions.Expression]::Assign($indexTemp, $Index))
        $Index = $indexTemp
    }
    $adjusted = [Linq.Expressions.Expression]::Condition(
        [Linq.Expressions.Expression]::LessThan($Index, [Linq.Expressions.Expression]::Constant(0)),
        [Linq.Expressions.Expression]::Add($Index, [Linq.Expressions.Expression]::ArrayLength($Array)),
        $Index)
    [pscustomobject]@{ Setup = $setup; Access = [Linq.Expressions.Expression]::ArrayAccess($Array, $adjusted) }
}

function Convert-AstExpressionAs {
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.Ast] $Node,
        [Parameter(Mandatory)][Type] $Type,
        [Parameter(Mandatory)][hashtable] $Scope
    )
    $inner = $Node
    while ($inner -is [System.Management.Automation.Language.PipelineAst] -and $inner.PipelineElements.Count -eq 1 -and
           $inner.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
        $inner = $inner.PipelineElements[0].Expression
    }
    if ($Type.IsArray -and ($inner -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                            $inner -is [System.Management.Automation.Language.ArrayLiteralAst])) {
        $elementType = $Type.GetElementType()
        $items = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($element in Get-AstArrayElements $inner) {
            $items.Add((Convert-AstExpressionAs -Node $element -Type $elementType -Scope $Scope))
        }
        return [Linq.Expressions.Expression]::NewArrayInit($elementType, [Linq.Expressions.Expression[]]$items.ToArray())
    }
    $value = Convert-AstExpression -Node $Node -Scope $Scope
    if ($value.Type -eq $Type) { return $value }
    if ($value -is [Linq.Expressions.ConstantExpression] -and $null -eq $value.Value -and -not $Type.IsValueType) {
        return [Linq.Expressions.Expression]::Constant($null, $Type)
    }
    ConvertTo-PowerShellType -Expression $value -Type $Type
}

function New-MemberAccess {
    # $target.Name or [Type]::Name as a field or property expression.
    param([Linq.Expressions.Expression] $Target, [Type] $Type, [string] $Name, [System.Management.Automation.Language.Ast] $Node)
    $member = Resolve-MatchingMember -TargetType $Type -MemberName $Name -IsStatic:($null -eq $Target)
    if ($member -is [Reflection.PropertyInfo]) { return [Linq.Expressions.Expression]::Property($Target, $member) }
    [Linq.Expressions.Expression]::Field($Target, $member)
}

function Read-PowerShellClass {
    <#
    .SYNOPSIS
        Parses PowerShell source code and validates the target class definition.
    #>
    param(
        [Parameter(Mandatory)][string] $Source,
        [Parameter()][string] $ClassName
    )

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $Source,
        [ref]$tokens,
        [ref]$errors
    )

    if ($errors -and $errors.Count -gt 0) {
        $messages = ($errors | ForEach-Object { $_.Message }) -join "`n"
        throw "PowerShell syntax parse error:`n$messages"
    }

    $classes = @($ast.FindAll({
        param($n)
        $n -is [System.Management.Automation.Language.TypeDefinitionAst] -and $n.IsClass
    }, $true))

    if ($classes.Count -eq 0) {
        throw 'No class definition found in source.'
    }

    $targetClass = if ($ClassName) {
        $matched = @($classes | Where-Object Name -eq $ClassName)
        if ($matched.Count -ne 1) {
            throw "Expected exactly one class named '$ClassName', found $($matched.Count)."
        }
        $matched[0]
    }
    else {
        $classes[0]
    }

    [pscustomobject]@{
        Ast      = $ast
        ClassAst = $targetClass
    }
}

function Resolve-MatchingMethod {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][string] $MethodName,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]] $ArgumentTypes,
        [switch] $IsStatic
    )

    $flags = [Reflection.BindingFlags]'Public'
    if ($IsStatic) {
        $flags = $flags -bor [Reflection.BindingFlags]::Static
    } else {
        $flags = $flags -bor [Reflection.BindingFlags]::Instance
    }

    # 1. Exact match
    $exact = $TargetType.GetMethod($MethodName, $flags, $null, $ArgumentTypes, $null)
    if ($null -ne $exact) { return $exact }

    # 2. Compatible match
    $all = @($TargetType.GetMethods($flags) | Where-Object {
        $_.Name -eq $MethodName -and $_.GetParameters().Length -eq $ArgumentTypes.Length
    })

    foreach ($candidate in $all) {
        $params = $candidate.GetParameters()
        $match = $true
        for ($i = 0; $i -lt $params.Length; $i++) {
            if (-not $params[$i].ParameterType.IsAssignableFrom($ArgumentTypes[$i])) {
                $match = $false
                break
            }
        }
        if ($match) { return $candidate }
    }

    throw "Could not resolve method '$MethodName' with argument types ($($ArgumentTypes -join ', ')) on '$($TargetType.FullName)'."
}

function Resolve-MatchingConstructor {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][AllowEmptyCollection()][Type[]] $ArgumentTypes
    )

    # 1. Exact match
    $exact = $TargetType.GetConstructor($ArgumentTypes)
    if ($null -ne $exact) { return $exact }

    # 2. Compatible match
    $all = @($TargetType.GetConstructors() | Where-Object {
        $_.GetParameters().Length -eq $ArgumentTypes.Length
    })

    foreach ($candidate in $all) {
        $params = $candidate.GetParameters()
        $match = $true
        for ($i = 0; $i -lt $params.Length; $i++) {
            if (-not $params[$i].ParameterType.IsAssignableFrom($ArgumentTypes[$i])) {
                $match = $false
                break
            }
        }
        if ($match) { return $candidate }
    }

    throw "Could not resolve constructor with argument types ($($ArgumentTypes -join ', ')) on '$($TargetType.FullName)'."
}

function Resolve-MatchingMember {
    param(
        [Parameter(Mandatory)][Type] $TargetType,
        [Parameter(Mandatory)][string] $MemberName,
        [switch] $IsStatic
    )

    $flags = [Reflection.BindingFlags]'Public'
    if ($IsStatic) {
        $flags = $flags -bor [Reflection.BindingFlags]::Static
    } else {
        $flags = $flags -bor [Reflection.BindingFlags]::Instance
    }

    $prop = $TargetType.GetProperty($MemberName, $flags)
    if ($null -ne $prop) { return $prop }

    $field = $TargetType.GetField($MemberName, $flags)
    if ($null -ne $field) { return $field }

    throw "Could not resolve property or field '$MemberName' on '$($TargetType.FullName)'."
}

function Convert-AstExpression {
    <#
    .SYNOPSIS
        Converts an individual AST expression node into a typed LINQ Expression.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Node,

        [Parameter(Mandatory)]
        [hashtable] $Scope
    )

    # The concrete worker consumer needs a literal ThreadStart delegate type.
    if ($Node -is [System.Management.Automation.Language.TypeExpressionAst]) {
        $type = Resolve-AstType $Node.TypeName
        if ($type -eq [Threading.ThreadStart]) { return [Linq.Expressions.Expression]::Constant($type,[Type]) }
        throw ('[{0}:{1}] Only the ThreadStart type literal is admitted as a value.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
    }
    # 1. Constant literals
    if ($Node -is [System.Management.Automation.Language.ConstantExpressionAst]) {
        $val = $Node.Value
        $type = if ($null -eq $val) { [object] } else { $val.GetType() }
        return [Linq.Expressions.Expression]::Constant($val, $type)
    }

    # 2. String constant expressions
    if ($Node -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
        return [Linq.Expressions.Expression]::Constant($Node.Value, [string])
    }

    # 3. Variable references ($true, $false, $null, parameters, locals)
    if ($Node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        $varName = $Node.VariablePath.UserPath
        switch ($varName.ToLowerInvariant()) {
            'true'  { return [Linq.Expressions.Expression]::Constant($true, [bool]) }
            'false' { return [Linq.Expressions.Expression]::Constant($false, [bool]) }
            'null'  { return [Linq.Expressions.Expression]::Constant($null, [object]) }
        }

        if ($varName -eq 'this') {
            if (-not $Scope.This) {
                throw "[{0}:{1}] `$this is not available in a static method." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
            }
            return $Scope.This
        }
        if ($Scope.Parameters.ContainsKey($varName)) {
            return $Scope.Parameters[$varName]
        }
        if ($Scope.Locals.ContainsKey($varName)) {
            return $Scope.Locals[$varName]
        }

        throw "[{0}:{1}] Unresolved variable `$$varName." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
    }

    # 4. CommandExpressionAst wrapper
    if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) {
        return Convert-AstExpression -Node $Node.Expression -Scope $Scope
    }

    # 5. Pipeline wrapper around single expression (e.g. statement in pipeline)
    if ($Node -is [System.Management.Automation.Language.PipelineAst]) {
        if ($Node.PipelineElements.Count -eq 1 -and
            $Node.PipelineElements[0] -is [System.Management.Automation.Language.CommandExpressionAst]) {
            return Convert-AstExpression -Node $Node.PipelineElements[0].Expression -Scope $Scope
        }
    }

    # 5. Paren expressions: ( $expr )
    if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) {
        return Convert-AstExpression -Node $Node.Pipeline -Scope $Scope
    }



    # 6. Type casts: [int]$x or [int[]]@(...)
    if ($Node -is [System.Management.Automation.Language.ConvertExpressionAst]) {
        $targetType = Resolve-AstType $Node.Type.TypeName
        if ($targetType.IsArray) {
            $childNode = $Node.Child
            if ($childNode -is [System.Management.Automation.Language.ArrayExpressionAst] -or
                $childNode -is [System.Management.Automation.Language.ArrayLiteralAst]) {
                $elements = Get-AstArrayElements $childNode
                $elemType = $targetType.GetElementType()
                $elemExprList = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
                foreach ($el in $elements) {
                    $itemExpr = Convert-AstExpression -Node $el -Scope $Scope
                    if ($itemExpr.Type -ne $elemType) {
                        $itemExpr = (ConvertTo-PowerShellType -Expression $itemExpr -Type ($elemType))
                    }
                    $elemExprList.Add($itemExpr)
                }
                return [Linq.Expressions.Expression]::NewArrayInit($elemType, [Linq.Expressions.Expression[]]$elemExprList.ToArray())
            }
        }
        $child = Convert-AstExpression -Node $Node.Child -Scope $Scope
        return (ConvertTo-PowerShellType -Expression $child -Type ($targetType))
    }

    # 7. Unary arithmetic expressions: -$x, ++$x, --$x, $x++, $x--
    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') {
            $target = Convert-AstExpression -Node $Node.Child -Scope $Scope
            $one = [Linq.Expressions.Expression]::Constant(1, $target.Type)
            if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus') {
                return [Linq.Expressions.Expression]::Assign($target, (New-PowerShellArithmetic -Operator Plus -Left $target -Right $one))
            } else {
                return [Linq.Expressions.Expression]::Assign($target, (New-PowerShellArithmetic -Operator Minus -Left $target -Right $one))
            }
        }

        $operand = Convert-AstExpression -Node $Node.Child -Scope $Scope
        switch ($Node.TokenKind) {
            'Minus'   {
                if ($operand.Type -in $script:IntegralTypes) { return [Linq.Expressions.Expression]::NegateChecked($operand) }
                return [Linq.Expressions.Expression]::Negate($operand)
            }
            'Plus'    { return $operand }
            'Not'     { return [Linq.Expressions.Expression]::Not($operand) }
            'Bnot'    {
                if ($operand.Type -notin $script:IntegralTypes) {
                    throw "[{0}:{1}] -bnot requires an integral operand, got '{2}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $operand.Type.FullName
                }
                return [Linq.Expressions.Expression]::Not($operand)
            }
            'Exclaim' { return [Linq.Expressions.Expression]::Not($operand) }
            default {
                throw "[{0}:{1}] Unsupported unary operator '{2}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.TokenKind
            }
        }
    }

    # 8. Binary arithmetic and comparison expressions
    if ($Node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        $left = Convert-AstExpression -Node $Node.Left -Scope $Scope
        $right = Convert-AstExpression -Node $Node.Right -Scope $Scope

        if ($Node.Operator -in 'Shl', 'Shr') {
            if ($left.Type -notin $script:IntegralTypes -or $right.Type -ne [int]) {
                throw "[{0}:{1}] -{2} requires an integral left operand and an [int] shift count, got '{3}' and '{4}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator.ToString().ToLowerInvariant(), $left.Type.FullName, $right.Type.FullName
            }
            if ($Node.Operator -eq 'Shl') { return [Linq.Expressions.Expression]::LeftShift($left, $right) }
            return [Linq.Expressions.Expression]::RightShift($left, $right)
        }

        if ($left.Type -ne $right.Type) {
            throw "[{0}:{1}] Binary operator '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator, $left.Type.FullName, $right.Type.FullName
        }

        if ($left.Type -eq [string] -and $Node.Operator -match '^[IC](eq|ne|lt|le|gt|ge)$') {
            $compared = New-PowerShellStringComparison -Left $left -Right $right -CaseSensitive ([string]$Node.Operator).StartsWith('C', [StringComparison]::Ordinal)
            $zero = [Linq.Expressions.Expression]::Constant(0)
            switch -Regex ($Node.Operator) {
                'eq$' { return [Linq.Expressions.Expression]::Equal($compared, $zero) }
                'ne$' { return [Linq.Expressions.Expression]::NotEqual($compared, $zero) }
                'lt$' { return [Linq.Expressions.Expression]::LessThan($compared, $zero) }
                'le$' { return [Linq.Expressions.Expression]::LessThanOrEqual($compared, $zero) }
                'gt$' { return [Linq.Expressions.Expression]::GreaterThan($compared, $zero) }
                'ge$' { return [Linq.Expressions.Expression]::GreaterThanOrEqual($compared, $zero) }
            }
        }

        switch ($Node.Operator) {
            { $_ -in 'Plus', 'Minus', 'Multiply', 'Divide', 'Rem' } { return New-PowerShellArithmetic -Operator $Node.Operator -Left $left -Right $right }
            { $_ -in 'Band', 'Bor', 'Bxor' } {
                if ($left.Type -notin $script:IntegralTypes) {
                    throw "[{0}:{1}] -{2} requires integral operands, got '{3}'." -f $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator.ToString().ToLowerInvariant(), $left.Type.FullName
                }
                switch ($Node.Operator) {
                    'Band' { return [Linq.Expressions.Expression]::And($left, $right) }
                    'Bor'  { return [Linq.Expressions.Expression]::Or($left, $right) }
                    'Bxor' { return [Linq.Expressions.Expression]::ExclusiveOr($left, $right) }
                }
            }
            { $_ -in 'Ieq', 'Ceq' } { return [Linq.Expressions.Expression]::Equal($left, $right) }
            { $_ -in 'Ine', 'Cne' } { return [Linq.Expressions.Expression]::NotEqual($left, $right) }
            { $_ -in 'Ilt', 'Clt' } { return [Linq.Expressions.Expression]::LessThan($left, $right) }
            { $_ -in 'Ile', 'Cle' } { return [Linq.Expressions.Expression]::LessThanOrEqual($left, $right) }
            { $_ -in 'Igt', 'Cgt' } { return [Linq.Expressions.Expression]::GreaterThan($left, $right) }
            { $_ -in 'Ige', 'Cge' } { return [Linq.Expressions.Expression]::GreaterThanOrEqual($left, $right) }
            'And'      { return [Linq.Expressions.Expression]::AndAlso($left, $right) }
            'Or'       { return [Linq.Expressions.Expression]::OrElse($left, $right) }
            default {
                throw "[{0}:{1}] Unsupported binary operator '{2}'." -f `
                    $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator
            }
        }
    }

    # 9. Array index read: $arr[$i]
    if ($Node -is [System.Management.Automation.Language.IndexExpressionAst]) {
        $targetExpr = Convert-AstExpression -Node $Node.Target -Scope $Scope
        $idxExpr = Convert-AstExpression -Node $Node.Index -Scope $Scope
        if ($targetExpr.Type.IsArray -and $targetExpr.Type.GetArrayRank() -eq 1) {
            $element = New-PowerShellArrayIndex -Array $targetExpr -Index $idxExpr -Scope $Scope
            $read = [Linq.Expressions.Expression]::ArrayIndex($element.Access.Object, $element.Access.Arguments[0])
            if ($element.Setup.Count -eq 0) { return $read }
            $element.Setup.Add($read)
            return [Linq.Expressions.Expression]::Block($read.Type, [Linq.Expressions.Expression[]]$element.Setup.ToArray())
        }
        throw "[{0}:{1}] Indexing into non-array type '{2}' is not supported." -f `
            $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $targetExpr.Type.FullName
    }

    # 10. Invoke Member Expression: [T]::Method(...) or $inst.Method(...) or [T]::new(...)
    if ($Node -is [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $address = Convert-NativeAddressExpression $Node
        if ($address) { return $address }
        $memberName = if ($Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $Node.Member.Value
        } else {
            $Node.Member.Extent.Text
        }

        # Convert arguments
        $argExprs = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        if ($Node.Arguments) {
            foreach ($arg in $Node.Arguments) {
                $argExprs.Add((Convert-AstExpression -Node $arg -Scope $Scope))
            }
        }
        $argTypes = [Type[]]@($argExprs | ForEach-Object { $_.Type })

        if ($Node.Static) {
            $targetType = if ($Node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                Resolve-AstType $Node.Expression.TypeName
            } else {
                Resolve-AstType $Node.Expression.Extent.Text
            }

            # Array allocation: [T[]]::new(count)
            if ($targetType.IsArray -and $memberName -eq 'new') {
                if ($argExprs.Count -ne 1) {
                    throw "[{0}:{1}] Array constructor requires exactly 1 length argument." -f `
                        $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber
                }
                $lenExpr = $argExprs[0]
                if ($lenExpr.Type -ne [int]) {
                    $lenExpr = (ConvertTo-PowerShellType -Expression $lenExpr -Type ([int]))
                }
                return [Linq.Expressions.Expression]::NewArrayBounds($targetType.GetElementType(), $lenExpr)
            }

            # Object constructor: [T]::new(...)
            if ($memberName -eq 'new') {
                $ctor = Resolve-MatchingConstructor -TargetType $targetType -ArgumentTypes $argTypes
                $params = $ctor.GetParameters()
                for ($i = 0; $i -lt $params.Length; $i++) {
                    if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                        $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                    }
                }
                return $script:ExpressionNewMethod.Invoke($null, @($ctor, [Linq.Expressions.Expression[]]$argExprs.ToArray()))
            }

            # Static method call: [T]::Method(...)
            $method = Resolve-MatchingMethod -TargetType $targetType -MethodName $memberName -ArgumentTypes $argTypes -IsStatic
            if ($method.IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) {
                throw ('[{0}:{1}] UnmanagedCallersOnly method cannot be called from managed code.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
            }
            $params = $method.GetParameters()
            for ($i = 0; $i -lt $params.Length; $i++) {
                if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                    $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                }
            }
            return [Linq.Expressions.Expression]::Call($method, [Linq.Expressions.Expression[]]$argExprs.ToArray())
        }
        else {
            # Instance method call: $inst.Method(...)
            $targetExpr = Convert-AstExpression -Node $Node.Expression -Scope $Scope
            $method = Resolve-MatchingMethod -TargetType $targetExpr.Type -MethodName $memberName -ArgumentTypes $argTypes
            if ($method.IsDefined([Runtime.InteropServices.UnmanagedCallersOnlyAttribute],$false)) {
                throw ('[{0}:{1}] UnmanagedCallersOnly method cannot be called from managed code.' -f $Node.Extent.StartLineNumber,$Node.Extent.StartColumnNumber)
            }
            $params = $method.GetParameters()
            for ($i = 0; $i -lt $params.Length; $i++) {
                if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                    $argExprs[$i] = (ConvertTo-PowerShellType -Expression $argExprs[$i] -Type ($params[$i].ParameterType))
                }
            }
            return [Linq.Expressions.Expression]::Call($targetExpr, $method, [Linq.Expressions.Expression[]]$argExprs.ToArray())
        }
    }

    # 11. Member expression: $arr.Length, $inst.Prop, [T]::Prop
    if ($Node -is [System.Management.Automation.Language.MemberExpressionAst] -and
        $Node -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
        $memberName = if ($Node.Member -is [System.Management.Automation.Language.StringConstantExpressionAst]) {
            $Node.Member.Value
        } else {
            $Node.Member.Extent.Text
        }

        if ($Node.Static) {
            $targetType = if ($Node.Expression -is [System.Management.Automation.Language.TypeExpressionAst]) {
                Resolve-AstType $Node.Expression.TypeName
            } else {
                Resolve-AstType $Node.Expression.Extent.Text
            }
            return New-MemberAccess -Target $null -Type $targetType -Name $memberName -Node $Node
        }
        else {
            $targetExpr = Convert-AstExpression -Node $Node.Expression -Scope $Scope
            if ($targetExpr.Type.IsArray -and $memberName -eq 'Length') {
                return [Linq.Expressions.Expression]::ArrayLength($targetExpr)
            }
            return New-MemberAccess -Target $targetExpr -Type $targetExpr.Type -Name $memberName -Node $Node
        }
    }

    throw "[{0}:{1}] Unsupported AST expression '{2}' ({3})." -f `
        $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Extent.Text, $Node.GetType().Name
}

function Convert-AstStatement {
    <#
    .SYNOPSIS
        Converts an individual AST statement into a typed LINQ Expression.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.Ast] $Statement,

        [Parameter(Mandatory)]
        [hashtable] $Scope
    )

    # 1. Assignment statement: $x = <expr>, [int]$x = <expr>, or $arr[$i] = <expr>
    if ($Statement -is [System.Management.Automation.Language.AssignmentStatementAst]) {
        $leftNode = $Statement.Left

        if ($Statement.Operator -ne [System.Management.Automation.Language.TokenKind]::Equals) {
            $compound = @{ PlusEquals = 'Plus'; MinusEquals = 'Minus'; MultiplyEquals = 'Multiply'; DivideEquals = 'Divide'; RemainderEquals = 'Rem' }[[string]$Statement.Operator]
            if (-not $compound) {
                throw "[{0}:{1}] Unsupported assignment operator '{2}'." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator
            }
            if ($leftNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
                # The array and index are evaluated once, then the element is read,
                # combined and stored back.
                $arrayExpr = Convert-AstExpression -Node $leftNode.Target -Scope $Scope
                if (-not $arrayExpr.Type.IsArray -or $arrayExpr.Type.GetArrayRank() -ne 1) {
                    throw "[{0}:{1}] Compound assignment into non-array type '{2}' is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $arrayExpr.Type.FullName
                }
                $element = New-PowerShellArrayIndex -Array $arrayExpr -Index (Convert-AstExpression -Node $leftNode.Index -Scope $Scope) -Scope $Scope
                $right = Convert-AstExpression -Node $Statement.Right -Scope $Scope
                if ($right.Type -ne $element.Access.Type) {
                    throw "[{0}:{1}] Compound assignment '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                        $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator, $element.Access.Type.FullName, $right.Type.FullName
                }
                $combined = New-PowerShellArithmetic -Operator $compound -Left $element.Access -Right $right
                $element.Setup.Add([Linq.Expressions.Expression]::Assign($element.Access, (ConvertTo-PowerShellType -Expression $combined -Type $element.Access.Type)))
                $element.Setup.Add([Linq.Expressions.Expression]::Empty())
                return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$element.Setup.ToArray())
            }
            if ($leftNode -isnot [System.Management.Automation.Language.VariableExpressionAst] -and
                -not ($leftNode -is [System.Management.Automation.Language.MemberExpressionAst] -and
                      $leftNode -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst] -and
                      ($leftNode.Static -or $leftNode.Expression -is [System.Management.Automation.Language.VariableExpressionAst]))) {
                throw "[{0}:{1}] Compound assignment '{2}' is supported only on a variable or a member of a variable or type." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator
            }
            $target = Convert-AstExpression -Node $leftNode -Scope $Scope
            $right = Convert-AstExpression -Node $Statement.Right -Scope $Scope
            if ($right.Type -ne $target.Type) {
                throw "[{0}:{1}] Compound assignment '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Operator, $target.Type.FullName, $right.Type.FullName
            }
            $value = New-PowerShellArithmetic -Operator $compound -Left $target -Right $right
            return [Linq.Expressions.Expression]::Assign($target, (ConvertTo-PowerShellType -Expression $value -Type $target.Type))
        }

        # Array element assignment: $arr[$i] = <expr>
        if ($leftNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $targetExpr = Convert-AstExpression -Node $leftNode.Target -Scope $Scope
            $idxExpr = Convert-AstExpression -Node $leftNode.Index -Scope $Scope
            if (-not $targetExpr.Type.IsArray) {
                throw "[{0}:{1}] Cannot assign into non-array type '{2}'." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $targetExpr.Type.FullName
            }
            $elemType = $targetExpr.Type.GetElementType()
            $element = New-PowerShellArrayIndex -Array $targetExpr -Index $idxExpr -Scope $Scope
            $valExpr = Convert-AstExpressionAs -Node $Statement.Right -Type $elemType -Scope $Scope
            $store = [Linq.Expressions.Expression]::Assign($element.Access, $valExpr)
            if ($element.Setup.Count -eq 0) { return $store }
            $element.Setup.Add($store)
            $element.Setup.Add([Linq.Expressions.Expression]::Empty())
            return [Linq.Expressions.Expression]::Block([Linq.Expressions.Expression[]]$element.Setup.ToArray())
        }

        if ($leftNode -is [System.Management.Automation.Language.MemberExpressionAst] -and
            $leftNode -isnot [System.Management.Automation.Language.InvokeMemberExpressionAst]) {
            $memberTarget = Convert-AstExpression -Node $leftNode -Scope $Scope
            if ($memberTarget -isnot [Linq.Expressions.MemberExpression]) {
                throw "[{0}:{1}] Cannot assign to '{2}'." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $leftNode.Extent.Text
            }
            if ($memberTarget.Member -is [Reflection.PropertyInfo] -and -not $memberTarget.Member.CanWrite) {
                throw "[{0}:{1}] Property '{2}' is read-only." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $memberTarget.Member.Name
            }
            $valueForMember = Convert-AstExpressionAs -Node $Statement.Right -Type $memberTarget.Type -Scope $Scope
            return [Linq.Expressions.Expression]::Assign($memberTarget, $valueForMember)
        }

        $varName = $null
        $explicitType = $null

        if ($leftNode -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $varName = $leftNode.VariablePath.UserPath
        }
        elseif ($leftNode -is [System.Management.Automation.Language.ConvertExpressionAst] -and
                $leftNode.Child -is [System.Management.Automation.Language.VariableExpressionAst]) {
            $explicitType = Resolve-AstType $leftNode.Type.TypeName
            $varName = $leftNode.Child.VariablePath.UserPath
        }
        else {
            throw "[{0}:{1}] Unsupported assignment target '{2}'." -f `
                $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $leftNode.Extent.Text
        }

        $knownType = if ($explicitType) { $explicitType }
                     elseif ($Scope.Parameters.ContainsKey($varName)) { $Scope.Parameters[$varName].Type }
                     elseif ($Scope.Locals.ContainsKey($varName)) { $Scope.Locals[$varName].Type }
                     else { $null }
        $valExpr = if ($knownType) { Convert-AstExpressionAs -Node $Statement.Right -Type $knownType -Scope $Scope }
                   else { Convert-AstExpression -Node $Statement.Right -Scope $Scope }

        if ($explicitType -and $valExpr.Type -ne $explicitType) {
            $valExpr = (ConvertTo-PowerShellType -Expression $valExpr -Type ($explicitType))
        }

        $targetVar = $null
        if ($Scope.Parameters.ContainsKey($varName)) {
            $targetVar = $Scope.Parameters[$varName]
        }
        elseif ($Scope.Locals.ContainsKey($varName)) {
            $targetVar = $Scope.Locals[$varName]
        }
        else {
            $localType = if ($explicitType) { $explicitType } else { $valExpr.Type }
            $targetVar = [Linq.Expressions.Expression]::Variable($localType, $varName)
            $Scope.Locals[$varName] = $targetVar
            $Scope.DeclaredLocals.Add($targetVar)
        }

        if ($valExpr.Type -ne $targetVar.Type) {
            $valExpr = (ConvertTo-PowerShellType -Expression $valExpr -Type ($targetVar.Type))
        }

        return [Linq.Expressions.Expression]::Assign($targetVar, $valExpr)
    }

    # 2. Return statement
    if ($Statement -is [System.Management.Automation.Language.ReturnStatementAst]) {
        if ($null -eq $Statement.Pipeline) {
            # Void return
            if ($Scope.ReturnType -ne [void]) {
                throw "[{0}:{1}] Empty return statement in non-void method." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber
            }
            return [Linq.Expressions.Expression]::Return($Scope.ReturnTarget)
        }

        $retVal = Convert-AstExpressionAs -Node $Statement.Pipeline -Type $Scope.ReturnType -Scope $Scope

        return [Linq.Expressions.Expression]::Return($Scope.ReturnTarget, $retVal)
    }

    # 3. Statement block: { stmt1; stmt2 }
    if ($Statement -is [System.Management.Automation.Language.StatementBlockAst]) {
        $stmtList = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
        foreach ($s in $Statement.Statements) {
            $stmtList.Add((Convert-AstStatement -Statement $s -Scope $Scope))
        }
        $stmtList.Add([Linq.Expressions.Expression]::Empty())
        return [Linq.Expressions.Expression]::Block($stmtList)
    }

    # 4. If statement: if ($c) { $t } elseif ($c2) { $t2 } else { $e }
    if ($Statement -is [System.Management.Automation.Language.IfStatementAst]) {
        $elseExpr = if ($Statement.ElseClause) {
            Convert-AstStatement -Statement $Statement.ElseClause -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Empty()
        }

        $clauses = @($Statement.Clauses)
        for ($i = $clauses.Count - 1; $i -ge 0; $i--) {
            $cond = Convert-AstExpression -Node $clauses[$i].Item1 -Scope $Scope
            $then = Convert-AstStatement -Statement $clauses[$i].Item2 -Scope $Scope
            $elseExpr = [Linq.Expressions.Expression]::IfThenElse($cond, $then, $elseExpr)
        }

        return $elseExpr
    }

    # 5. For statement: for ($i = 0; $i -lt $n; $i++) { ... }
    if ($Statement -is [System.Management.Automation.Language.ForStatementAst]) {
        $blockStmts = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

        if ($Statement.Initializer) {
            $blockStmts.Add((Convert-AstStatement -Statement $Statement.Initializer -Scope $Scope))
        }

        $breakLabel = [Linq.Expressions.Expression]::Label('forBreak')
        $continueLabel = [Linq.Expressions.Expression]::Label('forContinue')

        $condExpr = if ($Statement.Condition) {
            Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Constant($true, [bool])
        }

        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $iterExpr = if ($Statement.Iterator) {
            Convert-AstStatement -Statement $Statement.Iterator -Scope $Scope
        } else {
            [Linq.Expressions.Expression]::Empty()
        }

        $loopBody = [Linq.Expressions.Expression]::Block(
            $bodyExpr,
            [Linq.Expressions.Expression]::Label($continueLabel),
            $iterExpr,
            [Linq.Expressions.Expression]::Empty()
        )

        $loopExpr = [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                $condExpr,
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)
            ),
            $breakLabel
        )

        $blockStmts.Add($loopExpr)
        $blockStmts.Add([Linq.Expressions.Expression]::Empty())
        return [Linq.Expressions.Expression]::Block($blockStmts)
    }

    # 6. While statement: while ($cond) { ... }
    if ($Statement -is [System.Management.Automation.Language.WhileStatementAst]) {
        $breakLabel = [Linq.Expressions.Expression]::Label('whileBreak')
        $continueLabel = [Linq.Expressions.Expression]::Label('whileContinue')

        $condExpr = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $loopBody = [Linq.Expressions.Expression]::Block(
            $bodyExpr,
            [Linq.Expressions.Expression]::Empty()
        )

        return [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                $condExpr,
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)
            ),
            $breakLabel,
            $continueLabel
        )
    }

    # 7. Throw statement: throw <expr>
    if ($Statement -is [System.Management.Automation.Language.ThrowStatementAst]) {
        if ($Statement.Pipeline) {
            $exExpr = Convert-AstExpression -Node $Statement.Pipeline -Scope $Scope
            return [Linq.Expressions.Expression]::Throw($exExpr, [void])
        } else {
            return [Linq.Expressions.Expression]::Rethrow([void])
        }
    }

    # 8. Try / Catch / Finally statement
    if ($Statement -is [System.Management.Automation.Language.TryStatementAst]) {
        $tryBody = Convert-AstStatement -Statement $Statement.Body -Scope $Scope

        $catchBlocks = [System.Collections.Generic.List[Linq.Expressions.CatchBlock]]::new()
        if ($Statement.CatchClauses) {
            foreach ($cc in $Statement.CatchClauses) {
                $catchType = [System.Exception]
                if ($cc.CatchTypes -and $cc.CatchTypes.Count -gt 0) {
                    $catchType = Resolve-AstType $cc.CatchTypes[0].TypeName
                }
                $catchBody = Convert-AstStatement -Statement $cc.Body -Scope $Scope
                $catchBlocks.Add([Linq.Expressions.Expression]::Catch($catchType, $catchBody))
            }
        }

        $finallyBody = if ($Statement.Finally) {
            Convert-AstStatement -Statement $Statement.Finally -Scope $Scope
        } else {
            $null
        }

        if ($finallyBody) {
            return [Linq.Expressions.Expression]::TryCatchFinally(
                $tryBody,
                $finallyBody,
                [Linq.Expressions.CatchBlock[]]$catchBlocks.ToArray()
            )
        }
        else {
            return [Linq.Expressions.Expression]::TryCatch(
                $tryBody,
                [Linq.Expressions.CatchBlock[]]$catchBlocks.ToArray()
            )
        }
    }

    # 9. Pipeline statement (single expression evaluated as statement)
    if ($Statement -is [System.Management.Automation.Language.PipelineAst]) {
        return Convert-AstExpression -Node $Statement -Scope $Scope
    }

    # 10. foreach ($item in $array) { ... } over a typed one-dimensional array,
    # lowered as an indexed loop. As in PowerShell, a $null array iterates zero
    # times, and the loop variable keeps its last value afterwards.
    if ($Statement -is [System.Management.Automation.Language.ForEachStatementAst]) {
        if ($Statement.Flags -ne [System.Management.Automation.Language.ForEachFlags]::None) {
            throw "[{0}:{1}] foreach -parallel is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber
        }
        $collection = Convert-AstExpression -Node $Statement.Condition -Scope $Scope
        if (-not $collection.Type.IsArray -or $collection.Type.GetArrayRank() -ne 1) {
            throw "[{0}:{1}] foreach requires a typed one-dimensional array, got '{2}'." -f `
                $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $collection.Type.FullName
        }
        $elementType = $collection.Type.GetElementType()
        $varName = $Statement.Variable.VariablePath.UserPath
        $item = if ($Scope.Parameters.ContainsKey($varName)) { $Scope.Parameters[$varName] }
                elseif ($Scope.Locals.ContainsKey($varName)) { $Scope.Locals[$varName] }
                else {
                    $declared = [Linq.Expressions.Expression]::Variable($elementType, $varName)
                    $Scope.Locals[$varName] = $declared
                    $Scope.DeclaredLocals.Add($declared)
                    $declared
                }
        $id = $Scope.DeclaredLocals.Count
        $array = [Linq.Expressions.Expression]::Variable($collection.Type, "foreachArray$id")
        $index = [Linq.Expressions.Expression]::Variable([int], "foreachIndex$id")
        $Scope.DeclaredLocals.Add($array)
        $Scope.DeclaredLocals.Add($index)
        $breakLabel = [Linq.Expressions.Expression]::Label("foreachBreak$id")
        $continueLabel = [Linq.Expressions.Expression]::Label("foreachContinue$id")

        $Scope.Loops.Push(@{ Break = $breakLabel; Continue = $continueLabel })
        try { $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope }
        finally { $null = $Scope.Loops.Pop() }

        $current = (ConvertTo-PowerShellType -Expression ([Linq.Expressions.Expression]::ArrayIndex($array, $index)) -Type $item.Type)
        $loopBody = [Linq.Expressions.Expression]::Block(
            [Linq.Expressions.Expression]::Assign($item, $current),
            $bodyExpr,
            [Linq.Expressions.Expression]::Label($continueLabel),
            [Linq.Expressions.Expression]::Assign($index, [Linq.Expressions.Expression]::Add($index, [Linq.Expressions.Expression]::Constant(1))),
            [Linq.Expressions.Expression]::Empty())
        $loop = [Linq.Expressions.Expression]::Loop(
            [Linq.Expressions.Expression]::IfThenElse(
                [Linq.Expressions.Expression]::LessThan($index, [Linq.Expressions.Expression]::ArrayLength($array)),
                $loopBody,
                [Linq.Expressions.Expression]::Break($breakLabel)),
            $breakLabel)
        return [Linq.Expressions.Expression]::Block(
            [Linq.Expressions.Expression]::Assign($array, $collection),
            [Linq.Expressions.Expression]::Assign($index, [Linq.Expressions.Expression]::Constant(0)),
            [Linq.Expressions.Expression]::IfThen(
                [Linq.Expressions.Expression]::NotEqual($array, [Linq.Expressions.Expression]::Constant($null, $collection.Type)),
                $loop),
            [Linq.Expressions.Expression]::Empty())
    }

    # 11. break and continue leave or restart the innermost loop.
    if ($Statement -is [System.Management.Automation.Language.BreakStatementAst] -or
        $Statement -is [System.Management.Automation.Language.ContinueStatementAst]) {
        $keyword = if ($Statement -is [System.Management.Automation.Language.BreakStatementAst]) { 'break' } else { 'continue' }
        if ($Statement.Label) {
            throw "[{0}:{1}] Labeled {2} is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keyword
        }
        if ($Scope.Loops.Count -eq 0) {
            throw "[{0}:{1}] {2} outside a loop is not supported." -f $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $keyword
        }
        $loopLabels = $Scope.Loops.Peek()
        if ($keyword -eq 'break') { return [Linq.Expressions.Expression]::Break($loopLabels.Break) }
        return [Linq.Expressions.Expression]::Continue($loopLabels.Continue)
    }

    throw "[{0}:{1}] Unsupported AST statement '{2}' ({3})." -f `
        $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Extent.Text, $Statement.GetType().Name
}

function Convert-MethodAstToLambda {
    <#
    .SYNOPSIS
        Lowers a method or constructor of a PowerShell class into a LambdaExpression.
    .DESCRIPTION
        Types are resolved against the mirror of every class in the method's
        source, so the method may use those classes and their members. An
        instance method or constructor takes the instance as its first lambda
        parameter, named 'this', which the emitter maps to argument 0. A
        constructor first runs -Initializers, the instance properties' initial
        values, as PowerShell does before the constructor body.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst] $MethodAst,

        [Parameter()]
        [System.Management.Automation.Language.PropertyMemberAst[]] $Initializers = @()
    )

    Use-ClassMirror -Ast $MethodAst
    Test-AstAdmitted -Ast $MethodAst

    $classType = $script:LoweringClassTypes[$MethodAst.Parent.Name]
    $retType = if ($MethodAst.IsConstructor) { [void] }
               elseif ($MethodAst.ReturnType) { Resolve-AstType $MethodAst.ReturnType.TypeName }
               else { [void] }

    $paramExprList = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    $paramMap = @{}
    foreach ($p in $MethodAst.Parameters) {
        $tc = $p.Attributes | Where-Object { $_ -is [System.Management.Automation.Language.TypeConstraintAst] } | Select-Object -First 1
        $pType = if ($tc) { Resolve-AstType $tc.TypeName } else { [object] }
        $pName = $p.Name.VariablePath.UserPath
        $pExpr = [Linq.Expressions.Expression]::Parameter($pType, $pName)
        $paramExprList.Add($pExpr)
        $paramMap[$pName] = $pExpr
    }

    $native = Get-NativeMethodContract $MethodAst
    if ($native -and $native.Kind -eq 'Calli') {
        if ($Mode -eq 'Expression') { throw ('[{0}:{1}] Native indirect-call stubs require Compile mode.' -f $MethodAst.Extent.StartLineNumber,$MethodAst.Extent.StartColumnNumber) }
        $method = $classType.GetMethod($MethodAst.Name,[Type[]]$native.ParameterTypes)
        $call = [Linq.Expressions.Expression]::Call($method,[Linq.Expressions.Expression[]]$paramExprList.ToArray())
        $script:NativeExpressions.Add($call,$native)
        return [pscustomobject]@{Name=$MethodAst.Name; Lambda=[Linq.Expressions.Expression]::Lambda($call,$paramExprList.ToArray()); IsStatic=$true; HasThis=$false; ReturnType=$retType; ParameterTypes=$native.ParameterTypes}
    }

    $thisParam = if ($MethodAst.IsStatic) { $null } else { [Linq.Expressions.Expression]::Parameter($classType, 'this') }
    New-LoweredBody -Name $MethodAst.Name -ReturnType $retType -This $thisParam -Parameters $paramExprList -ParameterMap $paramMap `
        -Initializers $Initializers -Statements @($(if ($MethodAst.Body -and $MethodAst.Body.EndBlock) { $MethodAst.Body.EndBlock.Statements })) `
        -IsStatic ([bool]$MethodAst.IsStatic) -IsConstructor ([bool]$MethodAst.IsConstructor)
}

function Convert-InitializersToLambda {
    <#
    .SYNOPSIS
        Lowers property initial values on their own: the static initializer
        (-Static) or the implicit constructor of a class that declares none.
    #>
    param(
        [Parameter(Mandatory)][System.Management.Automation.Language.TypeDefinitionAst] $ClassAst,
        [Parameter()][System.Management.Automation.Language.PropertyMemberAst[]] $Initializers = @(),
        [switch] $Static
    )
    Use-ClassMirror -Ast $ClassAst
    $classType = $script:LoweringClassTypes[$ClassAst.Name]
    $thisParam = if ($Static) { $null } else { [Linq.Expressions.Expression]::Parameter($classType, 'this') }
    New-LoweredBody -Name $(if ($Static) { '.cctor' } else { '.ctor' }) -ReturnType ([void]) -This $thisParam `
        -Parameters ([System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()) -ParameterMap @{} `
        -Initializers $Initializers -Statements @() -IsStatic ([bool]$Static) -IsConstructor $true
}

function New-LoweredBody {
    param(
        [string] $Name, [Type] $ReturnType, $This,
        [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]] $Parameters, [hashtable] $ParameterMap,
        [System.Management.Automation.Language.PropertyMemberAst[]] $Initializers, [object[]] $Statements,
        [bool] $IsStatic, [bool] $IsConstructor
    )

    $returnTarget = [Linq.Expressions.Expression]::Label($ReturnType, 'returnTarget')
    $declaredLocals = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    $scope = @{
        ReturnType     = $ReturnType
        ReturnTarget   = $returnTarget
        Parameters     = $ParameterMap
        Locals         = @{}
        DeclaredLocals = $declaredLocals
        Loops          = [System.Collections.Generic.Stack[object]]::new()
        This           = $This
    }

    $body = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()
    foreach ($p in $Initializers) {
        if (-not $p.InitialValue) { continue }
        $classType = $script:LoweringClassTypes[$p.Parent.Name]
        $field = $classType.GetField($p.Name, [Reflection.BindingFlags]'Public,Static,Instance')
        $value = Convert-AstExpressionAs -Node $p.InitialValue -Type $field.FieldType -Scope $scope
        $target = if ($field.IsStatic) { $null } else { $This }
        $body.Add([Linq.Expressions.Expression]::Assign([Linq.Expressions.Expression]::Field($target, $field), $value))
    }
    foreach ($stmt in $Statements) {
        if ($null -eq $stmt) { continue }
        # The parser opens every constructor with an implicit base() call; the
        # emitter calls System.Object's constructor, the only base supported.
        if ($stmt -is [System.Management.Automation.Language.CommandExpressionAst] -and
            $stmt.Expression -is [System.Management.Automation.Language.BaseCtorInvokeMemberExpressionAst]) {
            if ($stmt.Expression.Arguments -and @($stmt.Expression.Arguments).Count) {
                throw "[{0}:{1}] A base constructor call with arguments is not supported." -f $stmt.Extent.StartLineNumber, $stmt.Extent.StartColumnNumber
            }
            continue
        }
        $body.Add((Convert-AstStatement -Statement $stmt -Scope $scope))
    }
    $defaultVal = if ($ReturnType -eq [void]) { [Linq.Expressions.Expression]::Empty() } else { [Linq.Expressions.Expression]::Default($ReturnType) }
    $body.Add([Linq.Expressions.Expression]::Label($returnTarget, $defaultVal))

    $bodyBlock = [Linq.Expressions.Expression]::Block($ReturnType,
        [Linq.Expressions.ParameterExpression[]]$declaredLocals.ToArray(),
        [Linq.Expressions.Expression[]]$body.ToArray())
    $lambdaParameters = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()
    if ($This) { $lambdaParameters.Add($This) }
    foreach ($p in $Parameters) { $lambdaParameters.Add($p) }
    $lambda = [Linq.Expressions.Expression]::Lambda($bodyBlock, $Name, [Linq.Expressions.ParameterExpression[]]$lambdaParameters.ToArray())

    [pscustomobject]@{
        Name           = $Name
        IsStatic       = $IsStatic
        IsConstructor  = $IsConstructor
        HasThis        = [bool]$This
        ReturnType     = $ReturnType
        ParameterTypes = [Type[]]@($Parameters | ForEach-Object { $_.Type })
        ParameterNames = [string[]]@($Parameters | ForEach-Object { $_.Name })
        Lambda         = $lambda
    }
}

function Set-DeterministicMvid {
    <#
    .SYNOPSIS
        Applies a deterministic Module Version ID (MVID) and zeroes PE timestamp.
    .DESCRIPTION
        Clears the PE header TimeDateStamp, locates the MVID in the metadata heap,
        computes SHA-256 over the blanked assembly bytes, formats the first 16 bytes
        as an RFC 4122 v4 variant 1 GUID, and writes it back into the binary.
    #>
    param(
        [Parameter(Mandatory)]
        [byte[]] $Assembly
    )

    if ($Assembly.Length -lt 0x40) {
        throw 'The byte array is too short to be a valid PE file.'
    }

    # COFF header: e_lfanew at 0x3C, then PE signature 'PE\0\0' (0x00004550),
    # then Machine (2 bytes), NumberOfSections (2 bytes), TimeDateStamp (4 bytes).
    $peOffset = [BitConverter]::ToInt32($Assembly, 0x3C)
    if ($peOffset -lt 0 -or $peOffset -ge ($Assembly.Length - 12)) {
        throw 'Invalid e_lfanew PE header offset.'
    }

    if ([BitConverter]::ToUInt32($Assembly, $peOffset) -ne 0x00004550) {
        throw 'The assembly does not carry a valid PE signature where its DOS header points.'
    }

    $timestampOffset = $peOffset + 8
    $result = [byte[]]$Assembly.Clone()
    for ($i = 0; $i -lt 4; $i++) {
        $result[$timestampOffset + $i] = 0
    }

    $stream = [System.IO.MemoryStream]::new($result, $false)
    $peReader = [System.Reflection.PortableExecutable.PEReader]::new($stream)
    try {
        $reader = [System.Reflection.Metadata.PEReaderExtensions]::GetMetadataReader($peReader)
        $current = $reader.GetGuid($reader.GetModuleDefinition().Mvid).ToByteArray()
    }
    finally {
        $peReader.Dispose()
        $stream.Dispose()
    }

    # Locate the exact 16-byte MVID occurrence in the binary
    $matches = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -le ($result.Length - 16); $i++) {
        if ($result[$i] -ne $current[0]) { continue }
        $same = $true
        for ($j = 1; $j -lt 16; $j++) {
            if ($result[$i + $j] -ne $current[$j]) {
                $same = $false
                break
            }
        }
        if ($same) {
            $matches.Add($i)
        }
    }

    if ($matches.Count -ne 1) {
        throw "The module version id appears $($matches.Count) times in the assembly; exactly one occurrence is required."
    }
    $offset = $matches[0]

    # Blank the 16 MVID bytes for hashing
    $blanked = [byte[]]$result.Clone()
    for ($j = 0; $j -lt 16; $j++) {
        $blanked[$offset + $j] = 0
    }

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha256.ComputeHash($blanked)
    }
    finally {
        $sha256.Dispose()
    }

    $mvid = [byte[]]::new(16)
    [System.Array]::Copy($digest, 0, $mvid, 0, 16)
    # Format as RFC 4122 v4 variant 1 GUID
    $mvid[7] = [byte](($mvid[7] -band 0x0F) -bor 0x40)
    $mvid[8] = [byte](($mvid[8] -band 0x3F) -bor 0x80)

    [System.Array]::Copy($mvid, 0, $result, $offset, 16)
    return ,$result
}

function New-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Creates a new PersistedAssemblyBuilder session.
    #>
    param(
        [Parameter(Mandatory)][string] $AssemblyName,
        [Parameter()][Reflection.Assembly] $CoreAssembly = [object].Assembly
    )

    $an = [Reflection.AssemblyName]::new($AssemblyName)
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new($an, $CoreAssembly)
    $module = $builder.DefineDynamicModule("$AssemblyName.dll")

    [pscustomobject]@{
        AssemblyName = $AssemblyName
        Builder      = $builder
        Module       = $module
        Types        = [System.Collections.Generic.Dictionary[string, Reflection.Emit.TypeBuilder]]::new()
    }
}

function Save-PersistedAssemblySession {
    <#
    .SYNOPSIS
        Saves the PersistedAssemblyBuilder session to the specified output path.
    .DESCRIPTION
        Creates types, serializes to a MemoryStream, applies deterministic MVID
        if requested, and writes atomically to disk using a temporary file.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject] $Session,

        [Parameter(Mandatory)]
        [string] $OutputPath,

        [switch] $Deterministic = $true,

        # A static method to mark as the entry point. The image is then an
        # executable rather than a library; without it the bytes are exactly
        # what PersistedAssemblyBuilder.Save writes.
        [Parameter()][Reflection.Emit.MethodBuilder] $EntryPoint
    )

    $fullOut = if ([IO.Path]::IsPathFullyQualified($OutputPath)) {
        [IO.Path]::GetFullPath($OutputPath)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path (Get-Location) $OutputPath))
    }

    $outDir = [IO.Path]::GetDirectoryName($fullOut)
    if ($outDir -and -not [IO.Directory]::Exists($outDir)) {
        [IO.Directory]::CreateDirectory($outDir) | Out-Null
    }

    # Ensure all defined types are created
    foreach ($tb in $Session.Types.Values) {
        if (-not $tb.IsCreated()) {
            $null = $tb.CreateType()
        }
    }

    if ($EntryPoint) {
        # PersistedAssemblyBuilder.Save always writes a library with no entry
        # point (WritePEImage, runtime ab194157). An executable is the same
        # metadata serialized by ManagedPEBuilder with an executable header
        # and the entry method's handle, which exists once metadata is built.
        $ilStream = $null
        $fieldData = $null
        $metadata = $Session.Builder.GenerateMetadata([ref]$ilStream, [ref]$fieldData)
        if ($EntryPoint.MetadataToken -eq 0) {
            throw "Entry point '$($EntryPoint.Name)' has no metadata token after metadata generation."
        }
        $entryHandle = [Reflection.Metadata.Ecma335.MetadataTokens]::MethodDefinitionHandle($EntryPoint.MetadataToken -band 0x00FFFFFF)
        $peBuilder = [Reflection.PortableExecutable.ManagedPEBuilder]::new(
            [Reflection.PortableExecutable.PEHeaderBuilder]::CreateExecutableHeader(),
            [Reflection.Metadata.Ecma335.MetadataRootBuilder]::new($metadata),
            $ilStream, $fieldData, $null, $null, $null, 0, $entryHandle)
        $peBlob = [Reflection.Metadata.BlobBuilder]::new()
        $null = $peBuilder.Serialize($peBlob)
        $bytes = $peBlob.ToArray()
    }
    else {
        $ms = [IO.MemoryStream]::new()
        try {
            $Session.Builder.Save($ms)
            $bytes = $ms.ToArray()
        }
        finally {
            $ms.Dispose()
        }
    }

    if ($Deterministic) {
        $bytes = Set-DeterministicMvid -Assembly $bytes
    }

    # Atomic file write to avoid partial artifacts on failure
    $tempFile = [IO.Path]::Combine($outDir, [IO.Path]::GetRandomFileName() + '.tmp')
    try {
        [IO.File]::WriteAllBytes($tempFile, $bytes)
        [IO.File]::Move($tempFile, $fullOut, $true)
    }
    finally {
        if ([IO.File]::Exists($tempFile)) {
            [IO.File]::Delete($tempFile)
        }
    }

    # An executable runs on the shared framework it was compiled against: the
    # runtime configuration names that framework and its exact version.
    $runtimeConfigPath = $null
    if ($EntryPoint) {
        $runtimeVersion = ([object].Assembly.GetCustomAttributes([Reflection.AssemblyInformationalVersionAttribute], $false)[0].InformationalVersion -split '\+')[0]
        $runtimeConfigPath = [IO.Path]::ChangeExtension($fullOut, '.runtimeconfig.json')
        $runtimeConfig = [ordered]@{
            runtimeOptions = [ordered]@{
                tfm       = "net$([Environment]::Version.Major).$([Environment]::Version.Minor)"
                framework = [ordered]@{ name = 'Microsoft.NETCore.App'; version = $runtimeVersion }
            }
        }
        [IO.File]::WriteAllText($runtimeConfigPath, ($runtimeConfig | ConvertTo-Json -Depth 4))
    }

    $sha256 = [Security.Cryptography.SHA256]::HashData($bytes)
    $hexHash = [BitConverter]::ToString($sha256).Replace('-', '')

    [pscustomobject]@{
        OutputPath   = $fullOut
        Length       = $bytes.Length
        SHA256       = $hexHash
        Deterministic = [bool]$Deterministic
        EntryPoint    = if ($EntryPoint) { $EntryPoint.Name } else { $null }
        RuntimeConfig = $runtimeConfigPath
    }
}

# Mirror member -> output member for the classes being compiled together, set
# by Export-LoweredAssembly for one compilation. Empty: operands pass through.
$script:IlMap = @{ Types = @{}; Members = @{} }

function Get-IlType([Type] $Type) {
    if ($null -eq $Type) { return $null }
    if ($script:IlMap.Types.ContainsKey($Type)) { return $script:IlMap.Types[$Type] }
    if ($Type.IsArray) {
        $element = Get-IlType $Type.GetElementType()
        if ($element -ne $Type.GetElementType()) { return $(if ($Type.GetArrayRank() -eq 1) { $element.MakeArrayType() } else { $element.MakeArrayType($Type.GetArrayRank()) }) }
        return $Type
    }
    if ($Type.IsConstructedGenericType) {
        $arguments = [Type[]]@($Type.GetGenericArguments() | ForEach-Object { Get-IlType $_ })
        $changed = $false
        $original = $Type.GetGenericArguments()
        for ($i = 0; $i -lt $arguments.Length; $i++) { if ($arguments[$i] -ne $original[$i]) { $changed = $true } }
        if ($changed) { return $Type.GetGenericTypeDefinition().MakeGenericType($arguments) }
    }
    if ($Type.Assembly.GetName().Name -like 'PSLoweringMirror*') { throw "Type '$($Type.Name)' has no compiled counterpart." }
    $Type
}

function Get-IlMember([Reflection.MemberInfo] $Member) {
    if ($script:IlMap.Members.ContainsKey($Member)) { return $script:IlMap.Members[$Member] }
    if ($Member.DeclaringType -and $Member.DeclaringType.Assembly.GetName().Name -like 'PSLoweringMirror*') {
        throw "'$($Member.DeclaringType.Name).$($Member.Name)' is used but not compiled; was it left out with -MethodNames?"
    }
    $declaring = $Member.DeclaringType
    if ($declaring -and $declaring.IsConstructedGenericType) {
        $mapped = Get-IlType $declaring
        if ($mapped -ne $declaring) {
            if ($Member -is [Reflection.MethodInfo] -and $Member.IsGenericMethod) {
                throw "Generic method '$($Member.Name)' on '$($declaring.Name)' over a compiled class is not supported."
            }
            # A member of a constructed type shares its definition's metadata token.
            $definition = $declaring.GetGenericTypeDefinition().GetMembers([Reflection.BindingFlags]'Public,NonPublic,Instance,Static') |
                Where-Object { $_.MetadataToken -eq $Member.MetadataToken -and $_.Module -eq $Member.Module } | Select-Object -First 1
            if (-not $definition) { throw "No definition found for '$($Member.Name)' on '$($declaring.Name)'." }
            if ($Member -is [Reflection.ConstructorInfo]) { return [Reflection.Emit.TypeBuilder]::GetConstructor($mapped, $definition) }
            if ($Member -is [Reflection.MethodInfo]) { return [Reflection.Emit.TypeBuilder]::GetMethod($mapped, $definition) }
            if ($Member -is [Reflection.FieldInfo]) { return [Reflection.Emit.TypeBuilder]::GetField($mapped, $definition) }
        }
    }
    $Member
}

function Write-IlArgumentLoad([Reflection.Emit.ILGenerator]$IL, [int]$Index) {
    switch ($Index) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_3); return }
    }
    if ($Index -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldarg_S, [byte]$Index)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldarg, [int16]$Index)
    }
}

function Write-IlArgumentStore([Reflection.Emit.ILGenerator]$IL, [int]$Index) {
    if ($Index -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Starg_S, [byte]$Index)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Starg, [int16]$Index)
    }
}

function Write-IlLocalLoad([Reflection.Emit.ILGenerator]$IL, [Reflection.Emit.LocalBuilder]$Loc) {
    $idx = $Loc.LocalIndex
    switch ($idx) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_3); return }
    }
    if ($idx -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldloc_S, $Loc)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldloc, $Loc)
    }
}

function Write-IlLocalStore([Reflection.Emit.ILGenerator]$IL, [Reflection.Emit.LocalBuilder]$Loc) {
    $idx = $Loc.LocalIndex
    switch ($idx) {
        0 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_0); return }
        1 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_1); return }
        2 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_2); return }
        3 { $IL.Emit([Reflection.Emit.OpCodes]::Stloc_3); return }
    }
    if ($idx -le 255) {
        $IL.Emit([Reflection.Emit.OpCodes]::Stloc_S, $Loc)
    } else {
        $IL.Emit([Reflection.Emit.OpCodes]::Stloc, $Loc)
    }
}

function Write-IlArrayLoad([Reflection.Emit.ILGenerator]$IL, [Type]$ElementType) {
    if ($ElementType -eq [int]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I4); return }
    if ($ElementType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_R4); return }
    if ($ElementType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_R8); return }
    if ($ElementType -eq [byte]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_U1); return }
    if ($ElementType -eq [sbyte]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I1); return }
    if ($ElementType -eq [short]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I2); return }
    if ($ElementType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_U2); return }
    if ($ElementType -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I8); return }
    if ($ElementType -eq [bool]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_I1); return }
    if (-not $ElementType.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Ldelem_Ref); return }
    $IL.Emit([Reflection.Emit.OpCodes]::Ldelem, (Get-IlType $ElementType))
}

function Write-IlArrayStore([Reflection.Emit.ILGenerator]$IL, [Type]$ElementType) {
    if ($ElementType -eq [int]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I4); return }
    if ($ElementType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_R4); return }
    if ($ElementType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_R8); return }
    if ($ElementType -eq [byte]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if ($ElementType -eq [sbyte]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if ($ElementType -eq [short]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I2); return }
    if ($ElementType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I2); return }
    if ($ElementType -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I8); return }
    if ($ElementType -eq [bool]) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_I1); return }
    if (-not $ElementType.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Stelem_Ref); return }
    $IL.Emit([Reflection.Emit.OpCodes]::Stelem, (Get-IlType $ElementType))
}

function Write-IlConstant {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.ConstantExpression] $Expr
    )

    $val = $Expr.Value
    if ($null -eq $val) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldnull)
        return
    }

    if ($val -is [Type] -and $val -eq [Threading.ThreadStart]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldtoken,$val)
        $IL.Emit([Reflection.Emit.OpCodes]::Call,[Type].GetMethod('GetTypeFromHandle',[Type[]]@([RuntimeTypeHandle])))
        return
    }
    if ($val -is [int]) {
        switch ($val) {
            -1 { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_M1); return }
            0  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); return }
            1  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1); return }
            2  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_2); return }
            3  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_3); return }
            4  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_4); return }
            5  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_5); return }
            6  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_6); return }
            7  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_7); return }
            8  { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_8); return }
        }
        if ($val -ge -128 -and $val -le 127) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_S, [sbyte]$val)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4, [int]$val)
        }
        return
    }

    if ($val -is [enum]) {
        $underlying = [Enum]::GetUnderlyingType($val.GetType())
        Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant([Convert]::ChangeType($val, $underlying), $underlying))
        return
    }

    if ($val -is [bool]) {
        if ($val) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
        }
        return
    }

    if ($val -is [string]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldstr, [string]$val)
        return
    }

    if ($val -is [double]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R8, [double]$val)
        return
    }

    if ($val -is [single]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R4, [single]$val)
        return
    }

    if ($val -is [long]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]$val)
        return
    }

    throw "Unsupported constant type '$($val.GetType().FullName)'."
}

function Write-IlConversion {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Type] $FromType,
        [Parameter(Mandatory)][Type] $ToType,
        [switch] $Checked
    )

    if ($FromType -eq $ToType) { return }

    # Boxing and unboxing come first: a numeric opcode applied to a reference
    # converts the reference's bits, not the value it holds.
    if ($FromType.IsValueType -and -not $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Box, (Get-IlType $FromType))
        if ($ToType -ne [object]) { $IL.Emit([Reflection.Emit.OpCodes]::Castclass, (Get-IlType $ToType)) }
        return
    }
    if (-not $FromType.IsValueType -and $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Unbox_Any, (Get-IlType $ToType))
        return
    }
    if (-not $FromType.IsValueType -and -not $ToType.IsValueType) {
        $IL.Emit([Reflection.Emit.OpCodes]::Castclass, (Get-IlType $ToType))
        return
    }
    $numeric = { param([Type] $T) $T.IsPrimitive -or $T.IsEnum }
    if (-not (& $numeric $FromType) -or -not (& $numeric $ToType)) {
        throw "Unsupported conversion from '$($FromType.FullName)' to '$($ToType.FullName)'."
    }

    if ($Checked -and $ToType.IsPrimitive -and $ToType -notin [double], [single], [bool], [char]) {
        $un = if ($FromType -in [byte], [ushort], [uint], [ulong]) { '_Un' } else { '' }
        $suffix = @{ [int] = 'I4'; [long] = 'I8'; [short] = 'I2'; [sbyte] = 'I1'; [byte] = 'U1'; [ushort] = 'U2'; [uint] = 'U4'; [ulong] = 'U8' }[$ToType]
        if ($suffix) {
            $IL.Emit([Reflection.Emit.OpCodes].GetField("Conv_Ovf_$suffix$un").GetValue($null))
            return
        }
    }
    if ($ToType -in [double], [single] -and $FromType -in [uint], [ulong]) {
        $IL.Emit([Reflection.Emit.OpCodes]::Conv_R_Un)
    }

    if ($ToType -eq [int])    { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I4); return }
    if ($ToType -eq [long])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I8); return }
    if ($ToType -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_R8); return }
    if ($ToType -eq [single]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_R4); return }
    if ($ToType -eq [short])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I2); return }
    if ($ToType -eq [byte])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U1); return }
    if ($ToType -eq [sbyte])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_I1); return }
    if ($ToType -eq [uint])   { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U4); return }
    if ($ToType -eq [ulong])  { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U8); return }
    if ($ToType -eq [ushort]) { $IL.Emit([Reflection.Emit.OpCodes]::Conv_U2); return }

    throw "Unsupported conversion from '$($FromType.FullName)' to '$($ToType.FullName)'."
}

function Write-IlExpression {
    param(
        [Parameter(Mandatory)][Reflection.Emit.ILGenerator] $IL,
        [Parameter(Mandatory)][Linq.Expressions.Expression] $Expr,
        [Parameter(Mandatory)][hashtable] $Context
    )

    $native = $null
    if ($script:NativeExpressions.TryGetValue($Expr,[ref]$native)) {
        if ($native.Kind -eq 'Address') {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldftn,(Get-IlMember $native.Method))
            return
        }
        # Reject null before entering native code. These are typed parameters,
        # so loading the pointer twice has no observable side effects.
        $valid=$IL.DefineLabel()
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Brtrue,$valid)
        $IL.Emit([Reflection.Emit.OpCodes]::Ldstr,'functionPointer')
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj,[ArgumentNullException].GetConstructor([Type[]]@([string])))
        $IL.Emit([Reflection.Emit.OpCodes]::Throw)
        $IL.MarkLabel($valid)
        for ($i=1;$i -lt $Expr.Arguments.Count;$i++) { Write-IlExpression -IL $IL -Expr $Expr.Arguments[$i] -Context $Context }
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        $signature=[Type[]]@($native.ParameterTypes | Select-Object -Skip 1)
        $IL.EmitCalli([Reflection.Emit.OpCodes]::Calli,[Runtime.InteropServices.CallingConvention]$native.Convention,[Type]$native.ReturnType,$signature)
        return
    }

    # 1. Constant
    if ($Expr -is [Linq.Expressions.ConstantExpression]) {
        Write-IlConstant -IL $IL -Expr $Expr
        return
    }

    # 2. Parameter / Local read
    if ($Expr -is [Linq.Expressions.ParameterExpression]) {
        if ($Context.Locals.ContainsKey($Expr)) {
            Write-IlLocalLoad -IL $IL -Loc $Context.Locals[$Expr]
            return
        }
        if ($Context.Parameters.ContainsKey($Expr)) {
            Write-IlArgumentLoad -IL $IL -Index $Context.Parameters[$Expr]
            return
        }
        throw "Variable '$($Expr.Name)' was neither in parameters nor locals."
    }

    # 3. Block
    if ($Expr -is [Linq.Expressions.BlockExpression]) {
        # Declare local variables
        foreach ($var in $Expr.Variables) {
            if (-not $Context.Locals.ContainsKey($var)) {
                $loc = $IL.DeclareLocal((Get-IlType $var.Type))
                $Context.Locals[$var] = $loc
            }
        }

        $count = $Expr.Expressions.Count
        for ($i = 0; $i -lt $count; $i++) {
            $child = $Expr.Expressions[$i]
            $isLast = ($i -eq ($count - 1))
            Write-IlExpression -IL $IL -Expr $child -Context $Context

            # If not the last expression and pushes value onto stack, pop it
            if (-not $isLast -and $child.Type -ne [void] -and $child.NodeType -ne [Linq.Expressions.ExpressionType]::Assign) {
                $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            }
        }
        return
    }

    # 4. Goto / Return
    if ($Expr -is [Linq.Expressions.GotoExpression]) {
        if ($Expr.Value) {
            Write-IlExpression -IL $IL -Expr $Expr.Value -Context $Context
            if ($Context.ReturnLocal -and $Expr.Target.Name -eq 'returnTarget') {
                Write-IlLocalStore -IL $IL -Loc $Context.ReturnLocal
            }
        }

        $target = $Expr.Target
        if (-not $Context.Labels.ContainsKey($target)) {
            $Context.Labels[$target] = $IL.DefineLabel()
        }
        $label = $Context.Labels[$target]
        if ($Context.ExceptionDepth -gt 0) {
            $IL.Emit([Reflection.Emit.OpCodes]::Leave, $label)
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Br, $label)
        }
        return
    }

    # 5. Label
    if ($Expr -is [Linq.Expressions.LabelExpression]) {
        $target = $Expr.Target
        if (-not $Context.Labels.ContainsKey($target)) {
            $Context.Labels[$target] = $IL.DefineLabel()
        }
        $label = $Context.Labels[$target]
        $IL.MarkLabel($label)

        if ($Expr.Target.Name -eq 'returnTarget') {
            if ($Context.ReturnLocal) {
                Write-IlLocalLoad -IL $IL -Loc $Context.ReturnLocal
            }
            return
        }

        if ($Expr.DefaultValue) {
            Write-IlExpression -IL $IL -Expr $Expr.DefaultValue -Context $Context
        }
        return
    }

    # 6. Default / Empty
    if ($Expr -is [Linq.Expressions.DefaultExpression]) {
        if ($Expr.Type -eq [void]) { return }
        if ($Expr.Type -eq [int] -or $Expr.Type -eq [bool] -or $Expr.Type -eq [short] -or $Expr.Type -eq [byte]) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0); return
        }
        if ($Expr.Type -eq [long]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I8, [long]0); return }
        if ($Expr.Type -eq [double]) { $IL.Emit([Reflection.Emit.OpCodes]::Ldc_R8, [double]0.0); return }
        if (-not $Expr.Type.IsValueType) { $IL.Emit([Reflection.Emit.OpCodes]::Ldnull); return }
        throw "Unsupported default value type '$($Expr.Type.FullName)'."
    }

    # 7. Unary Convert
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -in [Linq.Expressions.ExpressionType]::Convert, [Linq.Expressions.ExpressionType]::ConvertChecked) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        Write-IlConversion -IL $IL -FromType $Expr.Operand.Type -ToType $Expr.Type -Checked:($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ConvertChecked)
        return
    }

    # Checked negation: 0 - x with overflow checking, as CIL has no checked neg.
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NegateChecked) {
        Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant([Convert]::ChangeType(0, $Expr.Type), $Expr.Type))
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Sub_Ovf)
        return
    }

    # 8. Unary Negate
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Negate) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Neg)
        return
    }

    # 9. Unary Not
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Not) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        if ($Expr.Operand.Type -eq [bool]) {
            $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
            $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
        }
        else {
            $IL.Emit([Reflection.Emit.OpCodes]::Not)
        }
        return
    }

    # 9.1 Unary ArrayLength
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ArrayLength) {
        Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Ldlen)
        $IL.Emit([Reflection.Emit.OpCodes]::Conv_I4)
        return
    }

    # 9.15 Unary Throw / Rethrow
    if ($Expr -is [Linq.Expressions.UnaryExpression] -and $Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Throw) {
        if ($Expr.Operand) {
            Write-IlExpression -IL $IL -Expr $Expr.Operand -Context $Context
            $IL.Emit([Reflection.Emit.OpCodes]::Throw)
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Rethrow)
        }
        return
    }

    # 9.2 NewArray (Bounds or Init)
    if ($Expr -is [Linq.Expressions.NewArrayExpression]) {
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NewArrayBounds) {
            Write-IlExpression -IL $IL -Expr $Expr.Expressions[0] -Context $Context
            $IL.Emit([Reflection.Emit.OpCodes]::Newarr, (Get-IlType $Expr.Type.GetElementType()))
            return
        }
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::NewArrayInit) {
            $elemType = $Expr.Type.GetElementType()
            $count = $Expr.Expressions.Count
            Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($count, [int]))
            $IL.Emit([Reflection.Emit.OpCodes]::Newarr, (Get-IlType $elemType))
            for ($i = 0; $i -lt $count; $i++) {
                $IL.Emit([Reflection.Emit.OpCodes]::Dup)
                Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($i, [int]))
                Write-IlExpression -IL $IL -Expr $Expr.Expressions[$i] -Context $Context
                Write-IlArrayStore -IL $IL -ElementType $elemType
            }
            return
        }
    }

    # 9.3 New object instantiation (NewExpression)
    if ($Expr -is [Linq.Expressions.NewExpression]) {
        foreach ($arg in $Expr.Arguments) {
            Write-IlExpression -IL $IL -Expr $arg -Context $Context
        }
        $IL.Emit([Reflection.Emit.OpCodes]::Newobj, (Get-IlMember $Expr.Constructor))
        return
    }

    # 9.4 Method call (MethodCallExpression)
    if ($Expr -is [Linq.Expressions.MethodCallExpression]) {
        if ($Expr.Object) {
            Write-IlExpression -IL $IL -Expr $Expr.Object -Context $Context
        }
        foreach ($arg in $Expr.Arguments) {
            Write-IlExpression -IL $IL -Expr $arg -Context $Context
        }
        if ($Expr.Method.IsVirtual -and -not $Expr.Method.DeclaringType.IsValueType) {
            $IL.Emit([Reflection.Emit.OpCodes]::Callvirt, (Get-IlMember $Expr.Method))
        } else {
            $IL.Emit([Reflection.Emit.OpCodes]::Call, (Get-IlMember $Expr.Method))
        }
        return
    }

    # 9.4 Array element read through an IndexExpression (one-dimensional array)
    if ($Expr -is [Linq.Expressions.IndexExpression] -and $null -eq $Expr.Indexer -and $Expr.Object.Type.IsArray -and $Expr.Arguments.Count -eq 1) {
        Write-IlExpression -IL $IL -Expr $Expr.Object -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Arguments[0] -Context $Context
        Write-IlArrayLoad -IL $IL -ElementType $Expr.Type
        return
    }

    # 9.5 Member access - Property or Field (MemberExpression)
    if ($Expr -is [Linq.Expressions.MemberExpression]) {
        if ($Expr.Member -is [Reflection.PropertyInfo]) {
            $getter = $Expr.Member.GetGetMethod()
            if ($Expr.Expression) {
                Write-IlExpression -IL $IL -Expr $Expr.Expression -Context $Context
            }
            if ($getter.IsVirtual -and -not $getter.DeclaringType.IsValueType) {
                $IL.Emit([Reflection.Emit.OpCodes]::Callvirt, (Get-IlMember $getter))
            } else {
                $IL.Emit([Reflection.Emit.OpCodes]::Call, (Get-IlMember $getter))
            }
            return
        }
        if ($Expr.Member -is [Reflection.FieldInfo]) {
            # A literal (const or enum member) has no storage to load; its
            # value is the constant, as in LambdaCompiler.EmitMemberExpression.
            if ($Expr.Member.IsLiteral) {
                $literalType = if ($Expr.Member.FieldType.IsEnum) { $Expr.Member.FieldType.GetEnumUnderlyingType() } else { $Expr.Member.FieldType }
                Write-IlConstant -IL $IL -Expr ([Linq.Expressions.Expression]::Constant($Expr.Member.GetRawConstantValue(), $literalType))
                return
            }
            if ($Expr.Expression) {
                Write-IlExpression -IL $IL -Expr $Expr.Expression -Context $Context
                $IL.Emit([Reflection.Emit.OpCodes]::Ldfld, (Get-IlMember $Expr.Member))
            } else {
                $IL.Emit([Reflection.Emit.OpCodes]::Ldsfld, (Get-IlMember $Expr.Member))
            }
            return
        }
        throw "Unsupported member access on '$($Expr.Member.GetType().FullName)'."
    }

    # 9.6 Try / Catch / Finally (TryExpression)
    if ($Expr -is [Linq.Expressions.TryExpression]) {
        $lblEnd = $IL.BeginExceptionBlock()
        $Context.ExceptionDepth++

        Write-IlExpression -IL $IL -Expr $Expr.Body -Context $Context

        foreach ($cb in $Expr.Handlers) {
            $IL.BeginCatchBlock((Get-IlType $cb.Test))
            if ($cb.Variable) {
                if (-not $Context.Locals.ContainsKey($cb.Variable)) {
                    $loc = $IL.DeclareLocal((Get-IlType $cb.Variable.Type))
                    $Context.Locals[$cb.Variable] = $loc
                }
                Write-IlLocalStore -IL $IL -Loc $Context.Locals[$cb.Variable]
            } else {
                $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            }
            Write-IlExpression -IL $IL -Expr $cb.Body -Context $Context
        }

        if ($Expr.Finally) {
            $IL.BeginFinallyBlock()
            Write-IlExpression -IL $IL -Expr $Expr.Finally -Context $Context
        }

        $IL.EndExceptionBlock()
        $Context.ExceptionDepth--
        return
    }

    # 10. Conditional Expression (if/else or ternary)
    if ($Expr -is [Linq.Expressions.ConditionalExpression]) {
        Write-IlExpression -IL $IL -Expr $Expr.Test -Context $Context
        $lblFalse = $IL.DefineLabel()
        $lblEnd = $IL.DefineLabel()

        $IL.Emit([Reflection.Emit.OpCodes]::Brfalse, $lblFalse)
        Write-IlExpression -IL $IL -Expr $Expr.IfTrue -Context $Context

        $hasFalseBranch = ($Expr.IfFalse -and $Expr.IfFalse.NodeType -ne [Linq.Expressions.ExpressionType]::Default -and $Expr.IfFalse.Type -ne [void]) -or
                          ($Expr.IfFalse -and $Expr.IfFalse.NodeType -ne [Linq.Expressions.ExpressionType]::Default)

        if ($hasFalseBranch) {
            $IL.Emit([Reflection.Emit.OpCodes]::Br, $lblEnd)
            $IL.MarkLabel($lblFalse)
            Write-IlExpression -IL $IL -Expr $Expr.IfFalse -Context $Context
            $IL.MarkLabel($lblEnd)
        }
        else {
            $IL.MarkLabel($lblFalse)
        }
        return
    }

    # 11. Loop Expression
    if ($Expr -is [Linq.Expressions.LoopExpression]) {
        $lblHead = $IL.DefineLabel()
        $lblBreak = if ($Expr.BreakLabel) {
            if (-not $Context.Labels.ContainsKey($Expr.BreakLabel)) {
                $Context.Labels[$Expr.BreakLabel] = $IL.DefineLabel()
            }
            $Context.Labels[$Expr.BreakLabel]
        } else { $IL.DefineLabel() }

        $lblContinue = if ($Expr.ContinueLabel) {
            if (-not $Context.Labels.ContainsKey($Expr.ContinueLabel)) {
                $Context.Labels[$Expr.ContinueLabel] = $IL.DefineLabel()
            }
            $Context.Labels[$Expr.ContinueLabel]
        } else { $lblHead }

        $IL.MarkLabel($lblHead)
        # The continue label is the loop head, as in LambdaCompiler.EmitLoopExpression.
        if ($Expr.ContinueLabel) { $IL.MarkLabel($lblContinue) }
        Write-IlExpression -IL $IL -Expr $Expr.Body -Context $Context
        $IL.Emit([Reflection.Emit.OpCodes]::Br, $lblHead)
        $IL.MarkLabel($lblBreak)
        return
    }

    # 12. Binary Expressions (Arithmetic, Assignment, Logic, Comparisons, Index)
    if ($Expr -is [Linq.Expressions.BinaryExpression]) {
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::Assign) {
            if ($Expr.Left -is [Linq.Expressions.ParameterExpression]) {
                # Evaluate right hand side
                Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
                if ($Context.Locals.ContainsKey($Expr.Left)) {
                    Write-IlLocalStore -IL $IL -Loc $Context.Locals[$Expr.Left]
                    return
                }
                if ($Context.Parameters.ContainsKey($Expr.Left)) {
                    Write-IlArgumentStore -IL $IL -Index $Context.Parameters[$Expr.Left]
                    return
                }
            }
            if ($Expr.Left -is [Linq.Expressions.IndexExpression]) {
                Write-IlExpression -IL $IL -Expr $Expr.Left.Object -Context $Context
                Write-IlExpression -IL $IL -Expr $Expr.Left.Arguments[0] -Context $Context
                Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
                Write-IlArrayStore -IL $IL -ElementType $Expr.Left.Type
                return
            }
            if ($Expr.Left -is [Linq.Expressions.MemberExpression]) {
                $member = $Expr.Left.Member
                if ($Expr.Left.Expression) { Write-IlExpression -IL $IL -Expr $Expr.Left.Expression -Context $Context }
                Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
                if ($member -is [Reflection.FieldInfo]) {
                    $op = if ($member.IsStatic) { [Reflection.Emit.OpCodes]::Stsfld } else { [Reflection.Emit.OpCodes]::Stfld }
                    $IL.Emit($op, (Get-IlMember $member))
                    return
                }
                $setter = $member.GetSetMethod()
                $op = if ($setter.IsVirtual -and -not $setter.DeclaringType.IsValueType) { [Reflection.Emit.OpCodes]::Callvirt } else { [Reflection.Emit.OpCodes]::Call }
                $IL.Emit($op, (Get-IlMember $setter))
                return
            }
            throw "Assignment to unsupported target expression '$($Expr.Left.GetType().FullName)'."
        }

        # Array Index Read
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::ArrayIndex) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            Write-IlArrayLoad -IL $IL -ElementType $Expr.Type
            return
        }

        # Short-circuit logical AndAlso
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::AndAlso) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            $lbl = $IL.DefineLabel()
            $IL.Emit([Reflection.Emit.OpCodes]::Dup)
            $IL.Emit([Reflection.Emit.OpCodes]::Brfalse, $lbl)
            $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            $IL.MarkLabel($lbl)
            return
        }

        # Short-circuit logical OrElse
        if ($Expr.NodeType -eq [Linq.Expressions.ExpressionType]::OrElse) {
            Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
            $lbl = $IL.DefineLabel()
            $IL.Emit([Reflection.Emit.OpCodes]::Dup)
            $IL.Emit([Reflection.Emit.OpCodes]::Brtrue, $lbl)
            $IL.Emit([Reflection.Emit.OpCodes]::Pop)
            Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context
            $IL.MarkLabel($lbl)
            return
        }

        # Binary operations (Arithmetic and Comparisons)
        Write-IlExpression -IL $IL -Expr $Expr.Left -Context $Context
        Write-IlExpression -IL $IL -Expr $Expr.Right -Context $Context

        if ($Expr.Method) {
            $IL.Emit([Reflection.Emit.OpCodes]::Call, (Get-IlMember $Expr.Method))
            return
        }

        $isFloat = ($Expr.Left.Type -eq [double] -or $Expr.Left.Type -eq [single])
        # Unsigned operands need the _Un forms; for floats, the _Un compare
        # forms are the ones that treat NaN as unordered.
        $isUnsigned = $Expr.Left.Type -in [byte], [ushort], [uint], [ulong]

        switch ($Expr.NodeType) {
            'Add'      { $IL.Emit([Reflection.Emit.OpCodes]::Add); return }
            'Subtract' { $IL.Emit([Reflection.Emit.OpCodes]::Sub); return }
            'Multiply' { $IL.Emit([Reflection.Emit.OpCodes]::Mul); return }
            'AddChecked'      { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Add_Ovf_Un } else { [Reflection.Emit.OpCodes]::Add_Ovf })); return }
            'SubtractChecked' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Sub_Ovf_Un } else { [Reflection.Emit.OpCodes]::Sub_Ovf })); return }
            'MultiplyChecked' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Mul_Ovf_Un } else { [Reflection.Emit.OpCodes]::Mul_Ovf })); return }
            'Divide'   { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Div_Un } else { [Reflection.Emit.OpCodes]::Div })); return }
            'And'         { $IL.Emit([Reflection.Emit.OpCodes]::And); return }
            'Or'          { $IL.Emit([Reflection.Emit.OpCodes]::Or); return }
            'ExclusiveOr' { $IL.Emit([Reflection.Emit.OpCodes]::Xor); return }
            'LeftShift'   { $IL.Emit([Reflection.Emit.OpCodes]::Shl); return }
            'RightShift'  { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Shr_Un } else { [Reflection.Emit.OpCodes]::Shr })); return }
            'Modulo'   { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Rem_Un } else { [Reflection.Emit.OpCodes]::Rem })); return }
            'Equal'    { $IL.Emit([Reflection.Emit.OpCodes]::Ceq); return }
            'NotEqual' {
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
            'LessThan' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Clt_Un } else { [Reflection.Emit.OpCodes]::Clt })); return }
            'GreaterThan' { $IL.Emit($(if ($isUnsigned) { [Reflection.Emit.OpCodes]::Cgt_Un } else { [Reflection.Emit.OpCodes]::Cgt })); return }
            'LessThanOrEqual' {
                if ($isFloat -or $isUnsigned) {
                    $IL.Emit([Reflection.Emit.OpCodes]::Cgt_Un)
                } else {
                    $IL.Emit([Reflection.Emit.OpCodes]::Cgt)
                }
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
            'GreaterThanOrEqual' {
                if ($isFloat -or $isUnsigned) {
                    $IL.Emit([Reflection.Emit.OpCodes]::Clt_Un)
                } else {
                    $IL.Emit([Reflection.Emit.OpCodes]::Clt)
                }
                $IL.Emit([Reflection.Emit.OpCodes]::Ldc_I4_0)
                $IL.Emit([Reflection.Emit.OpCodes]::Ceq)
                return
            }
        }
    }

    throw "Emitter encountered unhandled expression node type '$($Expr.GetType().FullName)' ($($Expr.NodeType))."
}

function Write-IlMethodBody {
    <#
    .SYNOPSIS
        Emits MSIL into a MethodBuilder from a validated LambdaExpression.
    #>
    param(
        [Parameter(Mandatory)][Linq.Expressions.LambdaExpression] $Lambda,
        # A MethodBuilder or ConstructorBuilder.
        [Parameter(Mandatory)][object] $MethodBuilder,
        [switch] $IsStatic,
        # The lambda's first parameter is the instance ('this', argument 0).
        [switch] $HasThis,
        # Call System.Object's constructor first, as an instance constructor must.
        [switch] $BaseConstructor
    )

    $il = $MethodBuilder.GetILGenerator()
    if ($BaseConstructor) {
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([Reflection.Emit.OpCodes]::Call, [object].GetConstructor([Type[]]@()))
    }

    $paramMap = @{}
    $offset = if ($IsStatic -or $HasThis) { 0 } else { 1 }

    for ($i = 0; $i -lt $Lambda.Parameters.Count; $i++) {
        $p = $Lambda.Parameters[$i]
        $paramMap[$p] = ($i + $offset)
    }

    $retLocal = if ($Lambda.ReturnType -ne [void]) {
        $il.DeclareLocal((Get-IlType $Lambda.ReturnType))
    } else {
        $null
    }

    $context = @{
        IsStatic    = [bool]$IsStatic
        Parameters  = $paramMap
        Locals      = @{}
        Labels      = @{}
        ReturnType     = $Lambda.ReturnType
        ReturnLocal    = $retLocal
        ExceptionDepth = 0
    }

    Write-IlExpression -IL $il -Expr $Lambda.Body -Context $context

    # Final method return
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
}

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
                    -ReturnType (Get-IlType $mm.ReturnType) -ParameterTypes ([Type[]]@($types | ForEach-Object { Get-IlType $_ })) -ParameterNames $names -Persisted
            }
            $methods = @($c.Methods)
            if ($MethodNames -and $c.Name -eq $targetClass.Name) { $methods = @($methods | Where-Object { $_.Name -in $MethodNames }) }
            $methodPlans = foreach ($m in $methods) {
                $types = Get-ParameterTypes $m
                $mm = $mirrorType.GetMethod($m.Name, $declared, $null, $types, $null)
                $mb = $tb.DefineMethod($mm.Name, $mm.Attributes, (Get-IlType $mm.ReturnType), [Type[]]@($types | ForEach-Object { Get-IlType $_ }))
                for ($i = 0; $i -lt $m.Parameters.Count; $i++) { $null = $mb.DefineParameter($i + 1, [Reflection.ParameterAttributes]::None, $m.Parameters[$i].Name.VariablePath.UserPath) }
                Set-NativeCallbackAttribute -Builder $mb -Contract (Get-NativeMethodContract $m)
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
                        $entryNative = Get-NativeMethodContract $method.Ast
                        if ($entryNative -and $entryNative.Kind -eq 'Callback') { throw ('[{0}:{1}] UnmanagedCallersOnly cannot be an entry point.' -f $method.Ast.Extent.StartLineNumber,$method.Ast.Extent.StartColumnNumber) }
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

}

process {
    if ($Help) {
        Get-Help -Name $PSCommandPath -Full
        return
    }
    switch ($Mode) {
        'Compile' {
            $compileParameters = @{}
            foreach ($name in 'SourcePath', 'ClassName', 'MethodNames', 'OutputPath', 'EntryPoint', 'Deterministic') {
                if ($PSBoundParameters.ContainsKey($name)) { $compileParameters[$name] = $PSBoundParameters[$name] }
            }
            Export-LoweredAssembly @compileParameters
        }
        'Expression' {
            if ($null -eq $MethodAst) { throw 'Expression requires -MethodAst.' }
            ConvertTo-TypedExpression -MethodAst $MethodAst
        }
        'Inspect' { Test-LoweredAssembly -AssemblyPath $AssemblyPath }
        'Capability' { Get-LoweringCapability }
    }
}
