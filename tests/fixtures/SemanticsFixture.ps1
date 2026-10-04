class SemanticsFixture {
    static [int] IntDivide([int] $a, [int] $b) {
        return $a / $b
    }

    static [double] IntDivideToDouble([int] $a, [int] $b) {
        return $a / $b
    }

    static [int] DoubleToInt([double] $d) {
        return $d
    }

    static [int] DoubleToIntLocal([double] $d) {
        [int] $i = $d
        return $i
    }

    static [long] LongMultiply([long] $a, [long] $b) {
        return $a * $b
    }

    static [int] Increment([int] $a) {
        $a++
        return $a
    }

    static [bool] StringEqual([string] $a, [string] $b) {
        return $a -eq $b
    }

    static [bool] StringEqualCase([string] $a, [string] $b) {
        return $a -ceq $b
    }

    static [bool] StringNotEqual([string] $a, [string] $b) {
        return $a -ne $b
    }

    static [bool] StringLess([string] $a, [string] $b) {
        return $a -lt $b
    }

    static [int] CompoundInt([int] $a, [int] $b) {
        [int] $x = $a
        $x += $b
        $x *= 2
        $x -= 1
        $x %= 7
        return $x
    }

    static [int] CompoundDivide([int] $a, [int] $b) {
        [int] $x = $a
        $x /= $b
        return $x
    }

    static [string] Concat([string] $a, [string] $b) {
        [string] $s = $a + '-'
        $s += $b
        return $s
    }
}
