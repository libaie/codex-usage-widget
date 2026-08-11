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
    [IO.File]::Copy(
        (Join-Path $package 'fixtures\contract\v1\inputs\demo.jsonl'),
        (Join-Path $sessions 'rollout-66666666-6666-6666-6666-666666666666.jsonl'))
    $killHandle = New-UsageWorkerJob
    $hostProcess = [Diagnostics.Process]::GetCurrentProcess()
    $baselineHandles = $hostProcess.HandleCount
    $baselineMemory = $hostProcess.WorkingSet64
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $workerIds = [Collections.Generic.List[int]]::new()

    for ($iteration = 0; $iteration -lt $Iterations; $iteration++) {
        $generation = [guid]::NewGuid().ToString('N')
        $workerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') `
            -DataDirectory $dataRoot -Generation $generation -WorkerJobHandle $killHandle
        $workerIds.Add($workerJob.Process.Id)
        do {
            $received = Receive-UsageScanProcess -Job $workerJob -TimeoutSeconds 10
            if ($received.Status -ceq 'pending') { Start-Sleep -Milliseconds 20 }
        } while ($received.Status -ceq 'pending')
        Assert-Stability ($received.Status -ceq 'completed' -and $received.ProcessExited) "refresh $iteration did not complete cleanly."
        $workerJob = $null
    }
    $watch.Stop()
    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
    $hostProcess.Refresh()
    $alive = 0
    foreach ($id in $workerIds) {
        try { $probe = [Diagnostics.Process]::GetProcessById($id); if (-not $probe.HasExited) { $alive++ }; $probe.Dispose() } catch { }
    }
    $workerRoot = Join-Path $testRoot 'CodexUsageWidget\worker'
    $residualFiles = if ([IO.Directory]::Exists($workerRoot)) { [IO.Directory]::GetFiles($workerRoot).Count } else { 0 }
    Assert-Stability ($alive -eq 0 -and $residualFiles -eq 0) 'workers or result files remained after refresh completion.'
    Assert-Stability ($hostProcess.HandleCount -le $baselineHandles + 12) 'parent handle count grew across refreshes.'
    Assert-Stability ($hostProcess.WorkingSet64 -le $baselineMemory + 67108864) 'parent working set grew by more than 64 MiB.'
    Assert-Stability (($watch.Elapsed.TotalSeconds / $Iterations) -lt 2) 'average refresh exceeded two seconds.'
}
finally {
    if ($null -ne $workerJob) {
        try { if (-not $workerJob.Process.HasExited) { $workerJob.Process.Kill(); $workerJob.Process.WaitForExit() } } catch { }
        try { $workerJob.Process.Dispose() } catch { }
    }
    if ($killHandle -ne [IntPtr]::Zero) { try { Close-UsageWorkerJob -Handle $killHandle } catch { } }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

Write-Output "Worker stability self-test passed ($Iterations refreshes)."
