class Slice2Fixture {
    static [int] AddTwo([int] $a, [int] $b) {
        return $a + $b
    }

    static [int] Compute([int] $x, [int] $y) {
        $sum = $x + $y
        $diff = $x - $y
        return $sum * $diff
    }

    static [int] OverflowWrap([int] $a, [int] $b) {
        return $a + $b
    }

    static [int] Negate([int] $v) {
        return -$v
    }

    static [double] FloatMath([double] $a, [double] $b) {
        return ($a * $b) / 2.0
    }

    [int] Calculate([int] $offset, [int] $mult) {
        $temp = $offset * $mult
        return $temp + 5
    }
}
