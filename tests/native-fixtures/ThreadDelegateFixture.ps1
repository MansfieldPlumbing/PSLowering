class ThreadDelegateFixture {
    ThreadDelegateFixture() { }
    [int] $Result
    [void] Run() { $this.Result = 42 }
    [Threading.ThreadStart] Worker() {
        return [Threading.ThreadStart]$this.GetType().GetMethod('Run').CreateDelegate([Threading.ThreadStart], $this)
    }
    [void] StartAndJoin() {
        [Threading.Thread] $thread = [Threading.Thread]::new($this.Worker())
        $thread.Start()
        $thread.Join()
    }
    static [int] Main() {
        foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($assembly.GetName().Name -eq 'System.Management.Automation') { return 1 }
        }
        [ThreadDelegateFixture] $worker = [ThreadDelegateFixture]::new()
        $worker.StartAndJoin()
        if ($worker.Result -ne 42) { return 2 }
        return 0
    }}
