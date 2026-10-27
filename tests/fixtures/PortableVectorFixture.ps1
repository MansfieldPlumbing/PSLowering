class PortableVectorProbe {
    static [float] Sum4([float[]] $a, [float[]] $b) {
        $x = [System.Runtime.Intrinsics.Vector128]::Create($a[0], $a[1], $a[2], $a[3])
        $y = [System.Runtime.Intrinsics.Vector128]::Create($b[0], $b[1], $b[2], $b[3])
        $s = [System.Runtime.Intrinsics.Vector128]::Add($x, [System.Runtime.Intrinsics.Vector128]::Multiply($x, $y))
        $w = [System.Runtime.Intrinsics.Vector256]::Create($a[0], $a[1], $a[2], $a[3], $b[0], $b[1], $b[2], $b[3])
        $w = [System.Runtime.Intrinsics.Vector256]::Add($w, [System.Runtime.Intrinsics.Vector256]::Multiply($w, $w))
        $low = [System.Runtime.Intrinsics.Vector256]::GetLower($w)
        $high = [System.Runtime.Intrinsics.Vector256]::GetUpper($w)
        $ints = [System.Runtime.Intrinsics.Vector128]::Create([int]1, [int]2, [int]3, [int]4)
        $floats = [System.Runtime.Intrinsics.Vector128]::ConvertToSingle($ints)
        return [System.Runtime.Intrinsics.Vector128]::GetElement($s, 0) + $low.get_Item(3) + $high.get_Item(3) + $floats.get_Item(2)
    }

    static [float[]] Lanes128([float[]] $a, [float[]] $b) {
        $x = [System.Runtime.Intrinsics.Vector128]::Create($a[0], $a[1], $a[2], $a[3])
        $y = [System.Runtime.Intrinsics.Vector128]::Create($b[0], $b[1], $b[2], $b[3])
        $sum = [System.Runtime.Intrinsics.Vector128]::Add($x, $y)
        $product = [System.Runtime.Intrinsics.Vector128]::Multiply($x, $y)
        $difference = [System.Runtime.Intrinsics.Vector128]::Subtract($x, $y)
        $operators = [System.Runtime.Intrinsics.Vector128[float]]::op_Addition($x, [System.Runtime.Intrinsics.Vector128[float]]::op_Multiply($x, $y))
        $syntax = $x + $x * $y
        $result = [float[]]::new(20)
        for ($i = 0; $i -lt 4; $i++) {
            $result[$i] = $sum.get_Item($i)
            $result[$i + 4] = $product.get_Item($i)
            $result[$i + 8] = $difference.get_Item($i)
            $result[$i + 12] = $operators.get_Item($i)
            $result[$i + 16] = $syntax.get_Item($i)
        }
        return $result
    }

    static [float[]] IntLanes([int[]] $a) {
        $ints = [System.Runtime.Intrinsics.Vector128]::Create($a[0], $a[1], $a[2], $a[3])
        $floats = [System.Runtime.Intrinsics.Vector128]::ConvertToSingle($ints)
        $result = [float[]]::new(4)
        for ($i = 0; $i -lt 4; $i++) { $result[$i] = $floats.get_Item($i) }
        return $result
    }

    static [double[]] DoubleLanes([double[]] $a, [double[]] $b) {
        $x = [System.Runtime.Intrinsics.Vector256]::Create($a[0], $a[1], $a[2], $a[3])
        $y = [System.Runtime.Intrinsics.Vector256]::Create($b[0], $b[1], $b[2], $b[3])
        $sum = [System.Runtime.Intrinsics.Vector256]::Add($x, $y)
        $product = [System.Runtime.Intrinsics.Vector256]::Multiply($x, $y)
        $result = [double[]]::new(8)
        for ($i = 0; $i -lt 4; $i++) {
            $result[$i] = $sum.get_Item($i)
            $result[$i + 4] = $product.get_Item($i)
        }
        return $result
    }

    static [float] Parameter([System.Runtime.Intrinsics.Vector128[float]] $v, [int] $i) { return $v.get_Item($i) }
    static [float] Element([System.Runtime.Intrinsics.Vector128[float][]] $values, [int] $i) { return $values[$i].get_Item(2) }
    static [float] Temporary([float] $value) { return [System.Runtime.Intrinsics.Vector128]::Create($value).get_Item(1) }
    static [float] Numerics([float[]] $values) {
        $v = [System.Numerics.Vector[float]]::new($values)
        return $v.get_Item(1)
    }
    static [int] ArrayInference([int[]] $values, [int] $value) { return [Array]::IndexOf($values, $value) }
    static [int] MirrorInference() {
        $value = [PortableVectorHolder]::new()
        $values = [PortableVectorHolder[]]::new(2)
        $values[1] = $value
        return [Array]::IndexOf($values, $value)
    }
    static [string] Virtual([System.Runtime.Intrinsics.Vector128[float]] $v) { return $v.ToString() }
    static [string] InheritedVirtual([int] $v) { return $v.ToString() }
}

class PortableVectorHolder {
    PortableVectorHolder() { }
    [System.Runtime.Intrinsics.Vector128[float]] $Value
    static [System.Runtime.Intrinsics.Vector128[float]] $Shared
    [float] Field([int] $i) { return $this.Value.get_Item($i) }
    static [float] StaticField([int] $i) { return [PortableVectorHolder]::Shared.get_Item($i) }
}
