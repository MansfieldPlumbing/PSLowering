class ObjectConversionFixture {
    static [int] ToInt([object] $value) { return [int]$value }
    static [long] ToLong([object] $value) { return [long]$value }
    static [double] ToDouble([object] $value) { return [double]$value }
    static [byte] ToByte([object] $value) { return [byte]$value }
    static [char] ToChar([object] $value) { return [char]$value }
    static [int] TextToInt([string] $text) { return [int]$text }

    static [int] SumBoxed([object[]] $values) {
        [int]$total = 0
        foreach ($value in $values) { $total += [int]$value }
        return $total
    }
}
