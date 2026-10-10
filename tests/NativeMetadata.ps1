function Get-NativeInstructions([Reflection.MethodInfo]$Method) {
    $opcodes=@{}
    foreach($field in [Reflection.Emit.OpCodes].GetFields([Reflection.BindingFlags]'Public,Static')) {
        $op=$field.GetValue($null)
        $opcodes[[int]$op.Value -band 65535]=$op
    }
    $bytes=$Method.GetMethodBody().GetILAsByteArray()
    $offset=0
    while($offset -lt $bytes.Length) {
        $value=[int]$bytes[$offset]
        $offset++
        if($value -eq 254) { $value=65024+[int]$bytes[$offset]; $offset++ }
        $op=$opcodes[$value]
        if($null -eq $op) { throw "Invalid opcode in $($Method.Name) at $offset (value $value)." }
        $size=switch($op.OperandType.ToString()) {
            InlineNone {0}
            {$_ -in 'ShortInlineBrTarget','ShortInlineI','ShortInlineVar'} {1}
            InlineVar {2}
            {$_ -in 'InlineI8','InlineR'} {8}
            InlineSwitch {4+4*[BitConverter]::ToInt32($bytes,$offset)}
            default {4}
        }
        $token=if($op.OperandType -in 'InlineSig','InlineMethod') { [BitConverter]::ToInt32($bytes,$offset) } else { 0 }
        [pscustomobject]@{Name=$op.Name;Token=$token}
        $offset+=$size
    }
}

function Test-NativeMetadata([Type]$Type) {
    # ECMA-335 II.23.2.3 and II.23.1.16: unmanaged call kind, count,
    # return element type, then the exact ordered parameter element types.
    $signatures=[ordered]@{ProcessId='020009';Compare='0102081818';Sort='01040118191918';CallMixed='01040D0A0C0D0A';CallEcho='02011818';CallWrite='010201180A'}
    foreach($name in $signatures.Keys) {
        $method=$Type.GetMethod($name)
        $calls=@(Get-NativeInstructions $method | Where-Object Name -CEQ 'calli')
        if($calls.Count -ne 1 -or [Convert]::ToHexString($method.Module.ResolveSignature($calls[0].Token)) -cne $signatures[$name]) { throw "Incorrect unmanaged signature metadata: $name" }
    }
    foreach($pair in @(@('ComparatorAddress','Comparator'),@('MixedAddress','Mixed'),@('EchoAddress','EchoPointer'),@('WriteAddress','WriteValue'))) {
        $method=$Type.GetMethod($pair[0])
        $addresses=@(Get-NativeInstructions $method | Where-Object Name -CEQ 'ldftn')
        if($addresses.Count -ne 1 -or $method.Module.ResolveMethod($addresses[0].Token).Name -cne $pair[1]) { throw "Incorrect typed ldftn target: $($pair[0])" }
    }
}
