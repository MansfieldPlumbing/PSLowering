# PowerShell cannot declare a CLR struct. Public Reflection.Emit supplies a
# consumer-defined value type, independently of the compiler under test.
function New-PortableStructAssembly([string] $Path) {
    $builder = [Reflection.Emit.PersistedAssemblyBuilder]::new([Reflection.AssemblyName]::new('PortableStructSupport'), [object].Assembly)
    $module = $builder.DefineDynamicModule('PortableStructSupport')
    $type = $module.DefineType('PortableCounter', [Reflection.TypeAttributes]'Public,Sealed,SequentialLayout', [ValueType])
    $field = $type.DefineField('Value', [int], [Reflection.FieldAttributes]::Public)
    $methodFlags = [Reflection.MethodAttributes]'Public,HideBySig'
    $scale = $type.DefineMethod('Scale', $methodFlags, [int], [Type[]]@([int]))
    $il = $scale.GetILGenerator()
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
    $il.Emit([Reflection.Emit.OpCodes]::Ldfld, $field)
    $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1)
    $il.Emit([Reflection.Emit.OpCodes]::Mul)
    $il.Emit([Reflection.Emit.OpCodes]::Ret)
    foreach ($name in @('Current', 'Item')) {
        [Type[]] $indices = if ($name -eq 'Item') { @([int]) } else { @() }
        $property = $type.DefineProperty($name, [Reflection.PropertyAttributes]::None, [int], $indices)
        $getter = $type.DefineMethod("get_$name", ($methodFlags -bor [Reflection.MethodAttributes]::SpecialName), [int], $indices)
        $il = $getter.GetILGenerator()
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit([Reflection.Emit.OpCodes]::Ldfld, $field)
        if ($name -eq 'Item') { $il.Emit([Reflection.Emit.OpCodes]::Ldarg_1); $il.Emit([Reflection.Emit.OpCodes]::Add) }
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        $property.SetGetMethod($getter)
        $setter = $type.DefineMethod("set_$name", ($methodFlags -bor [Reflection.MethodAttributes]::SpecialName), [void], [Type[]]@($indices + [Type[]]@([int])))
        $il = $setter.GetILGenerator()
        $il.Emit([Reflection.Emit.OpCodes]::Ldarg_0)
        $il.Emit($(if ($name -eq 'Item') { [Reflection.Emit.OpCodes]::Ldarg_2 } else { [Reflection.Emit.OpCodes]::Ldarg_1 }))
        $il.Emit([Reflection.Emit.OpCodes]::Stfld, $field)
        $il.Emit([Reflection.Emit.OpCodes]::Ret)
        $property.SetSetMethod($setter)
    }
    $null = $type.CreateType()
    $utility = $module.DefineType('PortableInference', [Reflection.TypeAttributes]'Public,Abstract,Sealed')
    $flags = [Reflection.MethodAttributes]'Public,Static'
    # Same signature after inference: the non-generic overload must win.
    $plain = $utility.DefineMethod('Choose', $flags, [int], [Type[]]@([int]))
    $il = $plain.GetILGenerator(); $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_1); $il.Emit([Reflection.Emit.OpCodes]::Ret)
    $generic = $utility.DefineMethod('Choose', $flags)
    $parameter = $generic.DefineGenericParameters([string[]]@('T'))[0]
    $generic.SetReturnType([int]); $generic.SetParameters([Type[]]@($parameter))
    $il = $generic.GetILGenerator(); $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_2); $il.Emit([Reflection.Emit.OpCodes]::Ret)
    foreach ($name in @('Nested', 'Conflict', 'Constrained', 'Uninferred')) {
        $method = $utility.DefineMethod($name, $flags)
        $parameter = $method.DefineGenericParameters([string[]]@('T'))[0]
        $signature = switch ($name) {
            Nested { [Type[]]@([Collections.Generic.List``1].MakeGenericType([Type[]]@($parameter.MakeArrayType()))) }
            Conflict { [Type[]]@($parameter, $parameter) }
            Constrained { $parameter.SetGenericParameterAttributes([Reflection.GenericParameterAttributes]::ReferenceTypeConstraint); [Type[]]@($parameter) }
            Uninferred { [Type[]]@([int]) }
        }
        $method.SetReturnType([int]); $method.SetParameters([Type[]]$signature)
        $il = $method.GetILGenerator(); $il.Emit([Reflection.Emit.OpCodes]::Ldc_I4_3); $il.Emit([Reflection.Emit.OpCodes]::Ret)
    }
    $null = $utility.CreateType()
    $builder.Save($Path)
}
