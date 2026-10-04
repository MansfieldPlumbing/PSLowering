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
}
