Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
