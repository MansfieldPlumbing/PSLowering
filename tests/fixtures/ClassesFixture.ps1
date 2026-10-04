class CellBox {
    [int] $Scalar = 32
    [int] $Width = 1

    CellBox() { }

    CellBox([int] $scalar, [int] $width) {
        $this.Scalar = $scalar
        $this.Width = $width
    }

    [int] Packed() {
        return ($this.Scalar -shl 2) -bor $this.Width
    }
}

class ClassesFixture {
    [int] $Total
    static [int[]] $Palette = @(0x0c0c0c, 0xc50f1f, 0x13a10e)
    static [int] $Base = [ClassesFixture]::ComputeBase()

    ClassesFixture() {
        $this.Total = 10
    }

    static [int] ComputeBase() {
        return 7
    }

    [void] Add([int] $n) {
        $this.Total += $n
    }

    static [int] UseInstance([int] $a, [int] $b) {
        $f = [ClassesFixture]::new()
        $f.Add($a)
        $f.Add($b)
        return $f.Total
    }

    static [int] DefaultCell() {
        $c = [CellBox]::new()
        return $c.Scalar * 10 + $c.Width
    }

    static [int] PackedCell([int] $s, [int] $w) {
        return [CellBox]::new($s, $w).Packed()
    }

    static [int] SumCells([int] $n) {
        $list = [System.Collections.Generic.List[CellBox]]::new()
        for ([int] $i = 0; $i -lt $n; $i++) {
            $list.Add([CellBox]::new($i, 1))
        }
        [int] $sum = 0
        foreach ($cell in $list.ToArray()) {
            $sum += $cell.Scalar
        }
        return $sum * 100 + $list.Count
    }

    static [int] PaletteAt([int] $i) {
        return [ClassesFixture]::Palette[$i]
    }

    static [int] BaseValue() {
        return [ClassesFixture]::Base
    }

    static [int] Bits([int] $a, [int] $b) {
        return (($a -band $b) -bxor ($a -bor $b)) + (-bnot $a)
    }

    static [int] Shifts([int] $a, [int] $n) {
        return ($a -shl $n) + ($a -shr $n)
    }

    static [int] SetLast([int[]] $values, [int] $v) {
        $values[-1] = $v
        $values[-2] += 1
        return $values[0] * 1000 + $values[$values.Length - 1]
    }
}
