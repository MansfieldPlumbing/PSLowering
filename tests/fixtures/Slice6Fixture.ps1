class Slice6Fixture {
    static [int[]] AllocateIntArray([int] $size) {
        return [int[]]::new($size)
    }

    static [int] SumArray([int[]] $arr) {
        $sum = 0
        for ($i = 0; $i -lt $arr.Length; $i++) {
            $sum = $sum + $arr[$i]
        }
        return $sum
    }

    static [float[]] ScaleFloatArray([float[]] $arr, [float] $scale) {
        for ($i = 0; $i -lt $arr.Length; $i++) {
            $arr[$i] = $arr[$i] * $scale
        }
        return $arr
    }

    static [int[]] ArrayLiteralInit() {
        return [int[]]@(10, 20, 30, 40)
    }

    static [int] ArrayLengthCheck([double[]] $arr) {
        return $arr.Length
    }

    static [int[]] CopyArray([int[]] $src) {
        $dst = [int[]]::new($src.Length)
        for ($i = 0; $i -lt $src.Length; $i++) {
            $dst[$i] = $src[$i]
        }
        return $dst
    }
}
