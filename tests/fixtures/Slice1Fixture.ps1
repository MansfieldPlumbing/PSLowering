class Slice1Fixture {
    static [int] GetAnswer() {
        return 42
    }

    static [bool] GetFalse() {
        return $false
    }

    static [string] GetGreeting() {
        return "hello"
    }

    static [void] DoNothing() {
        return
    }

    [int] GetInstanceVal() {
        return 100
    }
}
