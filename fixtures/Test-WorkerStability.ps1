param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [ValidateRange(1, 500)][int]$Iterations = 120
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-Stability([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Worker stability assertion failed: $Message" }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
. (Join-Path $package 'CodexUsageWidget.ps1') -SelfTest | Out-Null
$savedLocalAppData = $env:LOCALAPPDATA
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-worker-stability-' + [guid]::NewGuid().ToString('N'))
$workerJob = $null
$killHandle = [IntPtr]::Zero
try {
    $env:LOCALAPPDATA = $testRoot
    $dataRoot = Join-Path $testRoot 'codex'
    $sessions = Join-Path $dataRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($sessions)
    $demoLine = [IO.File]::ReadAllText((Join-Path $package 'fixtures\contract\v1\inputs\demo.jsonl')).Trim()
    $tailPadding = (' ' * 262144) + "`n"
    for ($index = 0; $index -lt 30; $index++) {
        [IO.File]::WriteAllText(
            (Join-Path $sessions ('session-{0:D2}.jsonl' -f $index)),
            $tailPadding + $demoLine + "`n",
            [Text.UTF8Encoding]::new($false))
    }
    $killHandle = New-UsageWorkerJob
    $hostProcess = [Diagnostics.Process]::GetCurrentProcess()
    $workerIds = [Collections.Generic.List[int]]::new()
    $durations = [Collections.Generic.List[double]]::new()
    $workerCpuSeconds = 0.0
    $workerPeakBytes = 0L
    $baselineHandles = 0
    $baselineMemory = 0L
    $baselineCpuSeconds = 0.0

    for ($round = 0; $round -lt (10 + $Iterations); $round++) {
        $measured = $round -ge 10
        $roundWatch = [Diagnostics.Stopwatch]::StartNew()
        $generation = [guid]::NewGuid().ToString('N')
        $workerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') `
            -DataDirectory $dataRoot -Generation $generation -WorkerJobHandle $killHandle
        $workerIds.Add($workerJob.Process.Id)
        $roundPeakBytes = 0L
        $roundCpuSeconds = 0.0
        while (-not $workerJob.Process.WaitForExit(250)) {
            try {
                $workerJob.Process.Refresh()
                $roundPeakBytes = [math]::Max($roundPeakBytes, [long]$workerJob.Process.PeakWorkingSet64)
            }
            catch { }
        }
        try {
            $workerJob.Process.Refresh()
            $roundPeakBytes = [math]::Max($roundPeakBytes, [long]$workerJob.Process.PeakWorkingSet64)
            $roundCpuSeconds = [math]::Max($roundCpuSeconds, $workerJob.Process.TotalProcessorTime.TotalSeconds)
        }
        catch { }
        $received = Receive-UsageScanProcess -Job $workerJob -TimeoutSeconds 10
        $roundWatch.Stop()
        Assert-Stability ($received.Status -ceq 'completed' -and $received.ProcessExited) "refresh $round did not complete cleanly."
        $workerJob = $null
        if ($measured) {
            $durations.Add($roundWatch.Elapsed.TotalSeconds)
            $workerCpuSeconds += $roundCpuSeconds
            $workerPeakBytes = [math]::Max($workerPeakBytes, $roundPeakBytes)
        }
        elseif ($round -eq 9) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $hostProcess.Refresh()
            $baselineHandles = $hostProcess.HandleCount
            $baselineMemory = $hostProcess.PrivateMemorySize64
            $baselineCpuSeconds = $hostProcess.TotalProcessorTime.TotalSeconds
        }
    }
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $hostProcess.Refresh()
    $alive = 0
    foreach ($id in $workerIds) {
        try { $probe = [Diagnostics.Process]::GetProcessById($id); if (-not $probe.HasExited) { $alive++ }; $probe.Dispose() } catch { }
    }
    $workerRoot = Join-Path $testRoot 'CodexUsageWidget\worker'
    $residualFiles = if ([IO.Directory]::Exists($workerRoot)) {
        @([IO.Directory]::GetFiles($workerRoot) | Where-Object { [IO.Path]::GetFileName($_) -cne 'scan-worker.ps1' }).Count
    } else { 0 }
    $residualDirectories = if ([IO.Directory]::Exists($workerRoot)) { [IO.Directory]::GetDirectories($workerRoot).Count } else { 0 }
    $sortedDurations = @($durations.ToArray() | Sort-Object)
    $p95 = $sortedDurations[[int]([math]::Ceiling($sortedDurations.Count * 0.95) - 1)]
    $parentCpuSeconds = [math]::Max(0, $hostProcess.TotalProcessorTime.TotalSeconds - $baselineCpuSeconds)
    $simulatedSeconds = 15.0 * $Iterations
    $parentCpuPercent = 100.0 * $parentCpuSeconds / $simulatedSeconds
    $combinedCpuPercent = 100.0 * ($parentCpuSeconds + $workerCpuSeconds) / $simulatedSeconds
    Write-Output ('Stability metrics: p95={0:N3}s; handles={1:+#;-#;0}; private={2:N1}MiB; workerPeak={3:N1}MiB; parentCpu={4:N2}%; combinedCpu={5:N2}%.' -f
        $p95, ($hostProcess.HandleCount - $baselineHandles), (($hostProcess.PrivateMemorySize64 - $baselineMemory) / 1MB),
        ($workerPeakBytes / 1MB), $parentCpuPercent, $combinedCpuPercent)
    Assert-Stability ($alive -eq 0 -and $residualFiles -eq 0 -and $residualDirectories -eq 0) 'workers or private channel paths remained after refresh completion.'
    Assert-Stability ($hostProcess.HandleCount -le $baselineHandles + 8) 'parent handle count grew by more than eight after warmup.'
    Assert-Stability ($hostProcess.PrivateMemorySize64 -le $baselineMemory + 20971520) 'parent private memory grew by more than 20 MiB after warmup.'
    Assert-Stability ($workerPeakBytes -le 134217728) ('a worker exceeded 128 MiB peak working set: {0:N1} MiB.' -f ($workerPeakBytes / 1MB))
    Assert-Stability ($p95 -lt 2) ('95th-percentile refresh time exceeded two seconds: {0:N3}s.' -f $p95)
    Assert-Stability ($parentCpuPercent -lt 1) ('parent CPU exceeded one percent of one core at a 15-second refresh interval: {0:N2}%.' -f $parentCpuPercent)
    Assert-Stability ($combinedCpuPercent -lt 5) ('combined parent and worker CPU exceeded five percent of one core: {0:N2}%.' -f $combinedCpuPercent)
}
finally {
    if ($null -ne $workerJob) {
        try { if (-not $workerJob.Process.HasExited) { $workerJob.Process.Kill(); $workerJob.Process.WaitForExit() } } catch { }
        try { $workerJob.Process.Dispose() } catch { }
    }
    if ($killHandle -ne [IntPtr]::Zero) { try { Close-UsageWorkerJob -Handle $killHandle } catch { } }
    $workerScriptPath = Join-Path $testRoot 'CodexUsageWidget\worker\scan-worker.ps1'
    if ([IO.File]::Exists($workerScriptPath)) { [IO.File]::Delete($workerScriptPath) }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

Write-Output "Worker stability self-test passed ($Iterations refreshes)."
