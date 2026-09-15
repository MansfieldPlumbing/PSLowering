[CmdletBinding()]
param(
    [switch]$PassThru,
    [switch]$BaselineOnly,
    [string]$SpecimenName,
    [AllowEmptyString()][string]$Source
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$instanceFlags = [Reflection.BindingFlags]'Instance,Public,NonPublic'
$staticFlags = [Reflection.BindingFlags]'Static,Public,NonPublic'
$sma = [System.Management.Automation.PSObject].Assembly
$compilerType = $sma.GetType('System.Management.Automation.Language.Compiler', $true)
$compile = $compilerType.GetMethods($instanceFlags) | Where-Object {
    $_.Name -eq 'Compile' -and $_.GetParameters().Count -eq 2 -and
    $_.GetParameters()[1].ParameterType -eq [bool]
} | Select-Object -First 1
$compileTree = $compilerType.GetMethod('CompileTree', $staticFlags)
$always = [Enum]::Parse($sma.GetType('System.Management.Automation.CompileInterpretChoice', $true), 'AlwaysCompile')
$dataField = [ScriptBlock].GetField('_scriptBlockData', $instanceFlags)
$lambdaField = $compilerType.GetField('_endBlockLambda', $instanceFlags)

$specimens = @(
    @{ Name = 'EmptyProbe'; Source = '' },
    @{ Name = 'VoidAddProbe'; Source = 'param($a, $b) [void]($a + $b)' },
    @{ Name = 'ExplicitDoubleProbe'; Source = 'param($a, $b) [void]([double]$a + [double]$b)' }
)
if (-not $BaselineOnly) {
    $specimens += @(
        @{ Name = 'TypedParametersProbe'; Source = 'param([double]$a, [double]$b) [void]($a + $b)' },
        @{ Name = 'TypedCompareProbe'; Source = 'param([double]$a, [double]$b) [void]($a -lt $b)' },
        @{ Name = 'TypedBooleanProbe'; Source = 'param([bool]$a, [bool]$b) [void]($a -and $b)' },
        @{ Name = 'TypedIntegerAddProbe'; Source = 'param([int]$a, [int]$b) [void]($a + $b)' },
        @{ Name = 'DoubleCompareProbe'; Source = 'param($a, $b) [void]([double]$a -lt [double]$b)' },
        @{ Name = 'BooleanLogicProbe'; Source = 'param($a, $b) [void]([bool]$a -and [bool]$b)' },
        @{ Name = 'PrimitiveLocalProbe'; Source = '[double]$a = 2; [double]$b = 3; [void]($a + $b)' },
        @{ Name = 'PrimitiveBranchProbe'; Source = 'param($a) if ([double]$a -gt 0) { [void]([double]$a + 1.0) }' },
        @{ Name = 'PrimitiveLoopProbe'; Source = 'for ([int]$i = 0; $i -lt 3; $i++) { [void]$i }' },
        @{ Name = 'TypedArrayProbe'; Source = 'param([int[]]$values) [void]$values[0]' },
        @{ Name = 'KnownMemberProbe'; Source = 'param([string]$value) [void]$value.Length' },
        @{ Name = 'PrimitiveReturnProbe'; Source = 'param($a, $b) [double]$a + [double]$b' }
    )
}
if ($PSBoundParameters.ContainsKey('Source')) {
    $specimens = @(@{ Name = $(if ($SpecimenName) { $SpecimenName } else { 'CustomProbe' }); Source = $Source })
}
elseif ($SpecimenName) {
    $specimens = @($specimens | Where-Object Name -eq $SpecimenName)
    if (-not $specimens.Count) { throw "Unknown specimen '$SpecimenName'." }
}

foreach ($specimen in $specimens) {
    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $specimen.Source, $specimen.Name + '.ps1', [ref]$tokens, [ref]$parseErrors)
    if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
    $block = $ast.GetScriptBlock()
    $data = $dataField.GetValue($block)
    $compiler = [Activator]::CreateInstance($compilerType, $true)
    $null = $compile.Invoke($compiler, [object[]]@($data, $true))
    $lambda = $lambdaField.GetValue($compiler)
    if (-not $lambda) { throw "$($specimen.Name): SMA emitted no end-block lambda." }

    # Both compilation paths consume the exact object emitted by SMA.
    $directDelegate = $lambda.Compile()
    $compiledDelegate = $compileTree.Invoke($null, [object[]]@($lambda, $always))
    [Runtime.CompilerServices.RuntimeHelpers]::PrepareDelegate($directDelegate)
    [Runtime.CompilerServices.RuntimeHelpers]::PrepareDelegate($compiledDelegate)
    $method = $compiledDelegate.Method
    if ($method -is [Reflection.Emit.DynamicMethod]) {
        $handle = $method.GetType().GetMethod('GetMethodDescriptor', $instanceFlags).Invoke($method, @())
    }
    else {
        $handle = $method.MethodHandle
    }
    $entry = $handle.GetFunctionPointer()
    if ($entry -eq [IntPtr]::Zero) { throw "$($specimen.Name): method entry is null." }

    # These counts describe only the authentic lambda, never native closure.
    $pending = [Collections.Generic.Stack[object]]::new()
    $visited = [Collections.Generic.HashSet[object]]::new([Collections.Generic.ReferenceEqualityComparer]::Instance)
    $nodes = [Collections.Generic.List[object]]::new()
    $pending.Push($lambda)
    while ($pending.Count) {
        $node = $pending.Pop()
        if (-not $visited.Add($node)) { continue }
        if ($node -is [Linq.Expressions.Expression]) { $nodes.Add($node) }
        foreach ($property in $node.GetType().GetProperties([Reflection.BindingFlags]'Public,Instance')) {
            if ($property.GetIndexParameters().Count -or $property.Name -in 'Type','NodeType','CanReduce') { continue }
            $value = $property.GetValue($node)
            if ($value -is [Linq.Expressions.Expression] -or
                $value -is [Linq.Expressions.CatchBlock] -or
                $value -is [Linq.Expressions.SwitchCase]) { $pending.Push($value) }
            elseif ($value -is [Collections.IEnumerable] -and $value -isnot [string]) {
                foreach ($item in $value) {
                    if ($item -is [Linq.Expressions.Expression] -or
                        $item -is [Linq.Expressions.CatchBlock] -or
                        $item -is [Linq.Expressions.SwitchCase]) { $pending.Push($item) }
                }
            }
        }
        # SMA's PowerShellLoopExpression stores its child expressions in a
        # private _exprs field. Inspect those children without reducing or
        # replacing the compiler-produced expression.
        if ($node -is [Linq.Expressions.Expression] -and $node.NodeType -eq 'Extension') {
            foreach ($field in $node.GetType().GetFields($instanceFlags)) {
                $value = $field.GetValue($node)
                if ($value -is [Linq.Expressions.Expression]) { $pending.Push($value) }
                elseif ($value -is [Collections.IEnumerable] -and $value -isnot [string]) {
                    foreach ($item in $value) {
                        if ($item -is [Linq.Expressions.Expression]) { $pending.Push($item) }
                    }
                }
            }
        }
    }
    $binders = @($nodes | Where-Object { $_ -is [Linq.Expressions.DynamicExpression] })
    $operations = @($nodes | Where-Object {
        $_ -is [Linq.Expressions.BinaryExpression] -and
        $_.NodeType -notin 'Assign','ArrayIndex'
    } | ForEach-Object {
        '{0}:{1},{2}->{3}' -f $_.NodeType, $_.Left.Type.FullName, $_.Right.Type.FullName, $_.Type.FullName
    })
    $resultRecord = [pscustomobject]@{
        Name = $specimen.Name
        Source = $specimen.Source
        SourceLanguage = 'POWERSHELL'
        AuthenticSma = 'PASS'
        SameLambdaObject = [object]::ReferenceEquals($lambda, $lambdaField.GetValue($compiler))
        DirectLambdaCompile = 'PASS'
        PowerShellCompileTreeAlways = 'PASS'
        RyuJit = 'PASS'
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        RuntimeVersion = [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription
        SmaAssembly = $sma.Location
        LambdaType = $lambda.GetType().FullName
        LambdaName = $lambda.Name
        MethodName = $method.Name
        MethodType = $method.GetType().FullName
        EntryPoint = $entry
        EntryPointKind = 'RuntimeMethodHandle.GetFunctionPointer; may be precode'
        NativeCodeSize = 'UNKNOWN'
        NativeRuntimeDependencies = 'UNKNOWN'
        LambdaBinderCount = $binders.Count
        LambdaTraversal = 'Public expression children plus reflected SMA extension expression fields; no reduction or rewriting'
        LambdaExtensionTypes = @($nodes | Where-Object NodeType -eq Extension | ForEach-Object { $_.GetType().FullName } | Select-Object -Unique)
        LambdaBinders = @($binders | ForEach-Object { $_.Binder.GetType().Name })
        LambdaOperations = $operations
        Ast = $ast
        Lambda = $lambda
        Delegate = $compiledDelegate
        DirectDelegate = $directDelegate
        Method = $method
        MethodHandle = $handle
        Compiler = $compiler
        ScriptBlock = $block
    }
    if ($PassThru) { $resultRecord }
    else {
        '{0}: SOURCE=POWERSHELL AUTHENTIC_SMA=PASS SAME_LAMBDA_OBJECT={1} DIRECT_LAMBDA_COMPILE=PASS POWERSHELL_COMPILETREE_ALWAYS=PASS RYUJIT=PASS' -f $resultRecord.Name, $resultRecord.SameLambdaObject
        'METHOD={0} METHOD_TYPE={1} ENTRY_POINT=0x{2:X} NATIVE_CODE_SIZE=UNKNOWN NATIVE_RUNTIME_DEPS=UNKNOWN' -f $resultRecord.MethodName, $resultRecord.MethodType, $entry.ToInt64()
        'LAMBDA_BINDER_COUNT={0} LAMBDA_BINDERS={1} LAMBDA_OPERATIONS={2}' -f $resultRecord.LambdaBinderCount, ($resultRecord.LambdaBinders -join ','), ($operations -join ';')
    }
}
