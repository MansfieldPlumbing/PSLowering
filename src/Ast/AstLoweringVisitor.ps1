Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'AstTypeResolver.ps1')
. (Join-Path $PSScriptRoot 'AstValidator.ps1')

$script:ExpressionNewMethod = [Linq.Expressions.Expression].GetMethod(
    'New',
    [Type[]]@([Reflection.ConstructorInfo], [System.Collections.Generic.IEnumerable[Linq.Expressions.Expression]])
)

function Parse-PowerShellClass {
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
                        $itemExpr = [Linq.Expressions.Expression]::Convert($itemExpr, $elemType)
                    }
                    $elemExprList.Add($itemExpr)
                }
                return [Linq.Expressions.Expression]::NewArrayInit($elemType, [Linq.Expressions.Expression[]]$elemExprList.ToArray())
            }
        }
        $child = Convert-AstExpression -Node $Node.Child -Scope $Scope
        return [Linq.Expressions.Expression]::Convert($child, $targetType)
    }

    # 7. Unary arithmetic expressions: -$x, ++$x, --$x, $x++, $x--
    if ($Node -is [System.Management.Automation.Language.UnaryExpressionAst]) {
        if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus', 'PostfixMinusMinus', 'PrefixMinusMinus') {
            $target = Convert-AstExpression -Node $Node.Child -Scope $Scope
            $one = [Linq.Expressions.Expression]::Constant(1, $target.Type)
            if ($Node.TokenKind -in 'PostfixPlusPlus', 'PrefixPlusPlus') {
                return [Linq.Expressions.Expression]::Assign($target, [Linq.Expressions.Expression]::Add($target, $one))
            } else {
                return [Linq.Expressions.Expression]::Assign($target, [Linq.Expressions.Expression]::Subtract($target, $one))
            }
        }

        $operand = Convert-AstExpression -Node $Node.Child -Scope $Scope
        switch ($Node.TokenKind) {
            'Minus'   { return [Linq.Expressions.Expression]::Negate($operand) }
            'Plus'    { return $operand }
            'Not'     { return [Linq.Expressions.Expression]::Not($operand) }
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

        if ($left.Type -ne $right.Type) {
            throw "[{0}:{1}] Binary operator '{2}' requires identical operand types, got '{3}' and '{4}'." -f `
                $Node.Extent.StartLineNumber, $Node.Extent.StartColumnNumber, $Node.Operator, $left.Type.FullName, $right.Type.FullName
        }

        switch ($Node.Operator) {
            'Plus'     { return [Linq.Expressions.Expression]::Add($left, $right) }
            'Minus'    { return [Linq.Expressions.Expression]::Subtract($left, $right) }
            'Multiply' { return [Linq.Expressions.Expression]::Multiply($left, $right) }
            'Divide'   { return [Linq.Expressions.Expression]::Divide($left, $right) }
            'Rem'      { return [Linq.Expressions.Expression]::Modulo($left, $right) }
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
        if ($targetExpr.Type.IsArray) {
            if ($idxExpr.Type -ne [int]) {
                $idxExpr = [Linq.Expressions.Expression]::Convert($idxExpr, [int])
            }
            return [Linq.Expressions.Expression]::ArrayIndex($targetExpr, $idxExpr)
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
                    $lenExpr = [Linq.Expressions.Expression]::Convert($lenExpr, [int])
                }
                return [Linq.Expressions.Expression]::NewArrayBounds($targetType.GetElementType(), $lenExpr)
            }

            # Object constructor: [T]::new(...)
            if ($memberName -eq 'new') {
                $ctor = Resolve-MatchingConstructor -TargetType $targetType -ArgumentTypes $argTypes
                $params = $ctor.GetParameters()
                for ($i = 0; $i -lt $params.Length; $i++) {
                    if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                        $argExprs[$i] = [Linq.Expressions.Expression]::Convert($argExprs[$i], $params[$i].ParameterType)
                    }
                }
                return $script:ExpressionNewMethod.Invoke($null, @($ctor, [Linq.Expressions.Expression[]]$argExprs.ToArray()))
            }

            # Static method call: [T]::Method(...)
            $method = Resolve-MatchingMethod -TargetType $targetType -MethodName $memberName -ArgumentTypes $argTypes -IsStatic
            $params = $method.GetParameters()
            for ($i = 0; $i -lt $params.Length; $i++) {
                if ($argExprs[$i].Type -ne $params[$i].ParameterType) {
                    $argExprs[$i] = [Linq.Expressions.Expression]::Convert($argExprs[$i], $params[$i].ParameterType)
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
                    $argExprs[$i] = [Linq.Expressions.Expression]::Convert($argExprs[$i], $params[$i].ParameterType)
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
            $member = Resolve-MatchingMember -TargetType $targetType -MemberName $memberName -IsStatic
            if ($member -is [Reflection.PropertyInfo]) {
                return [Linq.Expressions.Expression]::Property($null, $member)
            }
            if ($member -is [Reflection.FieldInfo]) {
                return [Linq.Expressions.Expression]::Field($null, $member)
            }
        }
        else {
            $targetExpr = Convert-AstExpression -Node $Node.Expression -Scope $Scope
            if ($targetExpr.Type.IsArray -and $memberName -eq 'Length') {
                return [Linq.Expressions.Expression]::ArrayLength($targetExpr)
            }
            $member = Resolve-MatchingMember -TargetType $targetExpr.Type -MemberName $memberName
            if ($member -is [Reflection.PropertyInfo]) {
                return [Linq.Expressions.Expression]::Property($targetExpr, $member)
            }
            if ($member -is [Reflection.FieldInfo]) {
                return [Linq.Expressions.Expression]::Field($targetExpr, $member)
            }
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

        # Array element assignment: $arr[$i] = <expr>
        if ($leftNode -is [System.Management.Automation.Language.IndexExpressionAst]) {
            $targetExpr = Convert-AstExpression -Node $leftNode.Target -Scope $Scope
            $idxExpr = Convert-AstExpression -Node $leftNode.Index -Scope $Scope
            if (-not $targetExpr.Type.IsArray) {
                throw "[{0}:{1}] Cannot assign into non-array type '{2}'." -f `
                    $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $targetExpr.Type.FullName
            }
            if ($idxExpr.Type -ne [int]) {
                $idxExpr = [Linq.Expressions.Expression]::Convert($idxExpr, [int])
            }
            $elemType = $targetExpr.Type.GetElementType()
            $valExpr = Convert-AstExpression -Node $Statement.Right -Scope $Scope
            if ($valExpr.Type -ne $elemType) {
                $valExpr = [Linq.Expressions.Expression]::Convert($valExpr, $elemType)
            }
            $arrayAccess = [Linq.Expressions.Expression]::ArrayAccess($targetExpr, $idxExpr)
            return [Linq.Expressions.Expression]::Assign($arrayAccess, $valExpr)
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

        $valExpr = Convert-AstExpression -Node $Statement.Right -Scope $Scope

        if ($explicitType -and $valExpr.Type -ne $explicitType) {
            $valExpr = [Linq.Expressions.Expression]::Convert($valExpr, $explicitType)
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
            $valExpr = [Linq.Expressions.Expression]::Convert($valExpr, $targetVar.Type)
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

        $retVal = Convert-AstExpression -Node $Statement.Pipeline -Scope $Scope
        if ($retVal.Type -ne $Scope.ReturnType) {
            $retVal = [Linq.Expressions.Expression]::Convert($retVal, $Scope.ReturnType)
        }

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

        $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope

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
        $bodyExpr = Convert-AstStatement -Statement $Statement.Body -Scope $Scope

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

    throw "[{0}:{1}] Unsupported AST statement '{2}' ({3})." -f `
        $Statement.Extent.StartLineNumber, $Statement.Extent.StartColumnNumber, $Statement.Extent.Text, $Statement.GetType().Name
}

function Convert-MethodAstToLambda {
    <#
    .SYNOPSIS
        Lowers a FunctionMemberAst into a validated System.Linq.Expressions.LambdaExpression.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Language.FunctionMemberAst] $MethodAst
    )

    Test-AstAdmitted -Ast $MethodAst

    $retType = if ($MethodAst.ReturnType) {
        Resolve-AstType $MethodAst.ReturnType.TypeName
    }
    else {
        [void]
    }

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

    $returnTarget = [Linq.Expressions.Expression]::Label($retType, 'returnTarget')

    $declaredLocals = [System.Collections.Generic.List[Linq.Expressions.ParameterExpression]]::new()

    $scope = @{
        ReturnType     = $retType
        ReturnTarget   = $returnTarget
        Parameters     = $paramMap
        Locals         = @{}
        DeclaredLocals = $declaredLocals
    }

    $statements = [System.Collections.Generic.List[Linq.Expressions.Expression]]::new()

    if ($MethodAst.Body -and $MethodAst.Body.EndBlock -and $MethodAst.Body.EndBlock.Statements) {
        foreach ($stmt in $MethodAst.Body.EndBlock.Statements) {
            $expr = Convert-AstStatement -Statement $stmt -Scope $scope
            $statements.Add($expr)
        }
    }

    # Epilogue: Mark return target
    $defaultVal = if ($retType -eq [void]) {
        [Linq.Expressions.Expression]::Empty()
    }
    else {
        [Linq.Expressions.Expression]::Default($retType)
    }
    $statements.Add([Linq.Expressions.Expression]::Label($returnTarget, $defaultVal))

    $bodyBlock = [Linq.Expressions.Expression]::Block(
        $retType,
        [Linq.Expressions.ParameterExpression[]]$declaredLocals.ToArray(),
        [Linq.Expressions.Expression[]]$statements.ToArray()
    )

    $lambda = [Linq.Expressions.Expression]::Lambda(
        $bodyBlock,
        $MethodAst.Name,
        [Linq.Expressions.ParameterExpression[]]$paramExprList.ToArray()
    )

    [pscustomobject]@{
        Name           = $MethodAst.Name
        IsStatic       = [bool]$MethodAst.IsStatic
        ReturnType     = $retType
        ParameterTypes = [Type[]]@($paramExprList | ForEach-Object { $_.Type })
        ParameterNames = [string[]]@($paramExprList | ForEach-Object { $_.Name })
        Lambda         = $lambda
    }
}
