param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [ValidateRange(1, 500)][int]$Iterations = 120
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-Stability([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error title=Windows worker stability::$Message" }
        throw "Worker stability assertion failed: $Message"
    }
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
    $emptyDataRoot = Join-Path $testRoot 'empty-codex'
    [void][IO.Directory]::CreateDirectory((Join-Path $emptyDataRoot 'sessions'))
    $killHandle = New-UsageWorkerJob
    $coldDurations = [Collections.Generic.List[double]]::new()
    for ($round = 0; $round -lt 20; $round++) {
        $roundWatch = [Diagnostics.Stopwatch]::StartNew()
        $workerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') `
            -DataDirectory $emptyDataRoot -Generation ([guid]::NewGuid().ToString('N')) -WorkerJobHandle $killHandle
        do {
            $received = Receive-UsageScanProcess -Job $workerJob -TimeoutSeconds 10
            if ($received.Status -ceq 'pending') { Start-Sleep -Milliseconds 10 }
        } while ($received.Status -ceq 'pending')
        $roundWatch.Stop()
        Assert-Stability ($received.Status -ceq 'completed' -and $received.Snapshot.Classification -ceq 'empty') "cold worker $round did not return a validated empty result."
        $coldDurations.Add($roundWatch.Elapsed.TotalSeconds)
        $workerProcess = $workerJob.Process
        $script:UsageWorkerHost = $null
        Assert-Stability (Stop-UsageWorkerProcess -Process $workerProcess) "cold worker $round did not stop."
        $workerJob = $null
    }
    $sortedColdDurations = @($coldDurations.ToArray() | Sort-Object)
    $coldP95 = $sortedColdDurations[[int]([math]::Ceiling($sortedColdDurations.Count * 0.95) - 1)]
    # ponytail: local endpoint security varies; GitHub's pinned Windows image is the release performance reference.
    $coldP95Limit = if ($env:GITHUB_ACTIONS -eq 'true') { 0.75 } else { 3.0 }
    Assert-Stability ($coldP95 -lt $coldP95Limit) ('95th-percentile empty-input cold start exceeded {0:N2} seconds: {1:N3}s.' -f $coldP95Limit, $coldP95)
    $demoLine = [IO.File]::ReadAllText((Join-Path $package 'fixtures\contract\v1\inputs\demo.jsonl')).Trim()
    $tailPadding = (' ' * 262144) + "`n"
    for ($index = 0; $index -lt 30; $index++) {
        [IO.File]::WriteAllText(
            (Join-Path $sessions ('session-{0:D2}.jsonl' -f $index)),
            $tailPadding + $demoLine + "`n",
            [Text.UTF8Encoding]::new($false))
    }
    $hostProcess = [Diagnostics.Process]::GetCurrentProcess()
    $workerIds = [Collections.Generic.List[int]]::new()
    $durations = [Collections.Generic.List[double]]::new()
    $workerProcess = $null
    $workerCpuBaseline = 0.0
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
        if ($null -eq $workerProcess) { $workerProcess = $workerJob.Process }
        $workerIds.Add($workerJob.Process.Id)
        $roundPeakBytes = 0L
        $received = $null
        do {
            try {
                $workerJob.Process.Refresh()
                $roundPeakBytes = [math]::Max($roundPeakBytes, [long]$workerJob.Process.PeakWorkingSet64)
            }
            catch { }
            $received = Receive-UsageScanProcess -Job $workerJob -TimeoutSeconds 10
            if ($received.Status -ceq 'pending') { Start-Sleep -Milliseconds 50 }
        } while ($received.Status -ceq 'pending')
        $roundWatch.Stop()
        Assert-Stability ($received.Status -ceq 'completed' -and -not $received.ProcessExited) "refresh $round did not complete on a reusable worker."
        $workerJob = $null
        if ($measured) {
            $durations.Add($roundWatch.Elapsed.TotalSeconds)
            $workerPeakBytes = [math]::Max($workerPeakBytes, $roundPeakBytes)
        }
        elseif ($round -eq 9) {
            [GC]::Collect()
            [GC]::WaitForPendingFinalizers()
            $hostProcess.Refresh()
            $baselineHandles = $hostProcess.HandleCount
            $baselineMemory = $hostProcess.PrivateMemorySize64
            $baselineCpuSeconds = $hostProcess.TotalProcessorTime.TotalSeconds
            $workerProcess.Refresh()
            $workerCpuBaseline = $workerProcess.TotalProcessorTime.TotalSeconds
        }
    }
    $uniqueWorkerIds = @($workerIds.ToArray() | Sort-Object -Unique)
    Assert-Stability ($uniqueWorkerIds.Count -eq 1) 'refreshes must reuse exactly one isolated worker process.'
    $workerProcess.Refresh()
    $workerCpuSeconds = [math]::Max(0, $workerProcess.TotalProcessorTime.TotalSeconds - $workerCpuBaseline)
    Close-UsageWorkerJob -Handle $killHandle
    $killHandle = [IntPtr]::Zero
    Assert-Stability ($workerProcess.WaitForExit(2000)) 'closing the parent job handle must stop the reusable worker.'
    $workerProcess.Dispose()
    $workerProcess = $null
    $script:UsageWorkerHost = $null
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $hostProcess.Refresh()
    $alive = 0
    foreach ($id in $uniqueWorkerIds) {
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
    $metricsLine = 'Stability metrics: coldP95={0:N3}s; refreshP95={1:N3}s; handles={2:+#;-#;0}; private={3:N1}MiB; workerPeak={4:N1}MiB; parentCpu={5:N2}%; combinedCpu={6:N2}%.' -f
        $coldP95, $p95, ($hostProcess.HandleCount - $baselineHandles), (($hostProcess.PrivateMemorySize64 - $baselineMemory) / 1MB),
        ($workerPeakBytes / 1MB), $parentCpuPercent, $combinedCpuPercent
    Write-Output $metricsLine
    if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::notice title=Windows worker stability::$metricsLine" }
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
