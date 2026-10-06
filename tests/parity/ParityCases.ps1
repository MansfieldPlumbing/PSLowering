<#
.SYNOPSIS
    Input cases shared by the two parity checks.
.DESCRIPTION
    Returns one entry per fixture method: the fixture file, class, method and
    the argument lists to call it with. Both parity checks use this list, so the
    compiled assembly is checked against the framework's LambdaCompiler and
    against the PowerShell source on the same inputs. Boundary inputs
    (overflow, rounding midpoints, NaN, letter case, empty strings) are here
    because those are where lowered code and PowerShell can disagree.
#>
function V([string] $Fixture, [string] $Class, [string] $Method, [object[][]] $Inputs) {
    [pscustomobject]@{ Fixture = $Fixture; Class = $Class; Method = $Method; Inputs = $Inputs }
}
$max = [int]::MaxValue; $min = [int]::MinValue

# Slice 1: signatures and constants
V Slice1Fixture.ps1 Slice1Fixture GetAnswer      @(, @())
V Slice1Fixture.ps1 Slice1Fixture GetFalse       @(, @())
V Slice1Fixture.ps1 Slice1Fixture GetGreeting    @(, @())
V Slice1Fixture.ps1 Slice1Fixture DoNothing      @(, @())
V Slice1Fixture.ps1 Slice1Fixture GetInstanceVal @(, @())

# Slices 2-3: parameters, locals, arithmetic
V Slice2Fixture.ps1 Slice2Fixture AddTwo       @(@(0, 0), @(15, 27), @(-10, 20), @(($max - 1), 1), @($max, 1), @($min, -1))
V Slice2Fixture.ps1 Slice2Fixture Compute      @(@(10, 4), @(20, 5), @(100, 1), @(7, 2), @(5, 2), @(-7, 2))
V Slice2Fixture.ps1 Slice2Fixture OverflowAdd @(@($max, 1), @($min, -1), @(1, 2))
V Slice2Fixture.ps1 Slice2Fixture Negate       @(@(0), @(42), @(-99), @($min))
V Slice2Fixture.ps1 Slice2Fixture FloatMath    @(@(10.0, 5.0), @(2.5, 4.0), @(0.0, 100.0), @([double]::NaN, 1.0))
V Slice2Fixture.ps1 Slice2Fixture Calculate    @(@(10, 2), @(0, 5), @(-4, 3), @($max, 2))

# Slice 4: comparisons and Boolean logic
V Slice4Fixture.ps1 Slice4Fixture IntEqual          @(@(10, 10), @(10, 20))
V Slice4Fixture.ps1 Slice4Fixture IntLess           @(@(5, 10), @(10, 5), @(7, 7))
V Slice4Fixture.ps1 Slice4Fixture IntLessOrEqual    @(@(5, 10), @(10, 10), @(10, 5))
V Slice4Fixture.ps1 Slice4Fixture IntGreaterOrEqual @(@(5, 10), @(10, 10), @(10, 5))
V Slice4Fixture.ps1 Slice4Fixture FloatLessOrEqual  @(@(2.5, 3.5), @(3.5, 3.5), @([double]::NaN, 1.0), @(1.0, [double]::NaN))
V Slice4Fixture.ps1 Slice4Fixture LogicalAnd        @(@($true, $true), @($true, $false), @($false, $true), @($false, $false))
V Slice4Fixture.ps1 Slice4Fixture LogicalOr         @(@($true, $false), @($false, $false), @($true, $true))
V Slice4Fixture.ps1 Slice4Fixture LogicalNot        @(@($true), @($false))

# Slice 5: control flow
V Slice5Fixture.ps1 Slice5Fixture BranchMax         @(@(10, 20), @(50, 25), @(0, 0))
V Slice5Fixture.ps1 Slice5Fixture NestedIf          @(@(150), @(50), @(-10), @(0))
V Slice5Fixture.ps1 Slice5Fixture SumTo             @(@(0), @(5), @(10), @(70000))
V Slice5Fixture.ps1 Slice5Fixture EarlyReturnInLoop @(@(5), @(200), @(0))
V Slice5Fixture.ps1 Slice5Fixture WhileCountdown    @(@(5), @(0), @(10))

# Slice 6: typed arrays
V Slice6Fixture.ps1 Slice6Fixture AllocateIntArray  @(@(0), @(3))
V Slice6Fixture.ps1 Slice6Fixture SumArray          @(@(, [int[]]@(1, 2, 3)), @(, [int[]]@()), @(, [int[]]@($max, 1)))
V Slice6Fixture.ps1 Slice6Fixture ScaleFloatArray   @(@([float[]]@(1.5, -2.0), [float]2.0), @([float[]]@(), [float]3.0))
V Slice6Fixture.ps1 Slice6Fixture ArrayLiteralInit  @(, @())
V Slice6Fixture.ps1 Slice6Fixture ArrayLengthCheck  @(@(, [double[]]@(1.0, 2.0)), @(, [double[]]@()))
V Slice6Fixture.ps1 Slice6Fixture CopyArray         @(@(, [int[]]@(4, 5, 6)), @(, [int[]]@()))

# Slice 7: .NET calls and constructors
V Slice7Fixture.ps1 Slice7Fixture StaticMath    @(@(3, 9), @(-4, 2))
V Slice7Fixture.ps1 Slice7Fixture SubstringTest @(@('PowerShell', 0, 5), @('PowerShell', 5, 5), @('abc', 2, 5))
V Slice7Fixture.ps1 Slice7Fixture BuildGreeting @(@('World'), @(''))
V Slice7Fixture.ps1 Slice7Fixture IsEmpty       @(@(''), @('x'))
V Slice7Fixture.ps1 Slice7Fixture PathCombine   @(@('C:\foo', 'bar.txt'), @('a', 'b'))

# Slice 8: exceptions
V Slice8Fixture.ps1 Slice8Fixture ThrowPositive       @(@(-1), @(0), @(1))
V Slice8Fixture.ps1 Slice8Fixture TryCatchParse       @(@('42', 0), @('x', 7), @('', 9))
V Slice8Fixture.ps1 Slice8Fixture TryFinallyExecution @(@(0), @(10))
V Slice8Fixture.ps1 Slice8Fixture MultiCatch          @(@('5'), @('x'), @(''))

# Slice 9: the Kokoro consumer contract
V Slice9KokoroFixture.ps1 VoiceRowIndexContract VoiceRowIndex  @(@(1), @(50), @(256), @(510), @(0), @(-5), @(511), @($max), @($min))
V Slice9KokoroFixture.ps1 VoiceRowIndexContract SynthesisReady @(, @())

# Semantics: division, rounding, widening and string comparison
V SemanticsFixture.ps1 SemanticsFixture IntDivide         @(@(6, 2), @(7, 2), @(5, 2), @(-7, 2), @(1, 0), @($min, -1))
V SemanticsFixture.ps1 SemanticsFixture IntDivideToDouble @(@(6, 2), @(7, 2), @(1, 3), @(1, 0))
V SemanticsFixture.ps1 SemanticsFixture DoubleToInt       @(@(2.5), @(3.5), @(-2.5), @(2.4999), @(1e10), @([double]::NaN))
V SemanticsFixture.ps1 SemanticsFixture DoubleToIntLocal  @(@(2.5), @(3.5), @(1e10))
V SemanticsFixture.ps1 SemanticsFixture LongMultiply      @(@([long]3, [long]4), @([long]::MaxValue, [long]2))
V SemanticsFixture.ps1 SemanticsFixture Increment         @(@(1), @($max))
V SemanticsFixture.ps1 SemanticsFixture StringEqual       @(@('A', 'a'), @('abc', 'abc'), @('straße', 'STRASSE'), @('', ''), @('a', 'b'))
V SemanticsFixture.ps1 SemanticsFixture StringEqualCase   @(@('A', 'a'), @('abc', 'abc'))
V SemanticsFixture.ps1 SemanticsFixture StringNotEqual    @(@('A', 'a'), @('a', 'b'))
V SemanticsFixture.ps1 SemanticsFixture StringLess        @(@('a', 'B'), @('B', 'a'), @('a', 'a'), @('A', 'a'))

# Pwsh consumer: FindProfile from setup.ps1's managed host
$profileFiles = [string[]]@('/data/files/notes.txt', '/data/files/PROFILE.PS1', '/data/files/Profile.ps1')
V PwshFindProfileFixture.ps1 PwshNativeHost FindProfile @(@($profileFiles, 0, 'none'), @($profileFiles, 2, 'none'), @([string[]]@('/a/b.ps1'), 0, 'none'), @([string[]]@(), 0, 'none'), @($profileFiles, 3, 'none'), @([string[]]@('Profile.ps1x', 'xProfile.ps1'), 0, 'none'))

# Loops: foreach, break and continue
V LoopsFixture.ps1 LoopsFixture SumForeach               @(@(, [int[]]@(1, 2, 3)), @(, [int[]]@()), @(, $null), @(, [int[]]@($max, 1)))
V LoopsFixture.ps1 LoopsFixture LastForeachValue         @(@(, [int[]]@(4, 5, 6)), @(, [int[]]@()), @(, $null))
V LoopsFixture.ps1 LoopsFixture FirstNegativeIndex       @(@(, [int[]]@(3, -1, -2)), @(, [int[]]@(1, 2)), @(, [int[]]@()))
V LoopsFixture.ps1 LoopsFixture SumSkippingOdd           @(@(, [int[]]@(1, 2, 3, 4)), @(, [int[]]@(1, 3)), @(, [int[]]@()))
V LoopsFixture.ps1 LoopsFixture ForContinueStillIterates @(@(0), @(1), @(10))
V LoopsFixture.ps1 LoopsFixture WhileContinue            @(@(0), @(5), @(10))
V LoopsFixture.ps1 LoopsFixture NestedBreakInner         @(@(3, 5), @(2, 1), @(0, 4))
V LoopsFixture.ps1 LoopsFixture BreakFromTry             @(@(, [int[]]@(1, 2, 0, 3)), @(, [int[]]@(0)), @(, [int[]]@(5)))
V LoopsFixture.ps1 LoopsFixture AverageDoubles           @(@(, [double[]]@(1.0, 2.0, 4.0)), @(, [double[]]@()))
V LoopsFixture.ps1 LoopsFixture CountChars               @(@(, [string[]]@('ab', 'cde', '')), @(, [string[]]@()))
V SemanticsFixture.ps1 SemanticsFixture CompoundInt    @(@(1, 2), @(-5, 3), @($max, 1))
V SemanticsFixture.ps1 SemanticsFixture CompoundDivide @(@(7, 2), @(5, 2), @(1, 0))
V SemanticsFixture.ps1 SemanticsFixture Concat         @(@('a', 'b'), @('', ''))

# Classes: fields, constructors, initializers, classes using each other, bitwise operators
V ClassesFixture.ps1 ClassesFixture UseInstance @(@(1, 2), @(0, 0), @($max, 1))
V ClassesFixture.ps1 ClassesFixture DefaultCell @(, @())
V ClassesFixture.ps1 ClassesFixture PackedCell  @(@(5, 1), @(0, 0), @(-1, 2))
V ClassesFixture.ps1 ClassesFixture SumCells    @(@(0), @(1), @(5))
V ClassesFixture.ps1 ClassesFixture PaletteAt   @(@(0), @(2), @(3), @(-1))
V ClassesFixture.ps1 ClassesFixture BaseValue   @(, @())
V ClassesFixture.ps1 ClassesFixture Bits        @(@(12, 10), @(0, -1), @($max, $min))
V ClassesFixture.ps1 ClassesFixture Shifts      @(@(1, 0), @(1, 31), @(-8, 2), @(5, 33), @(-1, 1))
V ClassesFixture.ps1 ClassesFixture SetLast     @(@([int[]]@(1, 2, 3), 9), @([int[]]@(4, 5), 7))
