param([Parameter(Mandatory)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-Boundary([bool]$Condition, [string]$Message) {
    if (-not $Condition) {
        if ($env:GITHUB_ACTIONS -eq 'true') { Write-Host "::error title=Windows data boundary::$Message" }
        throw "Windows data-boundary assertion failed: $Message"
    }
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

function New-PrivateWorkerChannel([string]$Path) {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $security = [Security.AccessControl.DirectorySecurity]::new()
    $security.SetOwner($identity.User)
    $security.SetAccessRuleProtection($true, $false)
    [void]$security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        $identity.Name,
        [Security.AccessControl.FileSystemRights]::FullControl,
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit,
        [Security.AccessControl.PropagationFlags]::None,
        [Security.AccessControl.AccessControlType]::Allow))
    [void][IO.Directory]::CreateDirectory($Path, $security)
}

function Remove-TestJunction([string]$Path) {
    if ($null -eq ('CodexUsageWidgetTestJunctionNative' -as [type])) {
        Add-Type @'
using System.Runtime.InteropServices;
public static class CodexUsageWidgetTestJunctionNative {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    public static extern bool RemoveDirectory(string path);
}
'@
    }
    if ([IO.Directory]::Exists($Path)) { [void][CodexUsageWidgetTestJunctionNative]::RemoveDirectory($Path) }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
. (Join-Path $package 'CodexUsageWidget.ps1') -SelfTest | Out-Null

$savedLocalAppData = $env:LOCALAPPDATA
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-data-boundary-' + [guid]::NewGuid().ToString('N'))
$worker = $null
$cleanupJunction = $null
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
    $invalidTreeLedger = '{"SchemaVersion":3,"Sessions":[{"Id":"session","CacheHitTokens":8,"CacheMissTokens":2,"CacheHitBaselineTokens":0,"CacheMissBaselineTokens":0,"TreeId":"not-a-guid"}]}'
    [IO.File]::WriteAllText($ledgerPath, $invalidTreeLedger, [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $null = Update-CumulativeCacheTokens @()
    Assert-Boundary ($script:CacheTokenLedger.StoreStatus -ceq 'invalid' -and
        [IO.File]::ReadAllText($ledgerPath) -ceq $invalidTreeLedger) `
        'schema v3 must reject a noncanonical task-tree id without rewriting the ledger.'

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
    Assert-Boundary (Reset-WidgetLocalState -Language 'zh-CN') 'later scan boundaries must start with an empty cumulative ledger.'
    $script:CacheTokenLedger = $null

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
    Assert-Boundary (@($splitSnapshot.State.SessionTokenSnapshots).Count -eq 1 -and
        @($splitSnapshot.State.ActiveTasks).Count -eq 30) ('a first scan must bound new-session baseline work to one file without dropping active tasks; sessions={0}, tasks={1}.' -f
            @($splitSnapshot.State.SessionTokenSnapshots).Count, @($splitSnapshot.State.ActiveTasks).Count)

    $forkRoot = Join-Path $testRoot 'fork-prefix'
    $forkSessions = Join-Path $forkRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($forkSessions)
    $forkPath = Join-Path $forkSessions 'rollout-44444444-4444-4444-4444-444444444444.jsonl'
    $forkRows = @(
        '{"timestamp":"2026-08-11T00:00:00.000Z","type":"session_meta","payload":{"id":"44444444-4444-4444-4444-444444444444","forked_from_id":"33333333-3333-3333-3333-333333333333"}}',
        '{"timestamp":"2026-08-11T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":20,"total_tokens":120},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":45,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}',
        '{"timestamp":"2026-08-11T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1500,"cached_input_tokens":1200,"output_tokens":200,"total_tokens":1700},"last_token_usage":{"input_tokens":500,"cached_input_tokens":400,"output_tokens":100,"total_tokens":600},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":46,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}'
    )
    [IO.File]::WriteAllLines($forkPath, $forkRows, [Text.UTF8Encoding]::new($false))
    $legacyForkLedger = '{"Sessions":[{"Id":"rollout-44444444-4444-4444-4444-444444444444","CacheHitTokens":1200,"CacheMissTokens":300}]}'
    [IO.File]::WriteAllText($ledgerPath, $legacyForkLedger, [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $forkSnapshot = Get-CodexUsageSnapshot -DataDirectory $forkRoot -ReadOnly
    $forkTokens = @($forkSnapshot.State.SessionTokenSnapshots)[0]
    Assert-Boundary ($forkTokens.CacheHitTokens -eq 1200 -and $forkTokens.CacheMissTokens -eq 300 -and
        $forkTokens.CacheHitBaselineTokens -eq 720 -and $forkTokens.CacheMissBaselineTokens -eq 180) `
        ('a forked session must expose its raw cumulative values and only the copied prefix needed by the ledger; hit={0}, miss={1}, baseHit={2}, baseMiss={3}.' -f
            $forkTokens.CacheHitTokens, $forkTokens.CacheMissTokens, $forkTokens.CacheHitBaselineTokens, $forkTokens.CacheMissBaselineTokens)
    $script:CacheTokenLedger = $null
    if ([IO.File]::Exists($ledgerPath)) { [IO.File]::Delete($ledgerPath) }
    $forkTotals = Update-CumulativeCacheTokens @($forkTokens)
    Assert-Boundary ($forkTotals.CacheHitTokens -eq 480 -and $forkTotals.CacheMissTokens -eq 120) `
        'the cumulative ledger must subtract the copied fork prefix while retaining the first real request.'
    $legacyLedger = '{"Sessions":[{"Id":"rollout-44444444-4444-4444-4444-444444444444","CacheHitTokens":1400,"CacheMissTokens":350},{"Id":"missing","CacheHitTokens":50,"CacheMissTokens":10}]}'
    [IO.File]::WriteAllText($ledgerPath, $legacyLedger, [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $legacyIds = Get-CumulativeCacheBaselineMigrationIds
    Assert-Boundary ($legacyIds['rollout-44444444-4444-4444-4444-444444444444'].CacheHitTokens -eq 1400) `
        'legacy migration must expose the previously observed raw maximum to prevent a lower tail snapshot from losing tokens.'
    $migratedTotals = Update-CumulativeCacheTokens @([pscustomobject]@{
        Id = 'rollout-44444444-4444-4444-4444-444444444444'
        CacheHitTokens = 1400; CacheMissTokens = 350
        CacheHitBaselineTokens = 720; CacheMissBaselineTokens = 180
    })
    Assert-Boundary ($migratedTotals.CacheHitTokens -eq 730 -and $migratedTotals.CacheMissTokens -eq 180) `
        'legacy migration must subtract the proven prefix, retain missing sessions, and never clear the ledger.'
    Assert-Boundary (Reset-WidgetLocalState -Language 'zh-CN') 'the migration fixture must restore an empty ledger before unrelated scan boundaries.'
    $script:CacheTokenLedger = $null
    [IO.File]::SetLastWriteTimeUtc($ledgerPath, [datetime]::UtcNow)

    $legacyOnlyRow = $forkRows[1].Replace('"limit_id":"codex",', '')
    $legacyCompletePath = Join-Path $testRoot 'legacy-baseline-complete.jsonl'
    [IO.File]::WriteAllLines($legacyCompletePath, @($forkRows[0], $legacyOnlyRow), [Text.UTF8Encoding]::new($false))
    $legacyCompleteBaseline = Get-SessionCacheTokenBaseline -Path $legacyCompletePath
    Assert-Boundary ($legacyCompleteBaseline.CacheHitTokens -eq 720 -and $legacyCompleteBaseline.CacheMissTokens -eq 180) `
        'a complete file with no explicit limit id may use its first legacy cache baseline.'
    $legacyNullPath = Join-Path $testRoot 'legacy-baseline-null.jsonl'
    $legacyNullRow = $forkRows[1].Replace('"limit_id":"codex"', '"limit_id":null')
    [IO.File]::WriteAllLines($legacyNullPath, @($forkRows[0], $legacyNullRow), [Text.UTF8Encoding]::new($false))
    $legacyNullBaseline = Get-SessionCacheTokenBaseline -Path $legacyNullPath
    Assert-Boundary ($legacyNullBaseline.CacheHitTokens -eq $legacyCompleteBaseline.CacheHitTokens -and
        $legacyNullBaseline.CacheMissTokens -eq $legacyCompleteBaseline.CacheMissTokens) `
        'a null limit id must have the same legacy baseline semantics as an omitted limit id.'
    $legacyTruncatedPath = Join-Path $testRoot 'legacy-baseline-truncated.jsonl'
    [IO.File]::WriteAllLines($legacyTruncatedPath, @(
        $forkRows[0], $legacyOnlyRow, ('{"padding":"' + ('x' * 4194304) + '"}'), $forkRows[1]
    ), [Text.UTF8Encoding]::new($false))
    Assert-Boundary ($null -eq (Get-SessionCacheTokenBaseline -Path $legacyTruncatedPath)) `
        'a truncated head that has only legacy usage must remain unknown because an explicit Codex record may follow.'

    $rotationRoot = Join-Path $testRoot 'baseline-rotation'
    $rotationSessions = Join-Path $rotationRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($rotationSessions)
    $blockedId = '00000000-0000-0000-0000-000000000001'
    $readyId = '00000000-0000-0000-0000-000000000002'
    $blockedMeta = '{"timestamp":"2026-08-11T00:00:00.000Z","type":"session_meta","payload":{"id":"' +
        $blockedId + '","forked_from_id":"33333333-3333-3333-3333-333333333333","padding":"' + ('x' * 4194304) + '"}}'
    $readyMeta = '{"timestamp":"2026-08-11T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $readyId + '"}}'
    $rotationUsage = $forkRows[1]
    $blockedPath = Join-Path $rotationSessions ('rollout-' + $blockedId + '.jsonl')
    $readyPath = Join-Path $rotationSessions ('rollout-' + $readyId + '.jsonl')
    [IO.File]::WriteAllLines($blockedPath, @($blockedMeta, $rotationUsage), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines($readyPath, @($readyMeta, $rotationUsage), [Text.UTF8Encoding]::new($false))
    $rotationNow = [datetime]::UtcNow
    [IO.File]::SetLastWriteTimeUtc($blockedPath, $rotationNow)
    [IO.File]::SetLastWriteTimeUtc($readyPath, $rotationNow.AddSeconds(-1))
    [IO.File]::WriteAllLines((Join-Path $rotationRoot 'session_index.jsonl'), @(
        ('{"id":"' + $blockedId + '","thread_name":"blocked"}'),
        ('{"id":"' + $readyId + '","thread_name":"ready"}')
    ))
    $script:CacheTokenBaselineCursor = $null
    $blockedRound = Get-CodexUsageSnapshot -DataDirectory $rotationRoot -ReadOnly
    Assert-Boundary ($blockedRound.State.LimitWindows[0].RemainingPercent -eq 55 -and
        @($blockedRound.State.ActiveTasks).Count -eq 2 -and @($blockedRound.State.SessionTokenSnapshots).Count -eq 0) `
        'an indeterminate baseline must not become zero or hide the current percentage and active tasks.'
    $advancedRound = Get-CodexUsageSnapshot -DataDirectory $rotationRoot -ReadOnly
    $advancedSessions = @($advancedRound.State.SessionTokenSnapshots)
    Assert-Boundary ($advancedSessions.Count -eq 1 -and $advancedSessions[0].Id -ceq ('rollout-' + $readyId) -and
        $advancedSessions[0].CacheHitBaselineTokens -eq 0 -and $advancedSessions[0].CacheMissBaselineTokens -eq 0) `
        'one unreadable 4 MiB prefix must not permanently consume the only baseline-read budget.'

    $transientRoot = Join-Path $testRoot 'transient-migration'
    $transientSessions = Join-Path $transientRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($transientSessions)
    [IO.File]::Copy($blockedPath, (Join-Path $transientSessions ('rollout-' + $blockedId + '.jsonl')))
    [IO.File]::WriteAllText((Join-Path $transientSessions 'current.jsonl'), $rotationUsage, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ledgerPath,
        ('{"Sessions":[{"Id":"rollout-' + $blockedId + '","CacheHitTokens":800,"CacheMissTokens":200}]}'),
        [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $script:CacheTokenBaselineCursor = $null
    $transientSnapshot = Get-CodexUsageSnapshot -DataDirectory $transientRoot -ReadOnly
    Assert-Boundary (@($transientSnapshot.State.SessionTokenSnapshots | Where-Object Id -eq ('rollout-' + $blockedId)).Count -eq 0 -and
        @($transientSnapshot.State.SessionTokenSnapshots | Where-Object Id -eq 'current').Count -eq 1) `
        'a present session whose head is temporarily unreadable must remain pending instead of being frozen at baseline zero.'

    $nullRawRoot = Join-Path $testRoot 'null-raw-cache'
    $nullRawSessions = Join-Path $nullRawRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($nullRawSessions)
    $nullRawUsage = '{"timestamp":"2026-08-11T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"last_token_usage":{"input_tokens":100,"output_tokens":20,"total_tokens":120},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":45,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}'
    [IO.File]::WriteAllText((Join-Path $nullRawSessions 'null-cache.jsonl'), $nullRawUsage, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ledgerPath, '{"SchemaVersion":2,"Sessions":[]}', [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $nullRawSnapshot = Get-CodexUsageSnapshot -DataDirectory $nullRawRoot -ReadOnly
    Assert-Boundary ($nullRawSnapshot.State.LimitWindows[0].RemainingPercent -eq 55 -and
        @($nullRawSnapshot.State.SessionTokenSnapshots).Count -eq 0) `
        'a valid limit observation with unknown raw cache counters must remain visible without entering the cache ledger.'

    $directoryAForkId = 'rollout-44444444-4444-4444-4444-444444444444'
    $directoryARoot = Join-Path $testRoot 'migration-directory-a'
    $directoryASessions = Join-Path $directoryARoot 'sessions'
    [void][IO.Directory]::CreateDirectory($directoryASessions)
    [IO.File]::WriteAllText((Join-Path $directoryASessions 'current.jsonl'), $rotationUsage, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($ledgerPath,
        ('{"Sessions":[{"Id":"' + $directoryAForkId + '","CacheHitTokens":1400,"CacheMissTokens":350}]}'),
        [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $script:CacheTokenBaselineCursor = $null
    $directoryASnapshot = Get-CodexUsageSnapshot -DataDirectory $directoryARoot -ReadOnly
    Assert-Boundary (@($directoryASnapshot.State.SessionTokenSnapshots | Where-Object Id -eq $directoryAForkId).Count -eq 0) `
        'a pending fork missing only from the currently selected Codex directory must not be emitted with baseline zero.'
    $directoryAPersisted = Apply-UsageSnapshotPersistence $directoryASnapshot
    $directoryALedger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -ErrorAction Stop
    $directoryAFork = @($directoryALedger.Sessions | Where-Object Id -eq $directoryAForkId)[0]
    Assert-Boundary ($null -ne $directoryAPersisted -and
        $null -eq $directoryAFork.CacheHitBaselineTokens -and $null -eq $directoryAFork.CacheMissBaselineTokens) `
        'a scan of another Codex directory must preserve an unknown fork baseline on disk.'

    $directoryBRoot = Join-Path $testRoot 'migration-directory-b'
    $directoryBSessions = Join-Path $directoryBRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($directoryBSessions)
    [IO.File]::Copy($forkPath, (Join-Path $directoryBSessions ($directoryAForkId + '.jsonl')))
    [IO.File]::WriteAllText((Join-Path $directoryBSessions 'current.jsonl'), $rotationUsage, [Text.UTF8Encoding]::new($false))
    $directoryBSnapshot = Get-CodexUsageSnapshot -DataDirectory $directoryBRoot -ReadOnly
    $directoryBFork = @($directoryBSnapshot.State.SessionTokenSnapshots | Where-Object Id -eq $directoryAForkId)[0]
    Assert-Boundary ($directoryBFork.CacheHitBaselineTokens -eq 720 -and $directoryBFork.CacheMissBaselineTokens -eq 180) `
        'when the pending fork appears in a different Codex directory its proven copied prefix must still be recovered.'
    $null = Apply-UsageSnapshotPersistence $directoryBSnapshot
    $directoryBLedger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -ErrorAction Stop
    $directoryBStoredFork = @($directoryBLedger.Sessions | Where-Object Id -eq $directoryAForkId)[0]
    Assert-Boundary ($directoryBStoredFork.CacheHitBaselineTokens -eq 720 -and $directoryBStoredFork.CacheMissBaselineTokens -eq 180) `
        'the recovered fork baseline must replace the pending unknown value rather than a guessed zero.'

    $protocolRoot = Join-Path $testRoot 'migration-protocol-limit'
    $protocolSessions = Join-Path $protocolRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($protocolSessions)
    for ($index = 0; $index -lt 30; $index++) {
        [IO.File]::WriteAllText((Join-Path $protocolSessions ('session-{0:D2}.jsonl' -f $index)), $rotationUsage, [Text.UTF8Encoding]::new($false))
    }
    $ordinaryMigrationId = 'ordinary-old'
    [IO.File]::WriteAllLines((Join-Path $protocolSessions ($ordinaryMigrationId + '.jsonl')), @(
        '{"timestamp":"2026-08-11T00:00:00.000Z","type":"session_meta","payload":{"id":"55555555-5555-5555-5555-555555555555"}}',
        $rotationUsage
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::SetLastWriteTimeUtc((Join-Path $protocolSessions ($ordinaryMigrationId + '.jsonl')), [datetime]'2020-01-01T00:00:00Z')
    [IO.File]::WriteAllText($ledgerPath,
        ('{"Sessions":[{"Id":"' + $ordinaryMigrationId + '","CacheHitTokens":50,"CacheMissTokens":10}]}'),
        [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $script:CacheTokenBaselineCursor = $null
    $protocolSnapshot = Get-CodexUsageSnapshot -DataDirectory $protocolRoot -ReadOnly
    $ordinaryMigration = @($protocolSnapshot.State.SessionTokenSnapshots | Where-Object Id -eq $ordinaryMigrationId)
    Assert-Boundary (@($protocolSnapshot.State.SessionTokenSnapshots).Count -eq 31 -and $ordinaryMigration.Count -eq 1 -and
        $ordinaryMigration[0].CacheHitBaselineTokens -eq 0 -and $ordinaryMigration[0].CacheMissBaselineTokens -eq 0 -and
        (Test-UsageScanSnapshot $protocolSnapshot)) `
        'a found ordinary legacy session may use zero baseline without exceeding the thirty-plus-one protocol bound.'
    Assert-Boundary (Reset-WidgetLocalState -Language 'zh-CN') 'baseline migration boundary tests must restore an empty ledger.'
    $script:CacheTokenLedger = $null

    $invalidTreeSessionId = '55555555-5555-5555-5555-555555555555'
    $invalidTreePath = Join-Path $testRoot ('rollout-' + $invalidTreeSessionId + '.jsonl')
    [IO.File]::WriteAllText($invalidTreePath,
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' +
            $invalidTreeSessionId + '","session_id":"not-a-guid"}}'),
        [Text.UTF8Encoding]::new($false))
    Assert-Boundary ($null -eq (Get-SessionTreeId -Path $invalidTreePath)) `
        'an explicitly invalid session_id must remain unknown instead of being relabeled as a root task.'
    $lateMetaPath = Join-Path $testRoot ('late-rollout-' + $invalidTreeSessionId + '.jsonl')
    [IO.File]::WriteAllLines($lateMetaPath, @(
        '{bad json',
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' +
            $invalidTreeSessionId + '","session_id":"' + $invalidTreeSessionId + '"}}')
    ), [Text.UTF8Encoding]::new($false))
    Assert-Boundary ($null -eq (Get-SessionTreeId -Path $lateMetaPath)) `
        'task-tree identity must come only from the first nonempty record, never a later metadata-shaped line.'

    $treeRoot = Join-Path $testRoot 'fork-tree-deduplication'
    $treeSessions = Join-Path $treeRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($treeSessions)
    $treeRootId = '11111111-1111-1111-1111-111111111111'
    $treeForkAId = '22222222-2222-2222-2222-222222222222'
    $treeForkBId = '33333333-3333-3333-3333-333333333333'
    $independentId = '44444444-4444-4444-4444-444444444444'
    $treePrefix = '{"timestamp":"2026-08-12T00:00:01.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"total_tokens":110},"last_token_usage":{"input_tokens":100,"cached_input_tokens":80,"output_tokens":10,"total_tokens":110},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":45,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}'
    $treeRootFinal = '{"timestamp":"2026-08-12T00:00:02.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1000,"cached_input_tokens":800,"output_tokens":100,"total_tokens":1100},"last_token_usage":{"input_tokens":900,"cached_input_tokens":720,"output_tokens":90,"total_tokens":990},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":46,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}'
    $treeForkFinal = '{"timestamp":"2026-08-12T00:00:03.000Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1100,"cached_input_tokens":700,"output_tokens":110,"total_tokens":1210},"last_token_usage":{"input_tokens":1000,"cached_input_tokens":620,"output_tokens":100,"total_tokens":1100},"model_context_window":258400},"rate_limits":{"limit_id":"codex","primary":{"used_percent":47,"window_minutes":10080,"resets_at":4102444800},"secondary":null}}}'
    $independentPrefix = $treePrefix.Replace('"input_tokens":100,"cached_input_tokens":80', '"input_tokens":50,"cached_input_tokens":40').Replace('"total_tokens":110', '"total_tokens":60')
    $independentFinal = $treeRootFinal.Replace('"input_tokens":1000,"cached_input_tokens":800', '"input_tokens":500,"cached_input_tokens":400').Replace('"total_tokens":1100', '"total_tokens":600')
    [IO.File]::WriteAllLines((Join-Path $treeSessions ('rollout-' + $treeRootId + '.jsonl')), @(
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $treeRootId + '","session_id":"' + $treeRootId + '"}}'),
        $treePrefix, $treeRootFinal
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $treeSessions ('rollout-' + $treeForkAId + '.jsonl')), @(
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $treeForkAId + '","session_id":"' + $treeRootId + '","forked_from_id":"' + $treeRootId + '"}}'),
        $treePrefix, $treeForkFinal
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $treeSessions ('rollout-' + $treeForkBId + '.jsonl')), @(
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $treeForkBId + '","session_id":"' + $treeRootId + '","parent_thread_id":"' + $treeRootId + '"}}'),
        $treePrefix, $treeRootFinal
    ), [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllLines((Join-Path $treeSessions ('rollout-' + $independentId + '.jsonl')), @(
        ('{"timestamp":"2026-08-12T00:00:00.000Z","type":"session_meta","payload":{"id":"' + $independentId + '","session_id":"' + $independentId + '"}}'),
        $independentPrefix, $independentFinal
    ), [Text.UTF8Encoding]::new($false))
    $legacyTreeSessions = @(
        [pscustomobject]@{ Id = 'rollout-' + $treeRootId; CacheHitTokens = 800; CacheMissTokens = 200; CacheHitBaselineTokens = 0; CacheMissBaselineTokens = 0 },
        [pscustomobject]@{ Id = 'rollout-' + $treeForkAId; CacheHitTokens = 700; CacheMissTokens = 400; CacheHitBaselineTokens = 0; CacheMissBaselineTokens = 0 },
        [pscustomobject]@{ Id = 'rollout-' + $treeForkBId; CacheHitTokens = 800; CacheMissTokens = 200; CacheHitBaselineTokens = 0; CacheMissBaselineTokens = 0 },
        [pscustomobject]@{ Id = 'rollout-' + $independentId; CacheHitTokens = 400; CacheMissTokens = 100; CacheHitBaselineTokens = 0; CacheMissBaselineTokens = 0 }
    )
    [IO.File]::WriteAllText($ledgerPath,
        ([pscustomobject]@{ SchemaVersion = 2; Sessions = $legacyTreeSessions } | ConvertTo-Json -Depth 4 -Compress),
        [Text.UTF8Encoding]::new($false))
    $script:CacheTokenLedger = $null
    $script:CacheTokenBaselineCursor = $null
    $treeSnapshot = Get-CodexUsageSnapshot -DataDirectory $treeRoot -ReadOnly
    $treeSnapshot = Apply-UsageSnapshotPersistence $treeSnapshot
    Assert-Boundary ($null -ne $treeSnapshot) 'task-tree migration must preserve and persist its snapshot.'
    Assert-Boundary ($treeSnapshot.State.TokenDetails.CacheHitTokens -eq 1200 -and
        $treeSnapshot.State.TokenDetails.CacheMissTokens -eq 500) `
        ('one task tree must retain each cumulative counter maximum while an independent root still adds; hit={0}, miss={1}.' -f
            $treeSnapshot.State.TokenDetails.CacheHitTokens, $treeSnapshot.State.TokenDetails.CacheMissTokens)
    $treeLedger = [IO.File]::ReadAllText($ledgerPath) | ConvertFrom-Json -ErrorAction Stop
    Assert-Boundary ($treeLedger.SchemaVersion -eq 3 -and
        @($treeLedger.Sessions | Where-Object TreeId -eq $treeRootId).Count -eq 3 -and
        @($treeLedger.Sessions | Where-Object TreeId -eq $independentId).Count -eq 1) `
        'one scan must migrate every available v2 task-tree identity without clearing historical counters.'
    Assert-Boundary (Reset-WidgetLocalState -Language 'zh-CN') 'task-tree deduplication must leave later fixtures with an empty ledger.'
    $script:CacheTokenLedger = $null

    $filteredRoot = Join-Path $testRoot 'filtered-session-tokens'
    $filteredSessions = Join-Path $filteredRoot 'sessions'
    [void][IO.Directory]::CreateDirectory($filteredSessions)
    [IO.File]::Copy(
        (Join-Path $package 'fixtures\contract\v1\inputs\reset-jitter.jsonl'),
        (Join-Path $filteredSessions 'contract.jsonl'))
    $filteredSnapshot = Get-CodexUsageSnapshot -DataDirectory $filteredRoot -ReadOnly
    $filteredTokens = @($filteredSnapshot.State.SessionTokenSnapshots)[0]
    Assert-Boundary ($filteredTokens.CacheHitTokens -eq 80 -and $filteredTokens.CacheMissTokens -eq 120) `
        ('per-session cache totals must use the same current Codex cycle as the global state; hit={0}, miss={1}.' -f
            $filteredTokens.CacheHitTokens, $filteredTokens.CacheMissTokens)

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
    $orphanNow = [datetime]'2026-08-12T00:00:00Z'
    $oldChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-11111111111111111111111111111111'
    $freshChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-22222222222222222222222222222222'
    $unknownChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-33333333333333333333333333333333'
    $junctionChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-44444444444444444444444444444444'
    $badAclChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-55555555555555555555555555555555'
    $unrelatedChannel = Join-Path $workerRoot 'CodexUsageWidget-scan-not-ours'
    foreach ($path in $oldChannel, $freshChannel, $unknownChannel, $junctionChannel, $unrelatedChannel) {
        New-PrivateWorkerChannel $path
    }
    [void][IO.Directory]::CreateDirectory($badAclChannel)
    [IO.File]::WriteAllText((Join-Path $oldChannel 'ready'), '')
    [IO.File]::WriteAllText((Join-Path $oldChannel 'result.json'), '{}')
    [IO.File]::WriteAllText((Join-Path $oldChannel 'result.json.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.tmp'), '{}')
    [IO.File]::WriteAllText((Join-Path $unknownChannel 'unexpected.txt'), 'keep')
    $outsideCleanupTarget = Join-Path $testRoot 'orphan-cleanup-outside'
    [void][IO.Directory]::CreateDirectory($outsideCleanupTarget)
    $outsideCleanupSentinel = Join-Path $outsideCleanupTarget 'sentinel.txt'
    [IO.File]::WriteAllText($outsideCleanupSentinel, 'keep')
    $cleanupJunction = Join-Path $junctionChannel 'linked'
    $null = New-Item -ItemType Junction -Path $cleanupJunction -Target $outsideCleanupTarget -ErrorAction Stop
    foreach ($path in $oldChannel, $unknownChannel, $junctionChannel, $badAclChannel, $unrelatedChannel) {
        [IO.Directory]::SetLastWriteTimeUtc($path, $orphanNow.AddHours(-25))
    }
    Remove-StaleUsageWorkerChannels -Root $workerRoot -NowUtc $orphanNow
    Assert-Boundary (-not [IO.Directory]::Exists($oldChannel)) 'startup cleanup must remove an owned expired channel containing only known artifacts.'
    Assert-Boundary ([IO.Directory]::Exists($freshChannel) -and [IO.Directory]::Exists($unrelatedChannel)) 'startup cleanup must preserve fresh and non-owned names.'
    Assert-Boundary ([IO.Directory]::Exists($badAclChannel) -and [IO.Directory]::Exists($unknownChannel)) 'startup cleanup must preserve channels with an untrusted ACL or unknown child.'
    Assert-Boundary ([IO.Directory]::Exists($junctionChannel) -and [IO.File]::Exists($outsideCleanupSentinel)) 'startup cleanup must not follow or remove a nested reparse target.'
    Remove-TestJunction $cleanupJunction
    $cleanupJunction = $null
    $generation = [guid]::NewGuid().ToString('N')
    $stateHashes = @{}
    foreach ($path in $preferencePath, $ledgerPath, $reminderPath) {
        $stateHashes[$path] = [Convert]::ToBase64String([Security.Cryptography.SHA256]::Create().ComputeHash([IO.File]::ReadAllBytes($path)))
    }
    $workerEnvironmentNames = 'CODEX_WIDGET_DATA_DIRECTORY', 'CODEX_WIDGET_RESULT_PATH', 'CODEX_WIDGET_GENERATION'
    $workerEnvironmentBefore = @{}
    foreach ($name in $workerEnvironmentNames) { $workerEnvironmentBefore[$name] = [Environment]::GetEnvironmentVariable($name, [EnvironmentVariableTarget]::Process) }
    $workerWatch = [Diagnostics.Stopwatch]::StartNew()
    $savedConsoleInputEncoding = [Console]::InputEncoding
    try {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($true)
        $workerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') -DataDirectory $workerData -Generation $generation
    }
    finally { [Console]::InputEncoding = $savedConsoleInputEncoding }
    $channelDirectory = Join-Path $workerRoot ('CodexUsageWidget-scan-' + $generation)
    $workerOutput = Join-Path $channelDirectory 'result.json'
    $workerReady = Join-Path $channelDirectory 'ready'
    Assert-Boundary ($workerJob.OutputPath -ceq $workerOutput -and $workerJob.ChannelDirectory -ceq $channelDirectory) 'each scan must bind output to its own private channel directory.'
    Assert-Boundary ($workerJob.ReadyPath -ceq $workerReady -and $workerJob.RequestedAtUtc -is [datetime] -and
        $null -eq $workerJob.StartedAtUtc) 'a cold worker request must expose a private readiness marker before its scan deadline begins.'
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
    $workerStartupDeadlineAt = [datetime]::UtcNow.AddSeconds(30)
    while (-not [IO.File]::Exists($workerReady) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $workerStartupDeadlineAt) {
        Start-Sleep -Milliseconds 50
    }
    $workerStartupExited = $worker.HasExited
    $workerStartupError = if ($workerStartupExited) { $worker.StandardError.ReadToEnd().Trim() } else { '' }
    Assert-Boundary ([IO.File]::Exists($workerReady) -and -not $workerStartupExited) ('the worker must acknowledge a validated request before scanning; diagnostic={0}.' -f $workerStartupError)
    $workerDeadlineAt = [datetime]::UtcNow.AddSeconds(12)
    while (-not [IO.File]::Exists($workerOutput) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $workerDeadlineAt) {
        Start-Sleep -Milliseconds 50
    }
    $workerWatch.Stop()
    $workerHasExited = $worker.HasExited
    $workerExitCode = if ($workerHasExited) { $worker.ExitCode } else { $null }
    $workerError = if ($workerHasExited) { $worker.StandardError.ReadToEnd().Trim() } else { '' }
    Assert-Boundary (-not $workerHasExited) ('the isolated worker host must remain alive after completing a request; exit={0}; result={1}; elapsed={2:N3}s; diagnostic={3}.' -f
        $workerExitCode, [IO.File]::Exists($workerOutput), $workerWatch.Elapsed.TotalSeconds, $workerError)
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
    Assert-Boundary ($received.Status -ceq 'completed' -and -not $received.ProcessExited -and -not [IO.File]::Exists($workerOutput)) 'the parent must consume one result without stopping the reusable worker host.'
    $validatedSnapshot = $received.Snapshot
    Assert-Boundary ($validatedSnapshot.Classification -ceq 'complete' -and $null -ne $validatedSnapshot.State) 'the parent must publish a complete validated snapshot.'
    Assert-Boundary (@($validatedSnapshot.State.SessionTokenSnapshots).Count -eq 30) ('the parent must validate thirty bounded session files; count={0}.' -f @($validatedSnapshot.State.SessionTokenSnapshots).Count)
    $secondGeneration = [guid]::NewGuid().ToString('N')
    $secondWorkerJob = Start-UsageScanProcess -ScriptPath (Join-Path $package 'CodexUsageWidget.ps1') -DataDirectory $workerData -Generation $secondGeneration
    Assert-Boundary ($secondWorkerJob.Process.Id -eq $worker.Id) 'consecutive scans must reuse the same isolated worker process.'
    $secondStartupDeadlineAt = [datetime]::UtcNow.AddSeconds(30)
    while (-not [IO.File]::Exists($secondWorkerJob.ReadyPath) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $secondStartupDeadlineAt) {
        Start-Sleep -Milliseconds 50
    }
    Assert-Boundary ([IO.File]::Exists($secondWorkerJob.ReadyPath) -and -not $worker.HasExited) 'a reused worker must acknowledge its next request independently.'
    $secondDeadlineAt = [datetime]::UtcNow.AddSeconds(12)
    while (-not [IO.File]::Exists($secondWorkerJob.OutputPath) -and -not $worker.HasExited -and [datetime]::UtcNow -lt $secondDeadlineAt) {
        Start-Sleep -Milliseconds 50
    }
    $secondReceived = Receive-UsageScanProcess -Job $secondWorkerJob -TimeoutSeconds 10
    Assert-Boundary ($secondReceived.Status -ceq 'completed' -and -not $secondReceived.ProcessExited -and
        -not [IO.Directory]::Exists($secondWorkerJob.ChannelDirectory)) 'a reused worker must publish and clean an independent second channel.'
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
    $timeoutReady = Join-Path $timeoutChannel 'ready'
    [IO.File]::WriteAllText($timeoutReady, '')
    $timeoutJob = [pscustomobject]@{
        Process = $timeoutProcess
        Generation = '55555555555555555555555555555555'
        OutputPath = (Join-Path $timeoutChannel 'result.json')
        ChannelDirectory = $timeoutChannel
        ReadyPath = $timeoutReady
        RequestedAtUtc = [datetime]::UtcNow.AddSeconds(-11)
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
    $initializeStart = $runtime.IndexOf('function Initialize-UsageWorker', [StringComparison]::Ordinal)
    $refreshStart = $runtime.IndexOf('function Start-UsageRefresh', $initializeStart, [StringComparison]::Ordinal)
    Assert-Boundary ($initializeStart -ge 0 -and $refreshStart -gt $initializeStart -and
        $runtime.Substring($initializeStart, $refreshStart - $initializeStart).Contains('Remove-StaleUsageWorkerChannels')) 'runtime startup must invoke bounded stale-channel cleanup.'
}
finally {
    if ($null -ne $worker) {
        try { if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() } } catch { }
        $worker.Dispose()
    }
    $script:UsageWorkerHost = $null
    $env:LOCALAPPDATA = $savedLocalAppData
    if ($null -ne $cleanupJunction -and (Test-Path -LiteralPath $cleanupJunction)) {
        Remove-TestJunction $cleanupJunction
    }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

Write-Output 'Windows data-boundary self-test passed.'
