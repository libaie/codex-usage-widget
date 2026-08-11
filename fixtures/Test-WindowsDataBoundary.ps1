param([Parameter(Mandatory)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-Boundary([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Windows data-boundary assertion failed: $Message" }
}

function Get-FixtureSnapshot([string]$TestRoot, [string]$Package, [string]$Name) {
    $dataRoot = Join-Path $TestRoot ($Name + '-codex')
    $sessions = Join-Path $dataRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($sessions)
    [IO.File]::Copy(
        (Join-Path $Package ('fixtures\contract\v1\inputs\' + $Name + '.jsonl')),
        (Join-Path $sessions 'rollout-11111111-1111-1111-1111-111111111111.jsonl'))
    return Get-CodexUsageSnapshot -DataDirectory $dataRoot
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
. (Join-Path $package 'CodexUsageWidget.ps1') -SelfTest | Out-Null

$savedLocalAppData = $env:LOCALAPPDATA
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-data-boundary-' + [guid]::NewGuid().ToString('N'))
$worker = $null
try {
    $env:LOCALAPPDATA = $testRoot
    $stateRoot = Join-Path $testRoot 'CodexUsageWidget'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $preferencePath = Join-Path $stateRoot 'preferences.json'
    $invalidBytes = [Text.Encoding]::UTF8.GetBytes('{bad json')
    [IO.File]::WriteAllBytes($preferencePath, $invalidBytes)

    $preferences = Get-WidgetPreferences
    Assert-Boundary ($preferences.PSObject.Properties['StoreStatus'].Value -ceq 'invalid') 'an invalid preference store must be identified explicitly.'
    $saved = Save-WidgetPreferences -Left 1 -Top 2 -Monitor 'test' -Theme 0
    Assert-Boundary (-not $saved) 'an invalid preference store must reject implicit writes.'
    Assert-Boundary (([Convert]::ToBase64String([IO.File]::ReadAllBytes($preferencePath))) -ceq ([Convert]::ToBase64String($invalidBytes))) 'an invalid preference store must remain byte-identical.'

    $ledgerPath = Join-Path $stateRoot 'cache-token-ledger.json'
    [IO.File]::WriteAllBytes($ledgerPath, $invalidBytes)
    $script:CacheTokenLedger = $null
    $null = Update-CumulativeCacheTokens @([pscustomobject]@{ Id = 'session'; CacheHitTokens = 8; CacheMissTokens = 2 })
    Assert-Boundary ($script:CacheTokenLedger.StoreStatus -ceq 'invalid') 'an invalid cache ledger must be identified explicitly.'
    Assert-Boundary (([Convert]::ToBase64String([IO.File]::ReadAllBytes($ledgerPath))) -ceq ([Convert]::ToBase64String($invalidBytes))) 'an invalid cache ledger must remain byte-identical.'

    $reminderPath = Join-Path $stateRoot 'reminders.json'
    [IO.File]::WriteAllBytes($reminderPath, $invalidBytes)
    $script:ReminderGateCache = $null
    $reminders = Get-ReminderGateState
    Assert-Boundary ($reminders.StoreStatus -ceq 'invalid') 'an invalid reminder store must be identified explicitly.'
    $reminders.SentKeys = @('primary|4102444800|20')
    Assert-Boundary (-not (Save-ReminderGateState $reminders)) 'an invalid reminder store must reject implicit writes.'
    Assert-Boundary (([Convert]::ToBase64String([IO.File]::ReadAllBytes($reminderPath))) -ceq ([Convert]::ToBase64String($invalidBytes))) 'an invalid reminder store must remain byte-identical.'
    Assert-Boundary (Reset-WidgetLocalState -Language 'zh-CN') 'an explicit reset must replace all three local stores, including invalid files.'
    $resetPreferences = Get-WidgetPreferences
    $script:CacheTokenLedger = $null
    $null = Update-CumulativeCacheTokens @()
    $script:ReminderGateCache = $null
    Assert-Boundary ($resetPreferences.Theme -eq 7 -and $resetPreferences.Language -ceq 'zh-CN' -and
        $resetPreferences.StoreStatus -ceq 'valid' -and $script:CacheTokenLedger.StoreStatus -ceq 'valid' -and
        $script:CacheTokenLedger.Sessions.Count -eq 0 -and (Get-ReminderGateState).StoreStatus -ceq 'valid' -and
        @((Get-ReminderGateState).SentKeys).Count -eq 0) 'an explicit reset must publish only validated defaults after all writes succeed.'

    $partial = Get-FixtureSnapshot $testRoot $package 'partial'
    Assert-Boundary ($partial.Classification -ceq 'partial') 'valid usage plus malformed JSON must classify as partial.'
    Assert-Boundary ($partial.Metrics.MalformedLineCount -eq 1 -and $null -ne $partial.State) 'partial results must retain valid state and report malformed lines.'

    $unsupported = Get-FixtureSnapshot $testRoot $package 'unsupported'
    Assert-Boundary ($unsupported.Classification -ceq 'unsupported' -and $unsupported.Metrics.UnknownEventCount -eq 1) 'unknown schema data must remain distinct from empty data.'
    $malformed = Get-FixtureSnapshot $testRoot $package 'all-malformed'
    Assert-Boundary ($malformed.Classification -ceq 'error' -and $malformed.Metrics.MalformedLineCount -eq 1) 'all-malformed data must classify as an error.'
    $empty = Get-FixtureSnapshot $testRoot $package 'empty'
    Assert-Boundary ($empty.Classification -ceq 'empty' -and $empty.Metrics.CandidateLineCount -eq 0) 'an empty file must classify as empty.'
    $overflow = Get-FixtureSnapshot $testRoot $package 'overflow'
    Assert-Boundary ($overflow.Classification -ceq 'partial' -and $overflow.Metrics.InvalidValueCount -eq 1) 'overflowing token data must be retained as a partial observation.'

    $ledgerBaseline = '{"Sessions":[{"Id":"existing","CacheHitTokens":5,"CacheMissTokens":5}]}'
    [IO.File]::WriteAllText($ledgerPath, $ledgerBaseline, [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $null = Update-CumulativeCacheTokens @()
    $persistenceSnapshot = [pscustomobject]@{
        Classification = 'complete'
        State = [pscustomobject]@{
            SessionTokenSnapshots = @([pscustomobject]@{ Id = 'fresh'; CacheHitTokens = 8; CacheMissTokens = 2 })
            TokenDetails = $null
        }
    }
    $ledgerLock = [IO.File]::Open($ledgerPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $persistedSnapshot = Apply-UsageSnapshotPersistence $persistenceSnapshot
    }
    finally { $ledgerLock.Dispose() }
    Assert-Boundary ($null -eq $persistedSnapshot) 'a failed ledger write must not publish unsaved cumulative values.'
    Assert-Boundary ($script:CacheTokenLedger.Sessions.Count -eq 1) ('a failed ledger write must retain only the previously persisted session in memory; count={0}, status={1}, keys={2}.' -f
        $script:CacheTokenLedger.Sessions.Count, $script:CacheTokenLedger.StoreStatus, (@($script:CacheTokenLedger.Sessions.Keys) -join ','))
    Assert-Boundary ($script:CacheTokenLedger.Sessions.ContainsKey('existing')) 'a failed ledger write must retain the previously persisted session identity.'
    Assert-Boundary (-not $script:CacheTokenLedger.Dirty) 'a failed ledger write must not mark unsaved memory as persisted state.'
    Assert-Boundary ([IO.File]::ReadAllText($ledgerPath) -ceq $ledgerBaseline) 'a failed ledger write must leave the persisted ledger byte-identical.'

    $reminderBaseline = '{"SentKeys":[]}'
    [IO.File]::WriteAllText($reminderPath, $reminderBaseline, [Text.UTF8Encoding]::new($false))
    $script:ReminderGateCache = $null
    $null = Get-ReminderGateState
    $reminderLock = [IO.File]::Open($reminderPath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::Read)
    try {
        $reminderRegistered = Register-UsageReminderThreshold -State ([pscustomobject]@{
            Name = 'primary'; RemainingPercent = 10; ResetAt = [datetime]::UtcNow.AddHours(1)
        }) -Threshold 10
    }
    finally { $reminderLock.Dispose() }
    Assert-Boundary (-not $reminderRegistered -and @($script:ReminderGateCache.SentKeys).Count -eq 0) 'a failed reminder write must not publish or retain an unsaved notification gate.'
    Assert-Boundary ([IO.File]::ReadAllText($reminderPath) -ceq $reminderBaseline) 'a failed reminder write must leave the persisted reminder gate byte-identical.'

    $boundedRoot = Join-Path $testRoot 'bounded-sessions'
    [void][IO.Directory]::CreateDirectory($boundedRoot)
    for ($index = 0; $index -lt 40; $index++) {
        $path = Join-Path $boundedRoot ('session-{0:D2}.jsonl' -f $index)
        [IO.File]::WriteAllText($path, '')
        [IO.File]::SetLastWriteTimeUtc($path, ([datetime]'2026-08-11T00:00:00Z').AddMinutes($index))
    }
    $bounded = Get-BoundedSessionFiles -SessionsPath $boundedRoot -MaxFiles 30 -MaxEntries 100 -DeadlineUtc ([datetime]::UtcNow.AddSeconds(2))
    Assert-Boundary ($bounded.Files.Count -eq 30 -and $bounded.Files[0].Name -ceq 'session-39.jsonl' -and $bounded.Files[29].Name -ceq 'session-10.jsonl') 'bounded discovery must return only the thirty newest files.'
    $expired = Get-BoundedSessionFiles -SessionsPath $boundedRoot -MaxFiles 30 -MaxEntries 100 -DeadlineUtc ([datetime]::UtcNow.AddSeconds(-1))
    Assert-Boundary ($expired.Truncated -and $expired.Files.Count -eq 0) 'an expired discovery deadline must stop before enumeration.'

    $defaultLimitRoot = Join-Path $testRoot 'default-limit-sessions'
    [void][IO.Directory]::CreateDirectory($defaultLimitRoot)
    for ($index = 0; $index -lt 4100; $index++) {
        [IO.File]::WriteAllText((Join-Path $defaultLimitRoot ('entry-{0:D4}.jsonl' -f $index)), '')
    }
    $defaultLimit = Get-BoundedSessionFiles -SessionsPath $defaultLimitRoot -MaxFiles 30 -DeadlineUtc ([datetime]::UtcNow.AddSeconds(8))
    Assert-Boundary ($defaultLimit.EntriesVisited -eq 4100 -and -not $defaultLimit.Truncated) 'the default discovery budget must include all entries through the 10,000-item boundary.'

    $splitRoot = Join-Path $testRoot 'split-candidates'
    $splitSessions = Join-Path $splitRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($splitSessions)
    $splitNow = [datetime]::UtcNow
    $splitDemo = [IO.File]::ReadAllText((Join-Path $package 'fixtures\contract\v1\inputs\demo.jsonl'))
    $indexRows = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt 60; $index++) {
        $id = '00000000-0000-0000-0000-{0:D12}' -f ($index + 1)
        $path = Join-Path $splitSessions ('rollout-' + $id + '.jsonl')
        [IO.File]::WriteAllText($path, $splitDemo)
        [IO.File]::SetLastWriteTimeUtc($path, $splitNow.AddSeconds(-$index))
        if ($index -ge 30) { $indexRows.Add('{"id":"' + $id + '","thread_name":"task ' + $index + '"}') }
    }
    [IO.File]::WriteAllLines((Join-Path $splitRoot 'session_index.jsonl'), $indexRows)
    $splitSnapshot = Get-CodexUsageSnapshot -DataDirectory $splitRoot -ReadOnly
    Assert-Boundary (@($splitSnapshot.State.SessionTokenSnapshots).Count -eq 30 -and
        @($splitSnapshot.State.ActiveTasks).Count -eq 30) 'usage and named activity candidates must be selected independently and read at most sixty files.'

    $outside = Join-Path $testRoot 'outside-sessions'
    [void][IO.Directory]::CreateDirectory($outside)
    [IO.File]::WriteAllText((Join-Path $outside 'outside.jsonl'), '{}')
    $junction = Join-Path $boundedRoot 'linked-outside'
    $junctionCreated = $false
    try {
        $null = New-Item -ItemType Junction -Path $junction -Target $outside -ErrorAction Stop
        $junctionCreated = $true
        $contained = Get-BoundedSessionFiles -SessionsPath $boundedRoot -MaxFiles 50 -MaxEntries 100 -DeadlineUtc ([datetime]::UtcNow.AddSeconds(2))
        Assert-Boundary ($contained.RejectedPathCount -eq 1 -and @($contained.Files | Where-Object Name -eq 'outside.jsonl').Count -eq 0) 'junction targets must be rejected before file reads.'
    }
    catch [System.Management.Automation.PSNotSupportedException] { }
    finally {
        if ($junctionCreated -and [IO.Directory]::Exists($junction)) { [IO.Directory]::Delete($junction, $false) }
    }

    $indexPath = Join-Path $testRoot 'session_index.jsonl'
    $earlyId = '22222222-2222-2222-2222-222222222222'
    $lateId = '33333333-3333-3333-3333-333333333333'
    $indexText = '{"id":"' + $earlyId + '","thread_name":"early"}' + "`n" +
        ('x' * 1100000) + "`n" +
        '{"id":"' + $lateId + '","thread_name":"late"}' + "`n"
    [IO.File]::WriteAllText($indexPath, $indexText, [Text.UTF8Encoding]::new($false))
    $indexBytesRead = 0L
    $names = Read-TaskNameIndex -Path $indexPath -MaxBytes 1048576 -BytesRead ([ref]$indexBytesRead)
    Assert-Boundary ($indexBytesRead -le 1048576 -and $names[$lateId] -ceq 'late' -and -not $names.ContainsKey($earlyId)) 'task-name lookup must read only the bounded tail of a growing index.'

    $workerData = Join-Path $testRoot 'worker-codex'
    $workerSessions = Join-Path $workerData 'sessions'
    [void][IO.Directory]::CreateDirectory($workerSessions)
    $demoLine = [IO.File]::ReadAllText((Join-Path $package 'fixtures\contract\v1\inputs\demo.jsonl')).Trim()
    for ($index = 0; $index -lt 30; $index++) {
        [IO.File]::WriteAllText(
            (Join-Path $workerSessions ('session-{0:D2}.jsonl' -f $index)),
            ('x' * 300000) + "`n" + $demoLine + "`n",
            [Text.UTF8Encoding]::new($false))
    }
    $workerRoot = Join-Path $stateRoot 'worker'
    [void][IO.Directory]::CreateDirectory($workerRoot)
    $generation = [guid]::NewGuid().ToString('N')
    $stateHashes = @{}
    foreach ($path in $preferencePath, $ledgerPath, $reminderPath) {
        $stateHashes[$path] = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($path)))
    }
    $workerWatch = [Diagnostics.Stopwatch]::StartNew()
    $workerEnvironmentNames = 'CODEX_WIDGET_DATA_DIRECTORY', 'CODEX_WIDGET_RESULT_PATH', 'CODEX_WIDGET_GENERATION'
    $workerEnvironmentBefore = @{}
    foreach ($name in $workerEnvironmentNames) { $workerEnvironmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) }
    $workerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') -DataDirectory $workerData -Generation $generation
    $channelDirectory = Join-Path $workerRoot ('CodexUsageWidget-scan-' + $generation)
    $workerOutput = Join-Path $channelDirectory 'result.json'
    Assert-Boundary ($workerJob.OutputPath -ceq $workerOutput -and $workerJob.ChannelDirectory -ceq $channelDirectory) 'each scan must bind output to its own private channel directory.'
    $arguments = [string]$workerJob.Process.StartInfo.Arguments
    Assert-Boundary ($arguments -notlike ('*' + $workerData + '*') -and $arguments -notlike ('*' + $workerOutput + '*') -and
        $arguments -notlike ('*' + $generation + '*')) 'data, result, and generation values must not appear in the worker command line.'
    foreach ($name in $workerEnvironmentNames) {
        Assert-Boundary ([Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) -ceq $workerEnvironmentBefore[$name]) 'the parent environment must be restored immediately after worker launch.'
    }
    $channelAcl = Get-Acl -LiteralPath $channelDirectory
    $channelRules = @($channelAcl.Access | Where-Object { $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow })
    Assert-Boundary ($channelAcl.AreAccessRulesProtected -and $channelRules.Count -eq 1 -and
        $channelRules[0].IdentityReference.Value -ceq [Security.Principal.WindowsIdentity]::GetCurrent().Name) 'the per-round channel ACL must allow only the current user.'
    $worker = $workerJob.Process
    $workerCompleted = $worker.WaitForExit(12000)
    if (-not $workerCompleted) {
        try { $worker.Kill(); $worker.WaitForExit() } catch { }
    }
    Assert-Boundary $workerCompleted 'the isolated worker must finish inside its parent deadline.'
    Assert-Boundary ([IO.File]::Exists($workerOutput) -and ([IO.FileInfo]$workerOutput).Length -le 262144) 'the worker result must fit the 256 KiB protocol limit.'
    $workerResult = [IO.File]::ReadAllText($workerOutput) | ConvertFrom-Json -ErrorAction Stop
    Assert-Boundary ($workerResult.schemaVersion -eq 1 -and $workerResult.generation -ceq $generation -and $workerResult.snapshot.Classification -ceq 'complete') 'the worker result must bind schema, generation, and normalized snapshot.'
    $nestedForgery = $workerResult | ConvertTo-Json -Depth 16 | ConvertFrom-Json
    $nestedForgery.snapshot.State.TokenDetails | Add-Member -NotePropertyName Unexpected -NotePropertyValue 1
    $nestedForgeryPath = Join-Path $workerRoot 'forged-nested.json'
    [IO.File]::WriteAllText($nestedForgeryPath, ($nestedForgery | ConvertTo-Json -Depth 16 -Compress))
    Assert-Boundary ($null -eq (Read-UsageScanResult -Path $nestedForgeryPath -ExpectedGeneration $generation)) 'the parent must reject unknown nested snapshot fields before state or persistence can observe them.'
    Assert-Boundary ($null -ne (Get-Command Write-UsageScanResult -ErrorAction SilentlyContinue)) 'the worker must use one pre-serialization snapshot gate.'
    $producerPath = Join-Path $workerRoot 'producer-rejected.json'
    Assert-Boundary (-not (Write-UsageScanResult -Snapshot $nestedForgery.snapshot -Generation $generation -Path $producerPath) -and
        -not [IO.File]::Exists($producerPath)) 'the producer must reject an invalid snapshot before serialization or any result write.'
    $received = Receive-UsageScanProcess -Job $workerJob -TimeoutSeconds 10
    $workerWatch.Stop()
    Assert-Boundary ($received.Status -ceq 'completed' -and $received.ProcessExited -and -not [IO.File]::Exists($workerOutput)) 'the parent must reap a naturally completed worker exactly once.'
    $validatedSnapshot = $received.Snapshot
    Assert-Boundary ($validatedSnapshot.Classification -ceq 'complete' -and $null -ne $validatedSnapshot.State -and
        @($validatedSnapshot.State.SessionTokenSnapshots).Count -eq 30 -and $workerWatch.Elapsed.TotalSeconds -lt 10) 'the parent must validate thirty bounded session files within the deadline.'
    $forgedPath = Join-Path $workerRoot 'forged.json'
    [IO.File]::WriteAllText($forgedPath, '{"schemaVersion":1,"generation":"00000000000000000000000000000000","snapshot":{}}')
    Assert-Boundary ($null -eq (Read-UsageScanResult -Path $forgedPath -ExpectedGeneration $generation)) 'the parent must reject a stale generation.'
    $oversizedPath = Join-Path $workerRoot 'oversized.json'
    [IO.File]::WriteAllBytes($oversizedPath, [byte[]]::new(262145))
    Assert-Boundary ($null -eq (Read-UsageScanResult -Path $oversizedPath -ExpectedGeneration $generation)) 'the parent must reject a result over 256 KiB before parsing.'

    $timeoutInfo = [Diagnostics.ProcessStartInfo]::new()
    $timeoutInfo.FileName = (Join-Path $PSHOME 'powershell.exe')
    $timeoutInfo.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
    $timeoutInfo.UseShellExecute = $false
    $timeoutInfo.CreateNoWindow = $true
    $timeoutInfo.RedirectStandardOutput = $true
    $timeoutInfo.RedirectStandardError = $true
    $timeoutProcess = [Diagnostics.Process]::Start($timeoutInfo)
    $timeoutChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-55555555555555555555555555555555'
    [void][IO.Directory]::CreateDirectory($timeoutChannel)
    $timeoutJob = [pscustomobject]@{
        Process = $timeoutProcess
        Generation = '55555555555555555555555555555555'
        OutputPath = (Join-Path $timeoutChannel 'result.json')
        ChannelDirectory = $timeoutChannel
        StartedAtUtc = [datetime]::UtcNow.AddSeconds(-11)
    }
    $timedOut = Receive-UsageScanProcess -Job $timeoutJob -TimeoutSeconds 10
    Assert-Boundary ($timedOut.Status -ceq 'timeout' -and $timedOut.ProcessExited) 'a timed-out worker must be killed and reaped through its original process object.'

    $deadlineProbePath = Join-Path $testRoot 'deadline-probe.ps1'
    $deadlineProbeText = @'
param([Parameter(Mandatory)][string]$Package)
. (Join-Path $Package 'CodexUsageWidget.ps1') -SelfTest | Out-Null
$deadline = New-UsageWorkerDeadline
Start-Sleep -Seconds 30
'@
    [IO.File]::WriteAllText($deadlineProbePath, $deadlineProbeText, [Text.UTF8Encoding]::new($false))
    $deadlineInfo = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'powershell.exe'))
    $deadlineInfo.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $deadlineProbePath + '" -Package "' + $package + '"'
    $deadlineInfo.UseShellExecute = $false
    $deadlineInfo.CreateNoWindow = $true
    $deadlineWatch = [Diagnostics.Stopwatch]::StartNew()
    $deadlineProcess = [Diagnostics.Process]::Start($deadlineInfo)
    $deadlineCompleted = $deadlineProcess.WaitForExit(25000)
    $deadlineWatch.Stop()
    if (-not $deadlineCompleted) { try { $deadlineProcess.Kill(); $deadlineProcess.WaitForExit() } catch { } }
    Assert-Boundary ($deadlineCompleted -and $deadlineProcess.ExitCode -eq 2 -and $deadlineWatch.Elapsed.TotalSeconds -ge 11 -and
        $deadlineWatch.Elapsed.TotalSeconds -lt 25) 'the worker watchdog must independently terminate a blocked process after twelve seconds.'
    $deadlineProcess.Dispose()

    $killHandle = New-UsageWorkerJob
    $lifetimeInfo = [Diagnostics.ProcessStartInfo]::new()
    $lifetimeInfo.FileName = (Join-Path $PSHOME 'powershell.exe')
    $lifetimeInfo.Arguments = '-NoProfile -Command "Start-Sleep -Seconds 30"'
    $lifetimeInfo.UseShellExecute = $false
    $lifetimeInfo.CreateNoWindow = $true
    $lifetimeProcess = [Diagnostics.Process]::Start($lifetimeInfo)
    try {
        Add-UsageWorkerProcessToJob -Handle $killHandle -Process $lifetimeProcess
        Close-UsageWorkerJob -Handle $killHandle
        $killHandle = [IntPtr]::Zero
        Assert-Boundary ($lifetimeProcess.WaitForExit(2000)) 'closing the parent job handle must terminate an attached worker.'
    }
    finally {
        if ($killHandle -ne [IntPtr]::Zero) { Close-UsageWorkerJob -Handle $killHandle }
        try { if (-not $lifetimeProcess.HasExited) { $lifetimeProcess.Kill(); $lifetimeProcess.WaitForExit() } } catch { }
        $lifetimeProcess.Dispose()
    }
    foreach ($path in $preferencePath, $ledgerPath, $reminderPath) {
        $afterHash = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($path)))
        Assert-Boundary ($afterHash -ceq $stateHashes[$path]) 'the isolated worker must not mutate user state.'
    }

    $source = [IO.File]::ReadAllText((Join-Path $package 'CodexUsageWidget.ps1'))
    $runtime = $source.Substring($source.LastIndexOf('if ($SelfTest) { return }', [StringComparison]::Ordinal))
    Assert-Boundary (-not $runtime.Contains('RunspaceFactory') -and -not $runtime.Contains('InitialSessionState')) 'runtime refresh must not copy business functions into an in-process runspace.'
    Assert-Boundary ($runtime.Contains('Start-UsageScanProcess')) 'runtime refresh must use the isolated process launcher.'
}
finally {
    if ($null -ne $worker) {
        try { if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() } } catch { }
        $worker.Dispose()
    }
    $env:LOCALAPPDATA = $savedLocalAppData
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

Write-Output 'Windows data-boundary self-test passed.'
