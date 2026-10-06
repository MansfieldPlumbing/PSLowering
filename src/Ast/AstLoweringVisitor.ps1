Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AstTypeResolver.ps1')
. (Join-Path $PSScriptRoot 'AstValidator.ps1')
. (Join-Path $PSScriptRoot 'ClassModel.ps1')

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
        conversion does). Integral narrowing throws on overflow. Other
        conversions are plain CLR conversions.
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
