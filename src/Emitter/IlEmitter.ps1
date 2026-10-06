Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
