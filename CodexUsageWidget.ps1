param(
    [switch]$SelfTest
)

$script:CodexUsageDiagnostic = $null
$script:CacheTokenLedger = $null
$script:ReminderGateCache = $null
$script:InstanceMutex = $null
$script:OwnsInstanceMutex = $false
$script:WidgetLanguagePacks = $null
$script:CurrentLanguageCode = $null
$script:CurrentLanguageCulture = [cultureinfo]'en-US'

function Stop-InstanceMutex {
    if ($null -eq $script:InstanceMutex) { return }
    if ($script:OwnsInstanceMutex) {
        try { $script:InstanceMutex.ReleaseMutex() } catch { }
    }
    try { $script:InstanceMutex.Dispose() } catch { }
    $script:InstanceMutex = $null
    $script:OwnsInstanceMutex = $false
}

function Format-WidgetFatalError {
    param(
        [Parameter(Mandatory)][string]$Problem,
        [Parameter(Mandatory)][string]$Cause,
        [Parameter(Mandatory)][string]$Fix
    )

    if ($null -ne $script:WidgetLanguagePacks) {
        return Get-WidgetText 'fatal.template' @($Problem, $Cause, $Fix)
    }
    return "Problem / 问题：$Problem`r`n`r`nCause / 原因：$Cause`r`nFix / 解决办法：$Fix"
}

function Show-WidgetFatalError {
    param(
        [Parameter(Mandatory)][string]$Problem,
        [Parameter(Mandatory)][string]$Cause,
        [Parameter(Mandatory)][string]$Fix
    )

    $body = Format-WidgetFatalError $Problem $Cause $Fix
    $title = if ($null -ne $script:WidgetLanguagePacks) { Get-WidgetText 'app.title' } else { 'Usage widget / 用量小组件' }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [void][System.Windows.Forms.MessageBox]::Show(
            $body, $title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error)
        return
    }
    catch { }
    try {
        $shell = New-Object -ComObject WScript.Shell
        [void]$shell.Popup($body, 0, $title, 16)
        [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
    }
    catch { }
}

function Assert-Widget {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Message
    )

    if (-not $Condition) { throw "Assertion failed: $Message" }
}

function ConvertTo-LimitWindow {
    param(
        [Parameter(Mandatory)][ValidateSet('primary', 'secondary')][string]$Name,
        [Parameter(Mandatory)][AllowNull()]$Window
    )

    if ($null -eq $Window) { return $null }
    $used = $Window.PSObject.Properties['used_percent'].Value
    $resetSeconds = $Window.PSObject.Properties['resets_at'].Value
    if ($null -eq $used -or $null -eq $resetSeconds -or $used -is [bool] -or
        $resetSeconds -is [bool] -or $used -isnot [System.ValueType] -or
        $resetSeconds -isnot [System.ValueType]) { return $null }

    $usedPercent = [double]$used
    $resetValue = [double]$resetSeconds
    if ([double]::IsNaN($usedPercent) -or [double]::IsInfinity($usedPercent) -or
        $usedPercent -lt 0 -or $usedPercent -gt 100 -or [double]::IsNaN($resetValue) -or
        [double]::IsInfinity($resetValue) -or $resetValue -ne [math]::Truncate($resetValue) -or
        $resetValue -lt [long]::MinValue -or $resetValue -gt [long]::MaxValue) { return $null }

    try { $resetAt = [DateTimeOffset]::FromUnixTimeSeconds([long]$resetValue).LocalDateTime }
    catch { return $null }

    $values = [ordered]@{
        Name             = $Name
        UsedPercent      = $usedPercent
        RemainingPercent = 100 - $usedPercent
    }
    $windowMinutesProperty = $Window.PSObject.Properties['window_minutes']
    if ($null -ne $windowMinutesProperty) {
        $windowMinutes = $windowMinutesProperty.Value
        if ($null -eq $windowMinutes -or $windowMinutes -is [bool] -or
            $windowMinutes -isnot [System.ValueType]) { return $null }
        $windowMinutesValue = [double]$windowMinutes
        if ([double]::IsNaN($windowMinutesValue) -or [double]::IsInfinity($windowMinutesValue) -or
            $windowMinutesValue -lt 0) { return $null }
        $values.WindowMinutes = $windowMinutesValue
    }
    $values.ResetAt = $resetAt
    return [pscustomobject]$values
}

function ConvertTo-UsageState {
    param([Parameter(Mandatory)][string]$Json)

    try { $payload = $Json | ConvertFrom-Json -ErrorAction Stop }
    catch { throw 'Invalid rate-limit JSON.' }

    $windows = @()
    foreach ($name in 'primary', 'secondary') {
        $property = $payload.PSObject.Properties[$name]
        $window = ConvertTo-LimitWindow -Name $name -Window $(if ($null -ne $property) { $property.Value } else { $null })
        if ($null -ne $window) { $windows += $window }
    }
    if ($windows.Count -eq 0) { throw 'No valid rate-limit windows.' }
    return [pscustomobject]@{ LimitWindows = $windows }
}

function Get-CurrentLimitState {
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][datetime]$Now
    )

    @($State.LimitWindows) |
        Where-Object { [datetime]$_.ResetAt -gt $Now } |
        Sort-Object @{ Expression = 'RemainingPercent'; Ascending = $true },
                    @{ Expression = { if ($_.Name -eq 'primary') { 0 } else { 1 } }; Ascending = $true } |
        Select-Object -First 1
}

function Get-TokenNumber {
    param(
        [AllowNull()]$Object,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    $value = $property.Value
    if ($null -eq $value -or $value -is [bool] -or $value -isnot [System.ValueType]) { return $null }
    $typeCode = [Type]::GetTypeCode($value.GetType())
    if ($typeCode -notin [TypeCode]::Byte, [TypeCode]::SByte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal) { return $null }
    if (($typeCode -eq [TypeCode]::Single -and [math]::Abs([double]$value) -gt 16777215) -or
        ($typeCode -eq [TypeCode]::Double -and ([double]::IsNaN([double]$value) -or
            [double]::IsInfinity([double]$value) -or [math]::Abs([double]$value) -gt 9007199254740991))) { return $null }
    try { $number = [decimal]$value } catch { return $null }
    if ($number -lt 0 -or $number -gt [long]::MaxValue -or $number -ne [decimal]::Truncate($number)) { return $null }
    return [long]$number
}

function Get-TokenPercent {
    param(
        [AllowNull()]$Numerator,
        [AllowNull()]$Denominator
    )

    if ($null -eq $Numerator -or $null -eq $Denominator -or $Numerator -is [bool] -or
        $Denominator -is [bool] -or $Numerator -isnot [System.ValueType] -or
        $Denominator -isnot [System.ValueType]) { return $null }
    try {
        $numeratorValue = [decimal]$Numerator
        $denominatorValue = [decimal]$Denominator
    }
    catch { return $null }
    if ($numeratorValue -lt 0 -or $denominatorValue -le 0) { return $null }
    if ($numeratorValue -ge $denominatorValue) { return [decimal]100 }
    return [decimal]::Round(($numeratorValue / $denominatorValue) * 100, 1, [MidpointRounding]::ToEven)
}

function Get-EventTokenDetails {
    param([Parameter(Mandatory)]$Event)

    $payloadProperty = $Event.PSObject.Properties['payload']
    if ($null -eq $payloadProperty) { return $null }
    $infoProperty = $payloadProperty.Value.PSObject.Properties['info']
    if ($null -eq $infoProperty) { return $null }
    $info = $infoProperty.Value

    $totalUsageProperty = $info.PSObject.Properties['total_token_usage']
    $lastUsageProperty = $info.PSObject.Properties['last_token_usage']
    $total = if ($null -ne $totalUsageProperty) { $totalUsageProperty.Value } else { $null }
    $cumulative = Get-TokenNumber $total 'total_tokens'
    $cumulativeInputTokens = Get-TokenNumber $total 'input_tokens'
    $cumulativeCachedTokens = Get-TokenNumber $total 'cached_input_tokens'
    $last = if ($null -ne $lastUsageProperty) { $lastUsageProperty.Value } else { $null }
    $contextLimit = Get-TokenNumber $info 'model_context_window'
    $contextTokens = Get-TokenNumber $last 'total_tokens'
    $inputTokens = Get-TokenNumber $last 'input_tokens'
    $outputTokens = Get-TokenNumber $last 'output_tokens'
    $reasoningTokens = Get-TokenNumber $last 'reasoning_output_tokens'

    $cacheHitTokens = $null
    $cacheMissTokens = $null
    $cacheHitPercent = $null
    $cacheMissPercent = $null
    if ($null -ne $cumulativeInputTokens -and $null -ne $cumulativeCachedTokens -and
        $cumulativeCachedTokens -le $cumulativeInputTokens) {
        $cacheHitTokens = $cumulativeCachedTokens
        $cacheMissTokens = $cumulativeInputTokens - $cumulativeCachedTokens
        $cacheHitPercent = Get-TokenPercent $cacheHitTokens $cumulativeInputTokens
        if ($null -ne $cacheHitPercent) {
            $cacheMissPercent = [math]::Round(100.0 - $cacheHitPercent, 1, [MidpointRounding]::ToEven)
        }
    }

    if ($null -eq $cumulative -and $null -eq $contextLimit -and $null -eq $contextTokens -and
        $null -eq $inputTokens -and $null -eq $outputTokens -and $null -eq $reasoningTokens -and
        $null -eq $cacheHitTokens) { return $null }

    $compositionTotal = if ($null -ne $inputTokens -and $null -ne $outputTokens) { [decimal]$inputTokens + [decimal]$outputTokens } else { $null }
    [pscustomobject]@{
        CumulativeTokens       = $cumulative
        CacheHitTokens         = $cacheHitTokens
        CacheMissTokens        = $cacheMissTokens
        CacheHitPercent        = $cacheHitPercent
        CacheMissPercent       = $cacheMissPercent
        ContextTokens          = $contextTokens
        ContextLimit           = $contextLimit
        ContextPercent         = Get-TokenPercent $contextTokens $contextLimit
        InputPercent           = Get-TokenPercent $inputTokens $compositionTotal
        OutputPercent          = Get-TokenPercent $outputTokens $compositionTotal
        ReasoningOutputPercent = if ($null -ne $reasoningTokens -and $null -ne $outputTokens -and $reasoningTokens -le $outputTokens) { Get-TokenPercent $reasoningTokens $outputTokens } else { $null }
    }
}

function ConvertTo-ObservedAt {
    param([Parameter(Mandatory)]$Timestamp)

    try {
        if ($Timestamp -is [bool]) { return $null }
        if ($Timestamp -is [System.ValueType]) {
            return [DateTimeOffset]::FromUnixTimeSeconds([long]$Timestamp).LocalDateTime
        }

        $parsed = [DateTimeOffset]::MinValue
        if ([DateTimeOffset]::TryParse([string]$Timestamp, [ref]$parsed)) { return $parsed.LocalDateTime }
    }
    catch { }

    return $null
}

function Get-EventRateLimits {
    param([Parameter(Mandatory)]$Event)

    $pending = New-Object 'System.Collections.Generic.Queue[object]'
    $visited = New-Object 'System.Collections.Generic.HashSet[object]'
    $pending.Enqueue($Event)
    while ($pending.Count -and $visited.Count -lt 1000) {
        $value = $pending.Dequeue()
        if ($null -eq $value -or $value -is [string] -or $value -is [System.ValueType]) { continue }
        if (-not $visited.Add($value)) { continue }

        foreach ($property in $value.PSObject.Properties) {
            if ($property.Name -eq 'rate_limits') { return $property.Value }
            if ($null -ne $property.Value) { $pending.Enqueue($property.Value) }
        }
    }
    return $null
}

function Read-TaskNameIndex {
    param([Parameter(Mandatory)][string]$Path)

    if (-not [System.IO.File]::Exists($Path)) { return $null }
    $names = @{}
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $reader = [System.IO.StreamReader]::new($stream)
            try {
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ($line.IndexOf('thread_name', [StringComparison]::Ordinal) -lt 0) { continue }
                    try {
                        $row = $line | ConvertFrom-Json -ErrorAction Stop
                        $idProperty = $row.PSObject.Properties['id']
                        $nameProperty = $row.PSObject.Properties['thread_name']
                        if ($null -eq $idProperty -or $null -eq $nameProperty -or
                            $idProperty.Value -isnot [string] -or $nameProperty.Value -isnot [string]) { continue }
                        $parsedId = [guid]::Empty
                        $name = ($nameProperty.Value -replace '\s+', ' ').Trim()
                        if ([guid]::TryParse($idProperty.Value, [ref]$parsedId) -and
                            $name.Length -gt 0 -and $name.Length -le 500) {
                            $names[$parsedId.ToString()] = $name
                        }
                    }
                    catch { }
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch { return $null }
    return $names
}

function Get-ActiveTaskCandidates {
    param(
        [object[]]$Files,
        [AllowNull()]$Names,
        [Parameter(Mandatory)][datetime]$Now
    )

    if ($null -eq $Names) { return @() }
    $cutoff = $Now.ToUniversalTime().AddMinutes(-30)
    $seen = @{}
    $result = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in @($Files | Sort-Object LastWriteTimeUtc -Descending)) {
        try { $updatedAt = ([datetime]$file.LastWriteTimeUtc).ToUniversalTime() }
        catch { continue }
        if ($updatedAt -lt $cutoff -or
            $file.BaseName -notmatch '([0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12})$') { continue }
        $id = ([guid]$Matches[1]).ToString()
        if ($seen.ContainsKey($id) -or -not $Names.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $result.Add([pscustomobject]@{
            Id        = $id
            Name      = $Names[$id]
            FullName  = $file.FullName
            UpdatedAt = $updatedAt
        })
    }
    return $result.ToArray()
}

function Read-SessionEvents {
    param(
        [Parameter(Mandatory)][string]$Path,
        [long]$TailBytes = 0,
        [ref]$ReadFailed
    )

    if ($null -ne $ReadFailed) { $ReadFailed.Value = $false }
    $events = New-Object 'System.Collections.Generic.List[object]'
    try {
        $stream = [System.IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $truncated = $TailBytes -gt 0 -and $stream.Length -gt $TailBytes
            if ($truncated) { [void]$stream.Seek(-$TailBytes, [System.IO.SeekOrigin]::End) }
            $reader = New-Object System.IO.StreamReader($stream)
            try {
                if ($truncated) { [void]$reader.ReadLine() } # discard the partial first JSONL record
                while (($line = $reader.ReadLine()) -ne $null) {
                    if ($line.IndexOf('rate_limits', [System.StringComparison]::Ordinal) -lt 0) { continue }
                    try { $events.Add(($line | ConvertFrom-Json -ErrorAction Stop)) } catch { }
                }
            }
            finally { $reader.Dispose() }
        }
        finally { $stream.Dispose() }
    }
    catch {
        if ($null -ne $ReadFailed) { $ReadFailed.Value = $true }
    }
    return $events.ToArray()
}

function Get-NewestUsageState {
    param(
        [object[]]$Events,
        [AllowNull()][string]$LimitId
    )

    $newest = $null
    $matchingStates = New-Object 'System.Collections.Generic.List[object]'
    $legacyStates = New-Object 'System.Collections.Generic.List[object]'
    $filterByLimit = $PSBoundParameters.ContainsKey('LimitId')
    if ($filterByLimit -and [string]::IsNullOrWhiteSpace($LimitId)) {
        throw [ArgumentException]::new('LimitId must not be empty.', 'LimitId')
    }
    foreach ($event in $Events) {
        try {
            $timestamp = ConvertTo-ObservedAt $event.PSObject.Properties['timestamp'].Value
            $rateLimits = Get-EventRateLimits $event
            if ($null -eq $timestamp -or $null -eq $rateLimits) { continue }

            $rateLimitObject = if ($rateLimits -is [string]) {
                $rateLimits | ConvertFrom-Json -ErrorAction Stop
            }
            else { $rateLimits }
            $limitIdProperty = $rateLimitObject.PSObject.Properties['limit_id']
            $isLegacyLimit = $null -eq $limitIdProperty -or $null -eq $limitIdProperty.Value
            if ($filterByLimit -and -not $isLegacyLimit) {
                if ($limitIdProperty.Value -isnot [string] -or
                    [string]::IsNullOrWhiteSpace($limitIdProperty.Value) -or
                    $limitIdProperty.Value -ne $LimitId) { continue }
            }

            $json = if ($rateLimits -is [string]) { $rateLimits } else { $rateLimitObject | ConvertTo-Json -Depth 10 -Compress }
            $state = ConvertTo-UsageState -Json $json
            $state | Add-Member -NotePropertyName TokenDetails -NotePropertyValue (Get-EventTokenDetails $event)
            $state | Add-Member -NotePropertyName ObservedAt -NotePropertyValue $timestamp
            if ($filterByLimit) {
                if ($isLegacyLimit) { $legacyStates.Add($state) }
                else { $matchingStates.Add($state) }
            }
            elseif ($null -eq $newest -or $state.ObservedAt -gt $newest.ObservedAt) { $newest = $state }
        }
        catch { }
    }
    if (-not $filterByLimit) { return $newest }

    $states = if ($matchingStates.Count -gt 0) { $matchingStates.ToArray() } else { $legacyStates.ToArray() }
    if ($states.Count -eq 0) { return $null }

    $selectedWindows = New-Object 'System.Collections.Generic.List[object]'
    $currentStates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($name in 'primary', 'secondary') {
        $observations = New-Object 'System.Collections.Generic.List[object]'
        foreach ($state in $states) {
            foreach ($window in @($state.LimitWindows | Where-Object Name -eq $name)) {
                $observations.Add([pscustomobject]@{ State = $state; Window = $window })
            }
        }
        if ($observations.Count -eq 0) { continue }

        $cycle = ($observations.ToArray() |
            Sort-Object { [datetime]$_.Window.ResetAt } -Descending |
            Select-Object -First 1).Window.ResetAt
        $cycleObservations = @($observations.ToArray() |
            Where-Object { [datetime]$_.Window.ResetAt -eq [datetime]$cycle })
        $winner = $cycleObservations |
            Sort-Object @{ Expression = { [double]$_.Window.UsedPercent }; Descending = $true },
                        @{ Expression = { [datetime]$_.State.ObservedAt }; Descending = $true } |
            Select-Object -First 1
        $selectedWindows.Add($winner.Window)
        foreach ($observation in $cycleObservations) { $currentStates.Add($observation.State) }
    }
    if ($selectedWindows.Count -eq 0) { return $null }

    $sourceState = $currentStates.ToArray() | Sort-Object ObservedAt -Descending | Select-Object -First 1
    return [pscustomobject]@{
        LimitWindows = $selectedWindows.ToArray()
        TokenDetails = $sourceState.TokenDetails
        ObservedAt   = $sourceState.ObservedAt
    }
}

function ConvertTo-CodexDataDirectoryPath {
    param([Parameter(Mandatory)][AllowNull()]$Path)

    if ($Path -isnot [string] -or [string]::IsNullOrWhiteSpace($Path) -or $Path.Length -gt 1024 -or
        -not [System.IO.Path]::IsPathRooted($Path)) { return $null }
    try { return [System.IO.Path]::GetFullPath($Path.Trim()) }
    catch { return $null }
}

function Resolve-CodexDataDirectory {
    param(
        [AllowNull()]$SavedDirectory,
        [AllowNull()]$CodexHome,
        [AllowNull()]$UserProfile
    )

    $profilePath = ConvertTo-CodexDataDirectoryPath $UserProfile
    $defaultDirectory = if ($null -ne $profilePath) { Join-Path $profilePath '.codex' } else { $null }
    foreach ($candidate in $SavedDirectory, $CodexHome, $defaultDirectory) {
        $directory = ConvertTo-CodexDataDirectoryPath $candidate
        if ($null -ne $directory -and [System.IO.Directory]::Exists((Join-Path $directory 'sessions'))) {
            return $directory
        }
    }
    return $null
}

function Get-CodexUsageState {
    param([AllowNull()][string]$DataDirectory)

    if (-not $PSBoundParameters.ContainsKey('DataDirectory')) {
        $DataDirectory = Resolve-CodexDataDirectory $null $env:CODEX_HOME $env:USERPROFILE
    }
    $sessionsPath = if (-not [string]::IsNullOrWhiteSpace($DataDirectory)) { Join-Path $DataDirectory 'sessions' } else { $null }
    $events = New-Object 'System.Collections.Generic.List[object]'
    $sessionTokenSnapshots = New-Object 'System.Collections.Generic.List[object]'
    $activeTasks = New-Object 'System.Collections.Generic.List[object]'
    $script:CodexUsageDiagnostic = $null
    if (-not [System.IO.Directory]::Exists($sessionsPath)) {
        $script:CodexUsageDiagnostic = 'missing_directory'
        return $null
    }

    try {
        $allFiles = @(Get-ChildItem -LiteralPath $sessionsPath -Recurse -File -Filter '*.jsonl' -ErrorAction Stop |
            Sort-Object LastWriteTimeUtc -Descending)
        $files = @($allFiles | Select-Object -First 30)
    }
    catch {
        $script:CodexUsageDiagnostic = 'read_failed'
        return $null
    }
    if ($files.Count -eq 0) {
        $script:CodexUsageDiagnostic = 'empty_directory'
        return $null
    }

    $taskIndexPath = Join-Path $DataDirectory 'session_index.jsonl'
    $taskNames = Read-TaskNameIndex $taskIndexPath
    $activeCandidates = @(Get-ActiveTaskCandidates -Files $allFiles -Names $taskNames -Now ([datetime]::UtcNow))
    $activeByPath = @{}
    foreach ($candidate in $activeCandidates) { $activeByPath[$candidate.FullName] = $candidate }
    $usagePaths = @{}
    $readPaths = @{}
    $filesToRead = New-Object 'System.Collections.Generic.List[object]'
    foreach ($file in $files) {
        $filesToRead.Add($file)
        $usagePaths[$file.FullName] = $true
        $readPaths[$file.FullName] = $true
    }
    foreach ($candidate in $activeCandidates) {
        if ($readPaths.ContainsKey($candidate.FullName)) { continue }
        $filesToRead.Add([pscustomobject]@{
            FullName = $candidate.FullName
            BaseName = [System.IO.Path]::GetFileNameWithoutExtension($candidate.FullName)
        })
        $readPaths[$candidate.FullName] = $true
    }

    $readFailed = $false
    $isNewestCandidate = $true
    foreach ($file in $filesToRead) {
        $fileReadFailed = $false
        $fileEvents = @(Read-SessionEvents -Path $file.FullName -TailBytes 262144 -ReadFailed ([ref]$fileReadFailed))
        if ($fileReadFailed) { $readFailed = $true }
        $fileState = Get-NewestUsageState -Events $fileEvents
        if ($isNewestCandidate -and $null -eq $fileState) {
            # ponytail: one 1 MiB retry bounds fallback I/O; enlarge only if Codex records outgrow it.
            $fileEvents = @(Read-SessionEvents -Path $file.FullName -TailBytes 1048576 -ReadFailed ([ref]$fileReadFailed))
            if ($fileReadFailed) { $readFailed = $true }
            $fileState = Get-NewestUsageState -Events $fileEvents
        }
        if ($usagePaths.ContainsKey($file.FullName)) {
            if ($null -ne $fileState -and $null -ne $fileState.TokenDetails) {
                $sessionTokenSnapshots.Add([pscustomobject]@{
                    Id              = $file.BaseName
                    CacheHitTokens  = $fileState.TokenDetails.CacheHitTokens
                    CacheMissTokens = $fileState.TokenDetails.CacheMissTokens
                })
            }
            foreach ($event in $fileEvents) { $events.Add($event) }
        }
        if ($activeByPath.ContainsKey($file.FullName)) {
            $candidate = $activeByPath[$file.FullName]
            $activeTasks.Add([pscustomobject]@{
                Id           = $candidate.Id
                Name         = $candidate.Name
                UpdatedAt    = $candidate.UpdatedAt
                TokenDetails = if ($null -ne $fileState) { $fileState.TokenDetails } else { $null }
            })
        }
        $isNewestCandidate = $false
    }
    $state = Get-NewestUsageState -Events $events.ToArray() -LimitId 'codex'
    if ($null -ne $state) {
        $cacheTotals = Update-CumulativeCacheTokens $sessionTokenSnapshots.ToArray()
        if ($null -ne $cacheTotals) {
            if ($null -eq $state.TokenDetails) { $state.TokenDetails = [pscustomobject]@{} }
            foreach ($name in 'CacheHitTokens', 'CacheMissTokens', 'CacheHitPercent', 'CacheMissPercent') {
                $state.TokenDetails | Add-Member -NotePropertyName $name -NotePropertyValue $cacheTotals.$name -Force
            }
        }
        $state | Add-Member -NotePropertyName ActiveTasks -NotePropertyValue $activeTasks.ToArray()
        $state | Add-Member -NotePropertyName TaskNamesAvailable -NotePropertyValue ($null -ne $taskNames)
        $script:CodexUsageDiagnostic = $null
        return $state
    }
    $script:CodexUsageDiagnostic = if ($readFailed) { 'read_failed' } else { 'no_valid_event' }
    return $state
}

function Get-CodexUsageDiagnostic {
    return $script:CodexUsageDiagnostic
}

function Get-CodexUsageSnapshot {
    param([AllowNull()][string]$DataDirectory)

    $state = if ($PSBoundParameters.ContainsKey('DataDirectory')) {
        Get-CodexUsageState -DataDirectory $DataDirectory
    } else {
        Get-CodexUsageState
    }
    [pscustomobject]@{
        State      = $state
        Diagnostic = Get-CodexUsageDiagnostic
    }
}

function Resolve-UsageRefreshResult {
    param(
        [AllowNull()]$Snapshot,
        [Parameter(Mandatory)][int]$ErrorCount
    )

    $failure = [pscustomobject]@{ State = $null; Diagnostic = 'read_failed' }
    if ($ErrorCount -ne 0 -or $null -eq $Snapshot) { return $failure }
    $stateProperty = $Snapshot.PSObject.Properties['State']
    $diagnosticProperty = $Snapshot.PSObject.Properties['Diagnostic']
    if ($null -eq $stateProperty -or $null -eq $diagnosticProperty) { return $failure }

    $state = $stateProperty.Value
    $diagnostic = $diagnosticProperty.Value
    if ($null -ne $state) {
        if ($null -ne $diagnostic -or $null -eq $state.PSObject.Properties['LimitWindows'] -or
            $null -eq $state.PSObject.Properties['TokenDetails'] -or
            $null -eq $state.PSObject.Properties['ObservedAt']) { return $failure }
        return [pscustomobject]@{ State = $state; Diagnostic = $null }
    }
    if ($diagnostic -notin 'missing_directory', 'empty_directory', 'read_failed', 'no_valid_event') { return $failure }
    return [pscustomobject]@{ State = $null; Diagnostic = $diagnostic }
}

function Get-UsageWorkerFunctionNames {
    @(
        'ConvertTo-LimitWindow',
        'ConvertTo-UsageState',
        'ConvertTo-ObservedAt',
        'Get-TokenNumber',
        'Get-TokenPercent',
        'Get-EventTokenDetails',
        'Get-EventRateLimits',
        'Read-TaskNameIndex',
        'Get-ActiveTaskCandidates',
        'Read-SessionEvents',
        'Get-NewestUsageState',
        'ConvertTo-CodexDataDirectoryPath',
        'Resolve-CodexDataDirectory',
        'Save-TextAtomically',
        'Update-CumulativeCacheTokens',
        'Get-CodexUsageState',
        'Get-CodexUsageDiagnostic',
        'Get-CodexUsageSnapshot'
    )
}

function Save-TextAtomically {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text
    )

    $saved = $false
    $temporaryPath = $null
    $backupPath = $null
    try {
        $directory = [System.IO.Path]::GetDirectoryName($Path)
        [void][System.IO.Directory]::CreateDirectory($directory)
        $fileId = [guid]::NewGuid().ToString('N')
        $fileName = [System.IO.Path]::GetFileName($Path)
        $temporaryPath = Join-Path $directory ($fileName + '.' + $fileId + '.tmp')
        [System.IO.File]::WriteAllText($temporaryPath, $Text, [System.Text.UTF8Encoding]::new($false))
        if ([System.IO.File]::Exists($Path)) {
            $backupPath = Join-Path $directory ($fileName + '.' + $fileId + '.bak')
            [System.IO.File]::Replace($temporaryPath, $Path, $backupPath)
            $temporaryPath = $null
            $saved = $true
            try { [System.IO.File]::Delete($backupPath) } catch { }
            if (-not [System.IO.File]::Exists($backupPath)) { $backupPath = $null }
        }
        else {
            [System.IO.File]::Move($temporaryPath, $Path)
            $temporaryPath = $null
            $saved = $true
        }
    }
    catch { }
    finally {
        if ($null -ne $temporaryPath) {
            try {
                if ([System.IO.File]::Exists($temporaryPath)) { [System.IO.File]::Delete($temporaryPath) }
            }
            catch { }
        }
        if ($null -ne $backupPath -and [System.IO.File]::Exists($backupPath)) {
            try {
                if (-not [System.IO.File]::Exists($Path)) {
                    [System.IO.File]::Move($backupPath, $Path)
                }
                else {
                    [System.IO.File]::Delete($backupPath)
                }
            }
            catch { }
        }
    }
    return $saved
}

function Get-WidgetLanguageCodes { @('zh-CN', 'zh-TW', 'en-US', 'ja-JP', 'ko-KR') }

function Get-WidgetRequiredLanguageKeys {
    @(
        'app.title', 'app.alreadyRunning',
        'menu.showWidget', 'menu.showDetails', 'menu.hideDetails', 'menu.language', 'menu.exit',
        'language.zh-CN', 'language.zh-TW', 'language.en-US', 'language.ja-JP', 'language.ko-KR',
        'theme.glacier', 'theme.nebula', 'theme.ocean', 'theme.sakura', 'theme.aurora', 'theme.mica', 'theme.sunset', 'theme.lime',
        'detail.title', 'detail.remaining', 'detail.observed', 'detail.status',
        'activity.title', 'activity.window30m', 'activity.empty30m', 'activity.namesUnavailable',
        'task.noTokenData', 'task.activePrefix',
        'token.total', 'token.context', 'token.contextUsage', 'token.composition', 'token.input', 'token.output', 'token.reasoningShare',
        'cache.hit', 'cache.miss', 'cache.taskHit', 'cache.taskMiss', 'cache.localHit', 'cache.localMiss',
        'status.waitingObservation', 'status.observationNormal', 'status.sufficient', 'status.attention', 'status.critical', 'status.waiting', 'status.unavailable', 'status.noData',
        'diagnostic.missingDirectory', 'diagnostic.emptyDirectory', 'diagnostic.readFailed', 'diagnostic.noValidEvent', 'diagnostic.unavailable',
        'limit.unknown', 'limit.days', 'limit.hours', 'limit.minutes',
        'countdown.daysHours', 'countdown.hoursMinutes', 'countdown.minutes', 'countdown.waiting',
        'number.tenThousand', 'number.hundredMillion', 'number.thousand', 'number.million', 'number.billion',
        'composition.values', 'cache.value',
        'reminder.title', 'reminder.body',
        'picker.description', 'picker.openFailed', 'picker.invalidDirectory',
        'fatal.template', 'fatal.startProblem', 'fatal.unsupportedHost', 'fatal.unsupportedThread',
        'fatal.uiLoadCause', 'fatal.mutexCause', 'fatal.windowCause', 'fatal.notificationCause', 'fatal.workerCause',
        'fatal.useLauncherFix', 'fatal.exitOldFix', 'fatal.uiRepairFix', 'fatal.restartNotificationFix', 'fatal.restoreFix',
        'accessibility.ringName', 'accessibility.ringHelp', 'accessibility.localObservation', 'accessibility.waitingState', 'accessibility.unavailableState',
        'accessibility.criticalState', 'accessibility.attentionState', 'accessibility.normalState', 'accessibility.usageSummary', 'accessibility.activeTask'
    )
}

function Read-WidgetLanguagePack {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Root
    )

    if ($Code -cnotin @(Get-WidgetLanguageCodes)) { throw [ArgumentException]::new('Unsupported language code.', 'Code') }
    $path = Join-Path $Root ('locales\' + $Code + '.json')
    $file = [System.IO.FileInfo]::new($path)
    if (-not $file.Exists) { throw [System.IO.FileNotFoundException]::new('Language pack not found.', $path) }
    if ($file.Length -gt 262144) { throw [System.IO.InvalidDataException]::new('Language pack exceeds 256 KiB.') }

    $pack = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
    if ($pack -isnot [pscustomobject]) { throw [System.IO.InvalidDataException]::new('Language pack root must be an object.') }
    $codeProperty = $pack.PSObject.Properties['code']
    $cultureProperty = $pack.PSObject.Properties['culture']
    $nativeNameProperty = $pack.PSObject.Properties['nativeName']
    $stringsProperty = $pack.PSObject.Properties['strings']
    if ($null -eq $codeProperty -or $codeProperty.Value -isnot [string] -or $codeProperty.Value -cne $Code -or
        $null -eq $cultureProperty -or $cultureProperty.Value -isnot [string] -or $cultureProperty.Value -cne $Code -or
        $null -eq $nativeNameProperty -or $nativeNameProperty.Value -isnot [string] -or
        $nativeNameProperty.Value.Length -lt 1 -or $nativeNameProperty.Value.Length -gt 64 -or
        $null -eq $stringsProperty -or $stringsProperty.Value -isnot [pscustomobject]) {
        throw [System.IO.InvalidDataException]::new('Language pack metadata is invalid.')
    }

    $required = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    foreach ($key in Get-WidgetRequiredLanguageKeys) { $required[$key] = $true }
    $strings = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    foreach ($property in $stringsProperty.Value.PSObject.Properties) {
        if (-not $required.ContainsKey($property.Name)) { continue }
        if ($property.Value -isnot [string] -or $property.Value.Length -gt 1000) {
            throw [System.IO.InvalidDataException]::new('Language-pack strings must be strings no longer than 1000 characters.')
        }
        if ([string]::IsNullOrWhiteSpace($property.Value)) { continue }
        if ($property.Name -ceq 'app.title' -and $property.Value.Length -ge 64) {
            throw [System.IO.InvalidDataException]::new('Language-pack app.title must be shorter than 64 characters.')
        }
        $strings[$property.Name] = [string]$property.Value
    }
    return [pscustomobject]@{
        Code = [string]$codeProperty.Value
        NativeName = [string]$nativeNameProperty.Value
        Culture = [string]$cultureProperty.Value
        Strings = $strings
    }
}

function Resolve-WidgetLanguageCode {
    param(
        [AllowNull()]$SavedLanguage,
        [Parameter(Mandatory)][cultureinfo]$UiCulture
    )

    if ($SavedLanguage -is [string] -and $SavedLanguage -cin @(Get-WidgetLanguageCodes)) { return $SavedLanguage }
    $name = $UiCulture.Name
    if ($name -match '^zh-(Hans|CN|SG)') { return 'zh-CN' }
    if ($name -match '^zh-(Hant|TW|HK|MO)') { return 'zh-TW' }
    if ($name -match '^ja(?:-|$)') { return 'ja-JP' }
    if ($name -match '^ko(?:-|$)') { return 'ko-KR' }
    return 'en-US'
}

function Initialize-WidgetLocalization {
    param(
        [Parameter(Mandatory)][string]$Root,
        [AllowNull()]$SavedLanguage,
        [Parameter(Mandatory)][cultureinfo]$UiCulture
    )

    try {
        $english = Read-WidgetLanguagePack 'en-US' $Root
        foreach ($key in Get-WidgetRequiredLanguageKeys) {
            if (-not $english.Strings.ContainsKey($key)) { throw [System.IO.InvalidDataException]::new('English language pack is incomplete.') }
            try { [void][string]::Format([cultureinfo]::InvariantCulture, $english.Strings[$key], [object[]](0..9)) }
            catch { throw [System.IO.InvalidDataException]::new('English language pack has an invalid format string.', $_.Exception) }
        }
    }
    catch {
        throw [System.IO.InvalidDataException]::new('English language pack is unavailable or invalid. / 英语语言包缺失或无效。', $_.Exception)
    }

    $packs = [Collections.Hashtable]::new([StringComparer]::Ordinal)
    $packs['en-US'] = $english
    foreach ($code in Get-WidgetLanguageCodes) {
        if ($code -ceq 'en-US') { continue }
        $path = Join-Path $Root ('locales\' + $code + '.json')
        if (-not [System.IO.File]::Exists($path)) { continue }
        try {
            $pack = Read-WidgetLanguagePack $code $Root
            foreach ($key in @($pack.Strings.Keys)) {
                $englishPlaceholders = @([regex]::Matches($english.Strings[$key], '(?<!\{)\{[^{}]+\}(?!\})') | ForEach-Object Value | Sort-Object)
                $translatedPlaceholders = @([regex]::Matches($pack.Strings[$key], '(?<!\{)\{[^{}]+\}(?!\})') | ForEach-Object Value | Sort-Object)
                try { [void][string]::Format([cultureinfo]::InvariantCulture, $pack.Strings[$key], [object[]](0..9)) }
                catch { [void]$pack.Strings.Remove($key); continue }
                if (($englishPlaceholders -join "`n") -cne ($translatedPlaceholders -join "`n")) { [void]$pack.Strings.Remove($key) }
            }
            $packs[$code] = $pack
        }
        catch { }
    }

    $selectedCode = Resolve-WidgetLanguageCode $SavedLanguage $UiCulture
    if (-not $packs.ContainsKey($selectedCode)) { $selectedCode = 'en-US' }
    $script:WidgetLanguagePacks = $packs
    $script:CurrentLanguageCode = $selectedCode
    $script:CurrentLanguageCulture = [cultureinfo]::GetCultureInfo($packs[$selectedCode].Culture)
}

function Get-WidgetText {
    param(
        [Parameter(Mandatory)][string]$Key,
        [object[]]$Arguments
    )

    if ($null -eq $script:WidgetLanguagePacks) { throw [InvalidOperationException]::new('Widget localization is not initialized.') }
    $text = $script:WidgetLanguagePacks[$script:CurrentLanguageCode].Strings[$Key]
    if ($null -eq $text) { $text = $script:WidgetLanguagePacks['en-US'].Strings[$Key] }
    if ($null -eq $text) { throw [Collections.Generic.KeyNotFoundException]::new('Unknown widget language key: ' + $Key) }
    if ($PSBoundParameters.ContainsKey('Arguments')) { return [string]::Format($script:CurrentLanguageCulture, $text, $Arguments) }
    return $text
}

function Update-CumulativeCacheTokens {
    param([object[]]$Sessions)

    $toCounter = {
        param([AllowNull()]$Value)
        if ($null -eq $Value -or $Value -is [bool] -or $Value -isnot [System.ValueType]) { return $null }
        try { $number = [double]$Value } catch { return $null }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or
            $number -ne [math]::Truncate($number) -or $number -gt [long]::MaxValue) { return $null }
        return [long]$number
    }

    if ($null -eq $script:CacheTokenLedger) {
        $knownSessions = @{}
        try {
            $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'cache-token-ledger.json'
            if ([System.IO.File]::Exists($path)) {
                $stored = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
                $storedSessions = $stored.PSObject.Properties['Sessions']
                if ($null -eq $storedSessions) { throw 'Missing sessions.' }
                $loaded = 0
                foreach ($item in @($storedSessions.Value)) {
                    if ($loaded++ -ge 10000) { break }
                    $idProperty = $item.PSObject.Properties['Id']
                    $hitProperty = $item.PSObject.Properties['CacheHitTokens']
                    $missProperty = $item.PSObject.Properties['CacheMissTokens']
                    if ($null -eq $idProperty -or $idProperty.Value -isnot [string] -or
                        $idProperty.Value -cnotmatch '^[A-Za-z0-9._-]{1,200}$' -or
                        $null -eq $hitProperty -or $null -eq $missProperty) { continue }
                    $hit = & $toCounter $hitProperty.Value
                    $miss = & $toCounter $missProperty.Value
                    if ($null -eq $hit -or $null -eq $miss) { continue }
                    $knownSessions[$idProperty.Value] = [pscustomobject]@{
                        CacheHitTokens  = $hit
                        CacheMissTokens = $miss
                    }
                }
            }
        }
        catch { $knownSessions = @{} }
        # ponytail: the single persistent refresh worker owns this ledger; add locking only if refreshes become concurrent.
        $script:CacheTokenLedger = [pscustomobject]@{ Sessions = $knownSessions; Dirty = $false }
    }

    foreach ($session in @($Sessions)) {
        if ($null -eq $session) { continue }
        $idProperty = $session.PSObject.Properties['Id']
        $hitProperty = $session.PSObject.Properties['CacheHitTokens']
        $missProperty = $session.PSObject.Properties['CacheMissTokens']
        if ($null -eq $idProperty -or $idProperty.Value -isnot [string] -or
            $idProperty.Value -cnotmatch '^[A-Za-z0-9._-]{1,200}$' -or
            $null -eq $hitProperty -or $null -eq $missProperty) { continue }
        $hit = & $toCounter $hitProperty.Value
        $miss = & $toCounter $missProperty.Value
        if ($null -eq $hit -or $null -eq $miss) { continue }

        $previous = $script:CacheTokenLedger.Sessions[$idProperty.Value]
        $nextHit = if ($null -eq $previous -or $hit -gt $previous.CacheHitTokens) { $hit } else { [long]$previous.CacheHitTokens }
        $nextMiss = if ($null -eq $previous -or $miss -gt $previous.CacheMissTokens) { $miss } else { [long]$previous.CacheMissTokens }
        if ($null -eq $previous -or $nextHit -ne $previous.CacheHitTokens -or $nextMiss -ne $previous.CacheMissTokens) {
            $script:CacheTokenLedger.Sessions[$idProperty.Value] = [pscustomobject]@{
                CacheHitTokens  = $nextHit
                CacheMissTokens = $nextMiss
            }
            $script:CacheTokenLedger.Dirty = $true
        }
    }

    if ($script:CacheTokenLedger.Dirty) {
        try {
            $storedSessions = @(
                foreach ($id in @($script:CacheTokenLedger.Sessions.Keys | Sort-Object)) {
                    $tokens = $script:CacheTokenLedger.Sessions[$id]
                    [pscustomobject]@{
                        Id              = $id
                        CacheHitTokens  = [long]$tokens.CacheHitTokens
                        CacheMissTokens = [long]$tokens.CacheMissTokens
                    }
                }
            )
            $json = [pscustomobject]@{ Sessions = $storedSessions } | ConvertTo-Json -Depth 4 -Compress -ErrorAction Stop
            $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'cache-token-ledger.json'
            if (Save-TextAtomically -Path $path -Text $json) { $script:CacheTokenLedger.Dirty = $false }
        }
        catch { }
    }

    if ($script:CacheTokenLedger.Sessions.Count -eq 0) { return $null }
    $cacheHitTokens = 0.0
    $cacheMissTokens = 0.0
    foreach ($tokens in $script:CacheTokenLedger.Sessions.Values) {
        $cacheHitTokens += [double]$tokens.CacheHitTokens
        $cacheMissTokens += [double]$tokens.CacheMissTokens
    }
    $cacheHitPercent = Get-TokenPercent $cacheHitTokens ($cacheHitTokens + $cacheMissTokens)
    return [pscustomobject]@{
        CacheHitTokens  = $cacheHitTokens
        CacheMissTokens = $cacheMissTokens
        CacheHitPercent = $cacheHitPercent
        CacheMissPercent = if ($null -ne $cacheHitPercent) {
            [math]::Round(100.0 - $cacheHitPercent, 1, [MidpointRounding]::ToEven)
        } else { $null }
    }
}

function Get-ReminderGateState {
    if ($null -ne $script:ReminderGateCache) { return $script:ReminderGateCache }

    # ponytail: Prune expired keys on startup load; prune every write only if measured month-long residency grows the file.
    $sentKeys = @()
    try {
        $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'reminders.json'
        if ([System.IO.File]::Exists($path)) {
            $stored = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
            $sentKeysProperty = $stored.PSObject.Properties['SentKeys']
            if ($null -ne $sentKeysProperty) {
                $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                foreach ($value in @($sentKeysProperty.Value)) {
                    if ($value -isnot [string] -or $value -cnotmatch '^(primary|secondary)\|([0-9]+)\|(10|20)$') { continue }
                    $resetSeconds = 0L
                    if (-not [long]::TryParse($Matches[2], [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$resetSeconds) -or $resetSeconds -le $now) { continue }
                    try { [void][DateTimeOffset]::FromUnixTimeSeconds($resetSeconds) } catch { continue }
                    $key = '{0}|{1}|{2}' -f $Matches[1], $resetSeconds, $Matches[3]
                    if ($sentKeys -notcontains $key) { $sentKeys += $key }
                }
            }
        }
    }
    catch { $sentKeys = @() }

    $script:ReminderGateCache = [pscustomobject]@{ SentKeys = $sentKeys }
    return $script:ReminderGateCache
}

function Save-ReminderGateState {
    param([Parameter(Mandatory)]$State)

    $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'reminders.json'
    $json = [pscustomobject]@{ SentKeys = @($State.SentKeys) } | ConvertTo-Json -Compress
    return Save-TextAtomically -Path $path -Text $json
}

function Register-UsageReminderThreshold {
    param(
        [Parameter(Mandatory)][AllowNull()]$State,
        [Parameter(Mandatory)][ValidateSet(10, 20)][int]$Threshold
    )

    if ($null -eq $State) { return $false }
    $name = $State.PSObject.Properties['Name'].Value
    $remaining = $State.PSObject.Properties['RemainingPercent'].Value
    $resetValue = $State.PSObject.Properties['ResetAt'].Value
    if ($name -cnotin 'primary', 'secondary' -or $null -eq $remaining -or $remaining -is [bool] -or $remaining -isnot [System.ValueType] -or
        ($resetValue -isnot [datetime] -and $resetValue -isnot [datetimeoffset])) { return $false }

    try { $remainingPercent = [double]$remaining } catch { return $false }
    if ([double]::IsNaN($remainingPercent) -or [double]::IsInfinity($remainingPercent) -or $remainingPercent -lt 0 -or $remainingPercent -gt 100) {
        return $false
    }

    try {
        $resetAt = ([DateTimeOffset]$resetValue).ToUniversalTime()
        $now = [DateTimeOffset]::UtcNow
        $resetSeconds = $resetAt.ToUnixTimeSeconds()
    }
    catch { return $false }
    if ($resetAt -le $now -or $resetSeconds -le $now.ToUnixTimeSeconds()) { return $false }
    $key = '{0}|{1}|{2}' -f $name, $resetSeconds, $Threshold
    $gate = Get-ReminderGateState
    if ($remainingPercent -gt $Threshold -or $gate.SentKeys -contains $key) { return $false }
    $gate.SentKeys = @($gate.SentKeys) + $key
    [void](Save-ReminderGateState $gate)
    return $true
}

function Get-WidgetThemes {
    @(
        [pscustomobject]@{ NameKey = 'theme.glacier'; Start = '#7BFFE0'; End = '#55CFFF' },
        [pscustomobject]@{ NameKey = 'theme.nebula'; Start = '#D8A7FF'; End = '#7C8CFF' },
        [pscustomobject]@{ NameKey = 'theme.ocean'; Start = '#82D9FF'; End = '#4478FF' },
        [pscustomobject]@{ NameKey = 'theme.sakura'; Start = '#FFB1D8'; End = '#FF719D' },
        [pscustomobject]@{ NameKey = 'theme.aurora'; Start = '#7CFFB2'; End = '#38D989' },
        [pscustomobject]@{ NameKey = 'theme.mica'; Start = '#F1F5FF'; End = '#9DAAC3' },
        [pscustomobject]@{ NameKey = 'theme.sunset'; Start = '#FFC28A'; End = '#FF806D' },
        [pscustomobject]@{ NameKey = 'theme.lime'; Start = '#DCFF7C'; End = '#7DDB66' }
    )
}

function Get-WidgetPreferences {
    $preferences = [pscustomobject]@{ Left = $null; Top = $null; Monitor = $null; Theme = 0; CodexDataDirectory = $null; Language = $null }
    try {
        $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'preferences.json'
        if (-not [System.IO.File]::Exists($path)) { return $preferences }
        $stored = [System.IO.File]::ReadAllText($path) | ConvertFrom-Json -ErrorAction Stop
        foreach ($name in 'Left', 'Top') {
            $property = $stored.PSObject.Properties[$name]
            if ($null -eq $property -or $property.Value -is [bool] -or $property.Value -isnot [System.ValueType]) { continue }
            try { $value = [double]$property.Value } catch { continue }
            if (-not [double]::IsNaN($value) -and -not [double]::IsInfinity($value)) { $preferences.$name = $value }
        }
        $monitor = $stored.PSObject.Properties['Monitor']
        if ($null -ne $monitor -and $monitor.Value -is [string] -and $monitor.Value.Length -le 256 -and -not [string]::IsNullOrWhiteSpace($monitor.Value)) {
            $preferences.Monitor = $monitor.Value
        }
        $codexDataDirectory = $stored.PSObject.Properties['CodexDataDirectory']
        if ($null -ne $codexDataDirectory) {
            $preferences.CodexDataDirectory = ConvertTo-CodexDataDirectoryPath $codexDataDirectory.Value
        }
        $language = $stored.PSObject.Properties['Language']
        if ($null -ne $language -and $language.Value -is [string] -and @(Get-WidgetLanguageCodes) -ccontains $language.Value) {
            $preferences.Language = $language.Value
        }
        $themeCount = @(Get-WidgetThemes).Count
        $theme = $stored.PSObject.Properties['Theme']
        if ($null -ne $theme -and $theme.Value -isnot [bool] -and $theme.Value -is [System.ValueType]) {
            try { $themeValue = [double]$theme.Value } catch { $themeValue = -1 }
            if (-not [double]::IsNaN($themeValue) -and -not [double]::IsInfinity($themeValue) -and $themeValue -eq [Math]::Floor($themeValue) -and $themeValue -ge 0 -and $themeValue -lt $themeCount) {
                $preferences.Theme = [int]$themeValue
            }
        }
    }
    catch { }
    return $preferences
}

function Save-WidgetPreferences {
    param(
        [Parameter(Mandatory)]$Left,
        [Parameter(Mandatory)]$Top,
        [Parameter(Mandatory)][AllowNull()]$Monitor,
        [Parameter(Mandatory)]$Theme,
        [AllowNull()]$CodexDataDirectory = $null,
        [AllowNull()][string]$Language = $null
    )

    if ($Left -is [bool] -or $Left -isnot [System.ValueType] -or
        $Top -is [bool] -or $Top -isnot [System.ValueType] -or
        $Theme -is [bool] -or $Theme -isnot [System.ValueType] -or
        ($null -ne $Monitor -and ($Monitor -isnot [string] -or $Monitor.Length -gt 256 -or [string]::IsNullOrWhiteSpace($Monitor))) -or
        ($null -ne $Language -and @(Get-WidgetLanguageCodes) -cnotcontains $Language)) { return $false }
    $codexDataDirectoryPath = ConvertTo-CodexDataDirectoryPath $CodexDataDirectory
    if ($null -ne $CodexDataDirectory -and $null -eq $codexDataDirectoryPath) { return $false }
    try {
        $leftValue = [double]$Left
        $topValue = [double]$Top
        $themeValue = [double]$Theme
    }
    catch { return $false }
    $themeCount = @(Get-WidgetThemes).Count
    if ([double]::IsNaN($leftValue) -or [double]::IsInfinity($leftValue) -or
        [double]::IsNaN($topValue) -or [double]::IsInfinity($topValue) -or
        [double]::IsNaN($themeValue) -or [double]::IsInfinity($themeValue) -or
        $themeValue -ne [Math]::Floor($themeValue) -or $themeValue -lt 0 -or $themeValue -ge $themeCount) { return $false }
    $path = Join-Path (Join-Path $env:LOCALAPPDATA 'CodexUsageWidget') 'preferences.json'
    $json = [pscustomobject]@{
        Left = $leftValue; Top = $topValue; Monitor = $Monitor; Theme = [int]$themeValue
        CodexDataDirectory = $codexDataDirectoryPath
        Language = $Language
    } | ConvertTo-Json -Compress
    return Save-TextAtomically -Path $path -Text $json
}

function Get-SnappedWidgetPosition {
    param(
        [Parameter(Mandatory)][double]$Left,
        [Parameter(Mandatory)][double]$Top,
        [Parameter(Mandatory)][double]$Width,
        [Parameter(Mandatory)][double]$Height,
        [Parameter(Mandatory)][double]$VisibleSize,
        [Parameter(Mandatory)]$WorkArea
    )

    $horizontalInset = ($Width - $VisibleSize) / 2
    $verticalInset = ($Height - $VisibleSize) / 2
    $workRight = [double]$WorkArea.Left + [double]$WorkArea.Width
    $workBottom = [double]$WorkArea.Top + [double]$WorkArea.Height
    $distances = [ordered]@{
        Left   = [Math]::Abs(($Left + $horizontalInset) - [double]$WorkArea.Left)
        Right  = [Math]::Abs(($Left + $Width - $horizontalInset) - $workRight)
        Top    = [Math]::Abs(($Top + $verticalInset) - [double]$WorkArea.Top)
        Bottom = [Math]::Abs(($Top + $Height - $verticalInset) - $workBottom)
    }
    $edge = $null
    $nearest = [double]::PositiveInfinity
    foreach ($candidate in $distances.Keys) {
        if ($distances[$candidate] -lt $nearest) {
            $edge = $candidate
            $nearest = $distances[$candidate]
        }
    }
    if ($nearest -gt 28) { $edge = $null }
    switch ($edge) {
        'Left' { $Left = [double]$WorkArea.Left + 8 - $horizontalInset }
        'Right' { $Left = $workRight - 8 - $Width + $horizontalInset }
        'Top' { $Top = [double]$WorkArea.Top + 8 - $verticalInset }
        'Bottom' { $Top = $workBottom - 8 - $Height + $verticalInset }
    }
    return [pscustomobject]@{ Left = $Left; Top = $Top; Edge = $edge }
}

function Get-DetailPopupPosition {
    param(
        [Parameter(Mandatory)][double]$CircleLeft,
        [Parameter(Mandatory)][double]$CircleTop,
        [Parameter(Mandatory)][double]$CircleSize,
        [Parameter(Mandatory)][double]$CardWidth,
        [Parameter(Mandatory)][double]$CardHeight,
        [Parameter(Mandatory)]$WorkArea
    )

    $right = if ($null -ne $WorkArea.PSObject.Properties['Right']) {
        [double]$WorkArea.Right
    } else {
        [double]$WorkArea.Left + [double]$WorkArea.Width
    }
    $bottom = if ($null -ne $WorkArea.PSObject.Properties['Bottom']) {
        [double]$WorkArea.Bottom
    } else {
        [double]$WorkArea.Top + [double]$WorkArea.Height
    }
    $cardWidthValue = [Math]::Min($CardWidth, [Math]::Max(1, $right - [double]$WorkArea.Left - 16))
    $cardHeightValue = [Math]::Min($CardHeight, [Math]::Max(1, $bottom - [double]$WorkArea.Top - 16))
    $rightSpace = $right - ($CircleLeft + $CircleSize)
    $leftSpace = $CircleLeft - [double]$WorkArea.Left
    $opensLeft = $rightSpace -lt ($cardWidthValue + 12) -and $leftSpace -gt $rightSpace
    $left = if ($opensLeft) { $CircleLeft - 12 - $cardWidthValue } else { $CircleLeft + $CircleSize + 12 }
    $left = [Math]::Max([double]$WorkArea.Left + 8, [Math]::Min($right - 8 - $cardWidthValue, $left))
    $top = [Math]::Max([double]$WorkArea.Top + 8, [Math]::Min($bottom - 8 - $cardHeightValue, $CircleTop))
    return [pscustomobject]@{
        Left = $left; Top = $top; OpensLeft = $opensLeft
        CardWidth = $cardWidthValue; CardHeight = $cardHeightValue
    }
}

function Resolve-WidgetRestoreScreen {
    param(
        [AllowNull()]$RequestedScreen,
        [AllowNull()]$ActualScreen,
        [AllowNull()]$PrimaryScreen,
        [Parameter(Mandatory)][bool]$MoveSucceeded
    )

    if ($MoveSucceeded -and $null -ne $RequestedScreen -and $null -ne $ActualScreen -and
        [string]$RequestedScreen.DeviceName -eq [string]$ActualScreen.DeviceName) {
        return $RequestedScreen
    }
    if ($null -ne $ActualScreen) { return $ActualScreen }
    return $PrimaryScreen
}

function Test-ConversionFails {
    param([string]$Json, [string]$Name)

    try { ConvertTo-UsageState -Json $Json | Out-Null }
    catch { return }
    throw "Expected rejection: $Name"
}

function ConvertTo-FiniteWidgetNumber {
    param(
        [AllowNull()]$Value,
        [Parameter(Mandatory)][string]$Name
    )

    if ($null -eq $Value -or $Value.GetType().IsEnum -or [Type]::GetTypeCode($Value.GetType()) -notin
        [TypeCode]::SByte, [TypeCode]::Byte, [TypeCode]::Int16, [TypeCode]::UInt16,
        [TypeCode]::Int32, [TypeCode]::UInt32, [TypeCode]::Int64, [TypeCode]::UInt64,
        [TypeCode]::Single, [TypeCode]::Double, [TypeCode]::Decimal) {
        throw [ArgumentException]::new("$Name must be numeric.", $Name)
    }
    if ([Type]::GetTypeCode($Value.GetType()) -in [TypeCode]::Single, [TypeCode]::Double -and
        ([double]::IsNaN([double]$Value) -or [double]::IsInfinity([double]$Value))) {
        throw [ArgumentException]::new("$Name must be finite.", $Name)
    }
    return $Value
}

function Get-WidgetAppearance {
    param(
        [Parameter(Mandatory)]$RemainingPercent,
        [Parameter(Mandatory)]$Theme
    )

    $remaining = ConvertTo-FiniteWidgetNumber $RemainingPercent 'RemainingPercent'
    $themeNumber = ConvertTo-FiniteWidgetNumber $Theme 'Theme'
    if ($remaining -lt 0 -or $remaining -gt 100) {
        throw [ArgumentException]::new('RemainingPercent must be between 0 and 100.', 'RemainingPercent')
    }
    $themes = @(Get-WidgetThemes)
    if ($themeNumber -ne [Math]::Truncate($themeNumber) -or
        $themeNumber -lt 0 -or $themeNumber -ge $themes.Count) {
        throw [ArgumentException]::new('Theme must be an integer in the theme catalog.', 'Theme')
    }
    if ($remaining -le 10) {
        return [pscustomobject]@{ NameKey = 'accessibility.criticalState'; Start = '#FF657D'; End = '#FF657D' }
    }
    if ($remaining -le 20) {
        return [pscustomobject]@{ NameKey = 'accessibility.attentionState'; Start = '#FFD166'; End = '#FFD166' }
    }
    return $themes[[int]$themeNumber]
}

function Format-TokenCount {
    param([Parameter(Mandatory)]$Value)

    $number = ConvertTo-FiniteWidgetNumber $Value 'Value'
    if ($number -lt 0) { throw [ArgumentException]::new('Value must not be negative.', 'Value') }
    $culture = $script:CurrentLanguageCulture
    if ($script:CurrentLanguageCode -cne 'en-US') {
        if ($number -ge 100000000) {
            return Get-WidgetText 'number.hundredMillion' @(($number / 100000000).ToString('0.##', $culture))
        }
        if ($number -ge 10000) {
            $compact = $number / 10000
            return Get-WidgetText 'number.tenThousand' @($compact.ToString($(if ($compact -ge 1000) { '0' } else { '0.#' }), $culture))
        }
    }
    else {
        if ($number -ge 1000000000) {
            return Get-WidgetText 'number.billion' @(($number / 1000000000).ToString('0.##', $culture))
        }
        foreach ($compactNumber in @(
            @(1000000, 'number.million'),
            @(1000, 'number.thousand')
        )) {
            if ($number -ge $compactNumber[0]) {
                $compact = $number / $compactNumber[0]
                return Get-WidgetText $compactNumber[1] @($compact.ToString('0.#', $culture))
            }
        }
    }
    return $number.ToString('N0', $culture)
}

function Get-TokenDetailPresentation {
    param(
        [AllowNull()]$Details,
        [switch]$TaskCache
    )

    $values = @{}
    foreach ($name in 'CumulativeTokens', 'ContextTokens', 'ContextLimit', 'ContextPercent',
        'InputPercent', 'OutputPercent', 'CacheHitTokens', 'CacheMissTokens', 'CacheHitPercent',
        'CacheMissPercent', 'ReasoningOutputPercent') {
        $property = if ($null -ne $Details) { $Details.PSObject.Properties[$name] } else { $null }
        $values[$name] = if ($null -ne $property) { $property.Value } else { $null }
    }
    $cumulativeVisible = $null -ne $values.CumulativeTokens
    $contextVisible = $null -ne $values.ContextTokens -and $null -ne $values.ContextLimit
    $contextPercentVisible = $null -ne $values.ContextPercent
    $compositionVisible = $null -ne $values.InputPercent -and $null -ne $values.OutputPercent
    $cachedVisible = $null -ne $values.CacheHitTokens -and $null -ne $values.CacheMissTokens
    $reasoningVisible = $null -ne $values.ReasoningOutputPercent
    $anyVisible = $cumulativeVisible -or $contextVisible -or $contextPercentVisible -or
        $compositionVisible -or $cachedVisible -or $reasoningVisible
    $culture = $script:CurrentLanguageCulture
    $cacheHitRate = if ($null -ne $values.CacheHitPercent) { ([double]$values.CacheHitPercent).ToString('0.0', $culture) } else { $null }
    $cacheMissRate = if ($null -ne $values.CacheMissPercent) { ([double]$values.CacheMissPercent).ToString('0.0', $culture) } else { $null }
    $cacheHitLabel = Get-WidgetText $(if ($TaskCache) { 'cache.taskHit' } else { 'cache.localHit' })
    $cacheMissLabel = Get-WidgetText $(if ($TaskCache) { 'cache.taskMiss' } else { 'cache.localMiss' })
    $cumulativeValueText = if ($cumulativeVisible) { Format-TokenCount $values.CumulativeTokens } else { $null }
    $contextValueText = if ($contextVisible) {
        (Format-TokenCount $values.ContextTokens) + ' / ' + (Format-TokenCount $values.ContextLimit)
    } else { $null }
    $contextPercentValueText = if ($contextPercentVisible) {
        ([double]$values.ContextPercent).ToString('0.0', $culture) + '%'
    } else { $null }
    $compositionValueText = if ($compositionVisible) {
        Get-WidgetText 'composition.values' @(
            ([double]$values.InputPercent).ToString('0.0', $culture),
            ([double]$values.OutputPercent).ToString('0.0', $culture)
        )
    } else { $null }
    $cacheHitValueText = if ($cachedVisible) {
        $text = Get-WidgetText 'cache.value' @((Format-TokenCount $values.CacheHitTokens), $(if ($null -ne $cacheHitRate) { $cacheHitRate } else { '__WIDGET_RATE__' }))
        if ($null -ne $cacheHitRate) { $text } else { $text.Replace('__WIDGET_RATE__%', '—') }
    } else { $null }
    $cacheMissValueText = if ($cachedVisible) {
        $text = Get-WidgetText 'cache.value' @((Format-TokenCount $values.CacheMissTokens), $(if ($null -ne $cacheMissRate) { $cacheMissRate } else { '__WIDGET_RATE__' }))
        if ($null -ne $cacheMissRate) { $text } else { $text.Replace('__WIDGET_RATE__%', '—') }
    } else { $null }
    $reasoningValueText = if ($reasoningVisible) {
        ([double]$values.ReasoningOutputPercent).ToString('0.0', $culture) + '%'
    } else { $null }
    [pscustomobject]@{
        AnyVisible              = $anyVisible
        CumulativeVisible       = $cumulativeVisible
        CumulativeText          = if ($cumulativeVisible) { (Get-WidgetText 'token.total') + '　' + $cumulativeValueText } else { $null }
        CumulativeValueText     = $cumulativeValueText
        ContextVisible          = $contextVisible
        ContextText             = if ($contextVisible) { (Get-WidgetText 'token.context') + '　' + $contextValueText } else { $null }
        ContextValueText        = $contextValueText
        ContextPercentVisible   = $contextPercentVisible
        ContextPercentText      = if ($contextPercentVisible) { (Get-WidgetText 'token.contextUsage') + '　' + $contextPercentValueText } else { $null }
        ContextPercentValueText = $contextPercentValueText
        ContextBarVisible       = $contextPercentVisible
        ContextPercent          = $values.ContextPercent
        CompositionVisible      = $compositionVisible
        CompositionText         = if ($compositionVisible) { (Get-WidgetText 'token.composition') + '　' + $compositionValueText } else { $null }
        CompositionValueText    = $compositionValueText
        CompositionBarVisible   = $compositionVisible
        InputPercent            = $values.InputPercent
        OutputPercent           = $values.OutputPercent
        CachedVisible           = $cachedVisible
        CacheHitValueText       = $cacheHitValueText
        CacheMissValueText      = $cacheMissValueText
        CachedText              = if ($cachedVisible) {
            $cacheHitLabel + '　' + $cacheHitValueText + "`n" + $cacheMissLabel + '　' + $cacheMissValueText
        } else { $null }
        ReasoningVisible        = $reasoningVisible
        ReasoningText           = if ($reasoningVisible) { (Get-WidgetText 'token.reasoningShare') + '　' + $reasoningValueText } else { $null }
        ReasoningValueText      = $reasoningValueText
    }
}

function Set-DetailVisibility {
    param(
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)][bool]$Visible
    )

    $Element.Visibility = if ($Visible) { 'Visible' } else { 'Collapsed' }
}

function Set-DetailText {
    param(
        [Parameter(Mandatory)]$Element,
        [Parameter(Mandatory)][bool]$Visible,
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$Text
    )

    $Element.Text = if ($Visible -and $null -ne $Text) { $Text } else { '' }
    Set-DetailVisibility $Element $Visible
}

function Format-LimitWindow {
    param([AllowNull()]$Minutes)

    if ($null -eq $Minutes) { return Get-WidgetText 'limit.unknown' }
    $number = ConvertTo-FiniteWidgetNumber $Minutes 'Minutes'
    $typeCode = [Type]::GetTypeCode($Minutes.GetType())
    if ($number -le 0 -or
        ($typeCode -eq [TypeCode]::Decimal -and $number -ne [decimal]::Truncate([decimal]$number)) -or
        ($typeCode -eq [TypeCode]::Single -and
            ($number -ne [Math]::Truncate([double]$number) -or $number -gt 16777215)) -or
        ($typeCode -eq [TypeCode]::Double -and
            ($number -ne [Math]::Truncate([double]$number) -or $number -gt 9007199254740991))) {
        throw [ArgumentException]::new('Minutes must be a positive integer.', 'Minutes')
    }
    $exactMinutes = if ($typeCode -in [TypeCode]::Single, [TypeCode]::Double) {
        [decimal]([long]$number)
    }
    else {
        [decimal]$number
    }
    $culture = $script:CurrentLanguageCulture
    if ($exactMinutes -ge 1440 -and $exactMinutes % 1440 -eq 0) { return Get-WidgetText 'limit.days' @(($exactMinutes / 1440).ToString('0', $culture)) }
    if ($exactMinutes -ge 60 -and $exactMinutes % 60 -eq 0) { return Get-WidgetText 'limit.hours' @(($exactMinutes / 60).ToString('0', $culture)) }
    return Get-WidgetText 'limit.minutes' @($exactMinutes.ToString('0', $culture))
}

function Format-ResetCountdown {
    param(
        [AllowNull()]$State,
        [Parameter(Mandatory)][datetime]$Now
    )

    if ($null -eq $State) { return '—' }
    $current = Get-CurrentLimitState -State $State -Now $Now
    if ($null -eq $current) { return Get-WidgetText 'countdown.waiting' }
    $remaining = ([datetime]$current.ResetAt) - $Now
    if ($remaining.TotalDays -ge 1) {
        return Get-WidgetText 'countdown.daysHours' @([math]::Floor($remaining.TotalDays), $remaining.Hours)
    }
    if ($remaining.TotalHours -ge 1) {
        return Get-WidgetText 'countdown.hoursMinutes' @([math]::Floor($remaining.TotalHours), $remaining.Minutes)
    }
    return Get-WidgetText 'countdown.minutes' @([math]::Max(1, [math]::Ceiling($remaining.TotalMinutes)))
}

function Format-UsageDiagnostic {
    param([AllowNull()][string]$Code)

    switch ($Code) {
        'missing_directory' { return Get-WidgetText 'diagnostic.missingDirectory' }
        'empty_directory'   { return Get-WidgetText 'diagnostic.emptyDirectory' }
        'read_failed'       { return Get-WidgetText 'diagnostic.readFailed' }
        'no_valid_event'    { return Get-WidgetText 'diagnostic.noValidEvent' }
        default             { return Get-WidgetText 'diagnostic.unavailable' }
    }
}

function Get-WidgetVisibleStrings {
    foreach ($key in Get-WidgetRequiredLanguageKeys) { Get-WidgetText $key }
}

function Apply-WidgetLanguage {
    foreach ($binding in @(
        @('DetailTitleText', 'detail.title'), @('RemainingLabelText', 'detail.remaining'),
        @('ObservedLabelText', 'detail.observed'), @('StatusLabelText', 'detail.status'),
        @('ActivityTitleText', 'activity.title'), @('ActivityWindowText', 'activity.window30m'),
        @('TaskNoDataText', 'task.noTokenData'), @('CumulativeLabelText', 'token.total'),
        @('ContextLabelText', 'token.context'), @('ContextPercentLabelText', 'token.contextUsage'),
        @('CompositionLabelText', 'token.composition'), @('TaskCacheHitLabelText', 'cache.hit'),
        @('TaskCacheMissLabelText', 'cache.miss'), @('ReasoningLabelText', 'token.reasoningShare'),
        @('GlobalCacheHitLabelText', 'cache.localHit'), @('GlobalCacheMissLabelText', 'cache.localMiss')
    )) {
        $control = Get-Variable -Name $binding[0] -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $control) { $control.Text = Get-WidgetText $binding[1] }
    }
    if ($null -ne $script:WidgetWindow) {
        $script:WidgetWindow.Title = Get-WidgetText 'app.title'
        [System.Windows.Automation.AutomationProperties]::SetName($script:WidgetWindow, (Get-WidgetText 'app.title'))
    }
    if ($null -ne $script:CircleHost) {
        [System.Windows.Automation.AutomationProperties]::SetName($script:CircleHost, (Get-WidgetText 'accessibility.ringName'))
        [System.Windows.Automation.AutomationProperties]::SetHelpText($script:CircleHost, (Get-WidgetText 'accessibility.ringHelp'))
    }
    if ($null -ne $script:NotifyIcon) { $script:NotifyIcon.Text = Get-WidgetText 'app.title' }
    if ($null -ne $script:TrayShowItem) { $script:TrayShowItem.Text = Get-WidgetText 'menu.showWidget' }
    if ($null -ne $script:TrayExitItem) { $script:TrayExitItem.Text = Get-WidgetText 'menu.exit' }
    if ($null -ne $script:DetailMenuItem) {
        $script:DetailMenuItem.Header = Get-WidgetText $(if ($null -ne $script:DetailPopup -and $script:DetailPopup.IsOpen) { 'menu.hideDetails' } else { 'menu.showDetails' })
    }
    if ($null -ne $script:LanguageMenuItem) { $script:LanguageMenuItem.Header = Get-WidgetText 'menu.language' }
    if ($null -ne $script:ExitMenuItem) { $script:ExitMenuItem.Header = Get-WidgetText 'menu.exit' }
    $themes = @(Get-WidgetThemes)
    foreach ($item in @($script:ThemeMenuItems)) {
        $index = [int]$item.Tag
        if ($index -ge 0 -and $index -lt $themes.Count) { $item.Header = Get-WidgetText $themes[$index].NameKey }
    }
    foreach ($item in @($script:LanguageMenuItems)) { $item.Header = Get-WidgetText ('language.' + [string]$item.Tag) }
}

function Set-WidgetLanguage {
    param(
        [Parameter(Mandatory)][string]$Code,
        [switch]$Persist
    )

    if (@(Get-WidgetLanguageCodes) -cnotcontains $Code -or
        $null -eq $script:WidgetLanguagePacks -or -not $script:WidgetLanguagePacks.ContainsKey($Code)) { return }
    try { $culture = [cultureinfo]::GetCultureInfo($script:WidgetLanguagePacks[$Code].Culture) }
    catch { return }
    $script:CurrentLanguageCode = $Code
    $script:CurrentLanguageCulture = $culture
    if ($null -ne $script:WidgetPreferences) { $script:WidgetPreferences.Language = $Code }
    Apply-WidgetLanguage
    Set-WidgetState -State $script:LastUsageState
    if ($Persist -and $null -ne $script:WidgetPreferences) {
        [void](Save-WidgetPreferences -Left $script:WidgetPreferences.Left -Top $script:WidgetPreferences.Top `
            -Monitor $script:WidgetPreferences.Monitor -Theme $script:WidgetPreferences.Theme `
            -CodexDataDirectory $script:WidgetPreferences.CodexDataDirectory -Language $script:WidgetPreferences.Language)
    }
}

function Update-WidgetCountdown {
    $script:CountdownText.Text = Format-ResetCountdown -State $script:LastUsageState -Now (Get-Date)
}

function Set-WidgetTokenDetails {
    param([AllowNull()]$Details)

    $presentation = Get-TokenDetailPresentation -Details $Details -TaskCache
    foreach ($item in @(
        @($script:CumulativeRow, $script:CumulativeText, $presentation.CumulativeVisible, $presentation.CumulativeValueText),
        @($script:ContextRow, $script:ContextText, $presentation.ContextVisible, $presentation.ContextValueText),
        @($script:ContextPercentRow, $script:ContextPercentText, $presentation.ContextPercentVisible, $presentation.ContextPercentValueText),
        @($script:CompositionRow, $script:CompositionText, $presentation.CompositionVisible, $presentation.CompositionValueText),
        @($script:TaskCacheHitRow, $script:TaskCachedText, $presentation.CachedVisible, $presentation.CacheHitValueText),
        @($script:TaskCacheMissRow, $script:TaskCacheMissText, $presentation.CachedVisible, $presentation.CacheMissValueText),
        @($script:ReasoningRow, $script:ReasoningText, $presentation.ReasoningVisible, $presentation.ReasoningValueText)
    )) {
        Set-DetailVisibility $item[0] ([bool]$item[2])
        Set-DetailText $item[1] ([bool]$item[2]) $item[3]
    }
    Set-DetailVisibility $script:ContextBar $presentation.ContextBarVisible
    Set-DetailVisibility $script:CompositionBar $presentation.CompositionBarVisible
    if ($presentation.ContextBarVisible) {
        $contextPercent = [double]$presentation.ContextPercent
        $script:ContextFillColumn.Width = [System.Windows.GridLength]::new([math]::Max(0.001, $contextPercent), [System.Windows.GridUnitType]::Star)
        $script:ContextRestColumn.Width = [System.Windows.GridLength]::new([math]::Max(0.001, 100 - $contextPercent), [System.Windows.GridUnitType]::Star)
    }
    else {
        $script:ContextFillColumn.Width = [System.Windows.GridLength]::new(0.001, [System.Windows.GridUnitType]::Star)
        $script:ContextRestColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    }
    if ($presentation.CompositionBarVisible) {
        $script:InputColumn.Width = [System.Windows.GridLength]::new([math]::Max(0.001, [double]$presentation.InputPercent), [System.Windows.GridUnitType]::Star)
        $script:OutputColumn.Width = [System.Windows.GridLength]::new([math]::Max(0.001, [double]$presentation.OutputPercent), [System.Windows.GridUnitType]::Star)
    }
    else {
        $script:InputColumn.Width = [System.Windows.GridLength]::new(0.001, [System.Windows.GridUnitType]::Star)
        $script:OutputColumn.Width = [System.Windows.GridLength]::new(1, [System.Windows.GridUnitType]::Star)
    }
}

function Set-WidgetGlobalCacheDetails {
    param([AllowNull()]$Details)

    $presentation = Get-TokenDetailPresentation $Details
    Set-DetailVisibility $script:GlobalCacheDivider $presentation.CachedVisible
    Set-DetailVisibility $script:GlobalCacheHitRow $presentation.CachedVisible
    Set-DetailVisibility $script:GlobalCacheMissRow $presentation.CachedVisible
    Set-DetailText $script:CachedText $presentation.CachedVisible $presentation.CacheHitValueText
    Set-DetailText $script:CachedMissText $presentation.CachedVisible $presentation.CacheMissValueText
    Set-DetailVisibility $script:TokenDetailsPanel $presentation.CachedVisible
}

function Set-ActiveTaskRowAppearance {
    param(
        [AllowNull()]$Row,
        [Parameter(Mandatory)][bool]$Selected,
        [bool]$HighContrast = [System.Windows.SystemParameters]::HighContrast
    )

    if ($null -eq $Row -or $null -eq $Row.Child) { return }
    $label = $Row.Child
    $taskName = if ($null -ne $Row.Tag -and $null -ne $Row.Tag.Name) { [string]$Row.Tag.Name } else { '' }
    $label.Text = if ($Selected) { '•　' + $taskName } else { $taskName }
    if ($HighContrast) {
        $Row.Background = [System.Windows.Media.Brushes]::Transparent
        if ($Selected) {
            $accentBrush = if (
                [object]::ReferenceEquals($script:DetailAccentBrush, [System.Windows.SystemColors]::HighlightBrush) -or
                [object]::ReferenceEquals($script:DetailAccentBrush, [System.Windows.SystemColors]::GrayTextBrush)
            ) {
                $script:DetailAccentBrush
            } else {
                [System.Windows.SystemColors]::HighlightBrush
            }
            $Row.BorderBrush = $accentBrush
            $label.Foreground = $accentBrush
        }
        else {
            $Row.BorderBrush = [System.Windows.SystemColors]::GrayTextBrush
            $label.Foreground = [System.Windows.SystemColors]::WindowTextBrush
        }
        return
    }
    if ($Selected) {
        $Row.Background = if ($null -ne $script:DetailAccentSoftBrush) {
            $script:DetailAccentSoftBrush
        } else {
            [System.Windows.Media.Brushes]::Transparent
        }
        $accentBrush = if ($null -ne $script:DetailAccentBrush) {
            $script:DetailAccentBrush
        } else {
            [System.Windows.SystemColors]::HighlightBrush
        }
        $Row.BorderBrush = $accentBrush
        $label.Foreground = $accentBrush
    }
    else {
        $Row.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#10FFFFFF')
        $Row.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#20FFFFFF')
        $label.Foreground = [System.Windows.Media.BrushConverter]::new().ConvertFromString('#D0BDBBB4')
    }
}

function Set-WidgetAppearance {
    param(
        [AllowNull()]$RemainingPercent,
        [switch]$Unavailable,
        [bool]$HighContrast = [System.Windows.SystemParameters]::HighContrast
    )

    if ($HighContrast) {
        $gradientBrush = if ($Unavailable) {
            [System.Windows.SystemColors]::GrayTextBrush
        } else {
            [System.Windows.SystemColors]::HighlightBrush
        }
        $startBrush = $gradientBrush
        $endBrush = [System.Windows.SystemColors]::GrayTextBrush
        $softBrush = [System.Windows.Media.Brushes]::Transparent
    }
    elseif ($Unavailable) {
        $gradientBrush = [System.Windows.Media.Brushes]::SlateGray
        $startBrush = $gradientBrush
        $endBrush = $gradientBrush
        $softBrush = [System.Windows.Media.Brushes]::Transparent
    }
    else {
        $appearance = Get-WidgetAppearance -RemainingPercent $RemainingPercent -Theme $script:WidgetPreferences.Theme
        $startColor = [System.Windows.Media.ColorConverter]::ConvertFromString($appearance.Start)
        $endColor = [System.Windows.Media.ColorConverter]::ConvertFromString($appearance.End)
        $gradientBrush = [System.Windows.Media.LinearGradientBrush]::new()
        $gradientBrush.StartPoint = [System.Windows.Point]::new(0, 0)
        $gradientBrush.EndPoint = [System.Windows.Point]::new(1, 1)
        $gradientBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new($startColor, 0))
        $gradientBrush.GradientStops.Add([System.Windows.Media.GradientStop]::new($endColor, 1))
        $startBrush = [System.Windows.Media.SolidColorBrush]::new($startColor)
        $endBrush = [System.Windows.Media.SolidColorBrush]::new($endColor)
        $softBrush = [System.Windows.Media.SolidColorBrush]::new(
            [System.Windows.Media.Color]::FromArgb(28, $startColor.R, $startColor.G, $startColor.B))
        foreach ($brush in $gradientBrush, $startBrush, $endBrush, $softBrush) {
            if ($brush.CanFreeze) { $brush.Freeze() }
        }
    }

    $script:DetailAccentBrush = $gradientBrush
    $script:DetailAccentSoftBrush = $softBrush
    $script:RingValue.Stroke = $gradientBrush
    $script:GlowRing.Stroke = $gradientBrush
    $script:RemainingDetailText.Foreground = $gradientBrush
    $script:RemainingDetailUnitText.Foreground = $gradientBrush
    $script:DetailAccentDot.Fill = $gradientBrush
    $script:TaskDetailAccentLine.Background = $gradientBrush
    $script:ContextAccentFill.Background = $gradientBrush
    $script:InputAccentFill.Background = $startBrush
    $script:OutputAccentFill.Background = $endBrush
    $script:DetailAccentGlow.Background = $gradientBrush
    $script:DetailStatusText.Foreground = $gradientBrush
    Set-ActiveTaskRowAppearance -Row $script:ActiveTaskRow -Selected ($null -ne $script:ActiveTaskRow) -HighContrast $HighContrast
}

function Show-ActiveTaskDetails {
    param(
        [Parameter(Mandatory)]$Task,
        [AllowNull()]$Row
    )

    if ($null -ne $script:ActiveTaskRow -and $script:ActiveTaskRow -ne $Row) {
        Set-ActiveTaskRowAppearance -Row $script:ActiveTaskRow -Selected $false
    }
    $script:ActiveTaskRow = $Row
    $script:ActiveTaskId = $Task.Id
    Set-ActiveTaskRowAppearance -Row $Row -Selected $true
    $script:TaskTitleText.Text = $Task.Name
    Set-WidgetTokenDetails $Task.TokenDetails
    Set-DetailVisibility $script:TaskNoDataText ($null -eq $Task.TokenDetails)
    Set-DetailVisibility $script:TaskDetailsPanel $true
    if ($null -ne $script:DetailPopup -and $script:DetailPopup.IsOpen) { Show-DetailPopup }
}

function Hide-ActiveTaskDetails {
    Set-ActiveTaskRowAppearance -Row $script:ActiveTaskRow -Selected $false
    $script:ActiveTaskRow = $null
    $script:ActiveTaskId = $null
    $script:TaskTitleText.Text = ''
    Set-WidgetTokenDetails $null
    Set-DetailVisibility $script:TaskNoDataText $false
    Set-DetailVisibility $script:TaskDetailsPanel $false
    if ($null -ne $script:DetailPopup -and $script:DetailPopup.IsOpen) { Show-DetailPopup }
}

function Set-ActiveTaskList {
    param(
        [object[]]$Tasks,
        [bool]$NamesAvailable
    )

    $selectedId = $script:ActiveTaskId
    $script:ActiveTaskList.Children.Clear()
    $selectedTask = $null
    $selectedRow = $null
    foreach ($task in @($Tasks)) {
        if ($null -eq $task) { continue }
        $row = [System.Windows.Controls.Border]::new()
        $row.Padding = [System.Windows.Thickness]::new(10, 6, 10, 6)
        $row.Margin = [System.Windows.Thickness]::new(0, 3, 0, 3)
        $row.CornerRadius = [System.Windows.CornerRadius]::new(12)
        $row.BorderThickness = [System.Windows.Thickness]::new(1)
        $row.Focusable = $true
        $row.Tag = $task
        $row.ToolTip = $task.Name
        [System.Windows.Automation.AutomationProperties]::SetName($row, (Get-WidgetText 'accessibility.activeTask' @($task.Name)))
        $label = [System.Windows.Controls.TextBlock]::new()
        $label.Text = $task.Name
        $label.TextTrimming = [System.Windows.TextTrimming]::CharacterEllipsis
        $label.FontSize = 12
        $row.Child = $label
        Set-ActiveTaskRowAppearance -Row $row -Selected $false
        $row.Add_MouseEnter({
            param($sender, $eventArgs)
            if ($null -ne $script:TaskDetailHideTimer) { $script:TaskDetailHideTimer.Stop() }
            Show-ActiveTaskDetails -Task $sender.Tag -Row $sender
        })
        $row.Add_MouseLeave({
            if ($null -ne $script:TaskDetailHideTimer) {
                $script:TaskDetailHideTimer.Stop()
                $script:TaskDetailHideTimer.Start()
            }
        })
        $row.Add_GotKeyboardFocus({
            param($sender, $eventArgs)
            if ($null -ne $script:TaskDetailHideTimer) { $script:TaskDetailHideTimer.Stop() }
            Show-ActiveTaskDetails -Task $sender.Tag -Row $sender
        })
        $row.Add_LostKeyboardFocus({
            if ($null -ne $script:TaskDetailHideTimer) {
                $script:TaskDetailHideTimer.Stop()
                $script:TaskDetailHideTimer.Start()
            }
        })
        [void]$script:ActiveTaskList.Children.Add($row)
        if ($task.Id -eq $selectedId) {
            $selectedTask = $task
            $selectedRow = $row
        }
    }

    $script:ActiveTaskEmptyText.Text = if ($NamesAvailable) {
        Get-WidgetText 'activity.empty30m'
    } else {
        Get-WidgetText 'activity.namesUnavailable'
    }
    Set-DetailVisibility $script:ActiveTaskEmptyText ($script:ActiveTaskList.Children.Count -eq 0)
    if ($null -ne $selectedTask) {
        Show-ActiveTaskDetails -Task $selectedTask -Row $selectedRow
    }
    else {
        Hide-ActiveTaskDetails
    }
}

function Set-WidgetState {
    param([Parameter(Mandatory)][AllowNull()]$State)

    $usageState = $State
    $isFresh = $null -ne $State
    if ($null -eq $State) {
        $usageState = $script:LastUsageState
    }
    else {
        $script:LastUsageState = $State
    }
    $currentLimit = if ($null -ne $usageState) {
        Get-CurrentLimitState -State $usageState -Now (Get-Date)
    }
    $tokenDetailsProperty = if ($null -ne $usageState) { $usageState.PSObject.Properties['TokenDetails'] } else { $null }
    Set-WidgetGlobalCacheDetails $(if ($null -ne $tokenDetailsProperty) { $tokenDetailsProperty.Value } else { $null })
    $activeTasksProperty = if ($null -ne $usageState) { $usageState.PSObject.Properties['ActiveTasks'] } else { $null }
    $taskNamesProperty = if ($null -ne $usageState) { $usageState.PSObject.Properties['TaskNamesAvailable'] } else { $null }
    $hasTaskSection = $null -ne $activeTasksProperty -or $null -ne $taskNamesProperty
    Set-ActiveTaskList `
        -Tasks $(if ($null -ne $activeTasksProperty) { @($activeTasksProperty.Value) } else { @() }) `
        -NamesAvailable $(if ($null -ne $taskNamesProperty) { [bool]$taskNamesProperty.Value } else { $false })
    if ($hasTaskSection) {
        Set-DetailVisibility $script:TokenDetailsPanel $true
    }
    else {
        Set-DetailVisibility $script:ActiveTaskEmptyText $false
    }

    $observedProperty = if ($null -ne $usageState) { $usageState.PSObject.Properties['ObservedAt'] } else { $null }
    $observedText = if ($null -ne $observedProperty -and $observedProperty.Value -is [datetime]) {
        ([datetime]$observedProperty.Value).ToString('g', $script:CurrentLanguageCulture)
    } else { $null }
    $diagnosticText = $null
    if ($null -ne $script:LastUsageDiagnostic) {
        $diagnosticText = Format-UsageDiagnostic $script:LastUsageDiagnostic
    }
    elseif ($null -eq $observedText) {
        $diagnosticText = Format-UsageDiagnostic $null
    }
    $script:ObservedText.Text = if ($null -ne $observedText) { $observedText } else { '—' }
    Set-DetailText $script:ObservedDiagnosticText ($null -ne $diagnosticText) $diagnosticText

    if ($null -eq $currentLimit) {
        $script:RemainingText.Text = '—'
        Set-RingPercent 0
        Set-WidgetAppearance -Unavailable
        $script:RemainingDetailText.Text = '—'
        $script:RemainingDetailUnitText.Visibility = 'Collapsed'
        $script:DetailStatusText.Text = Get-WidgetText 'status.waitingObservation'
        if ($null -ne $usageState) {
            $script:LimitWindowText.Text = Get-WidgetText 'status.waiting'
            $script:UsageStatusText.Text = Get-WidgetText 'status.waiting'
            $automationName = Get-WidgetText 'accessibility.waitingState'
        }
        else {
            $script:LimitWindowText.Text = Get-WidgetText 'status.unavailable'
            $script:UsageStatusText.Text = Get-WidgetText 'status.noData'
            $automationName = Get-WidgetText 'accessibility.unavailableState'
        }
    }
    else {
        $remainingPercent = [double]$currentLimit.RemainingPercent
        $script:RemainingText.Text = $remainingPercent.ToString('0', $script:CurrentLanguageCulture) + '%'
        $script:RemainingDetailText.Text = $remainingPercent.ToString('0', $script:CurrentLanguageCulture)
        $script:RemainingDetailUnitText.Visibility = 'Visible'
        $windowMinutes = $currentLimit.PSObject.Properties['WindowMinutes']
        $windowText = Format-LimitWindow $(if ($null -eq $windowMinutes) { $null } else { $windowMinutes.Value })
        $script:LimitWindowText.Text = $windowText
        Set-RingPercent $remainingPercent
        Set-WidgetAppearance $remainingPercent
        if ($remainingPercent -le 10) {
            $script:DetailStatusText.Text = Get-WidgetText 'status.critical'
            $script:UsageStatusText.Text = Get-WidgetText 'status.critical'
            $status = Get-WidgetText 'accessibility.criticalState'
        }
        elseif ($remainingPercent -le 20) {
            $script:DetailStatusText.Text = Get-WidgetText 'status.attention'
            $script:UsageStatusText.Text = Get-WidgetText 'status.attention'
            $status = Get-WidgetText 'accessibility.attentionState'
        }
        else {
            $script:DetailStatusText.Text = Get-WidgetText 'status.observationNormal'
            $script:UsageStatusText.Text = Get-WidgetText 'status.sufficient'
            $status = Get-WidgetText 'accessibility.normalState'
        }
        $automationName = Get-WidgetText 'accessibility.usageSummary' @(
            $status, $remainingPercent, $windowText, ([datetime]$usageState.ObservedAt).ToString('g', $script:CurrentLanguageCulture))
    }
    Update-WidgetCountdown

    if ($null -ne $currentLimit -and $isFresh) {
        $observationKey = '{0}|{1:o}|{2:R}|{3:o}' -f
            $currentLimit.Name, ([datetime]$currentLimit.ResetAt), $remainingPercent, ([datetime]$usageState.ObservedAt)
        if ($observationKey -ne $script:LastShimmerObservationKey) {
            $script:LastShimmerObservationKey = $observationKey
            Start-ShimmerAnimation
        }
        $triggered20 = Register-UsageReminderThreshold -State $currentLimit -Threshold 20
        if ($triggered20) { Show-UsageReminder -State $currentLimit }
        $triggered10 = Register-UsageReminderThreshold -State $currentLimit -Threshold 10
        if ($triggered10) { Show-UsageReminder -State $currentLimit }
    }
    [System.Windows.Automation.AutomationProperties]::SetName(
        $script:CircleHost, $automationName)
    [System.Windows.Automation.AutomationProperties]::SetName(
        $script:WidgetWindow, $automationName)
    [System.Windows.Automation.AutomationProperties]::SetHelpText(
        $script:CircleHost, (Get-WidgetText 'accessibility.ringHelp'))
    Update-WidgetCountdown
}

function Get-WidgetXaml {
    @'
<Window
    xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
    xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
    x:Name="WidgetWindow"
    Title=""
    Width="100"
    Height="100"
    MinWidth="100"
    MaxWidth="100"
    MinHeight="100"
    MaxHeight="100"
    WindowStyle="None"
    ResizeMode="NoResize"
    AllowsTransparency="True"
    Background="Transparent"
    Topmost="True"
    ShowInTaskbar="False"
    FontFamily="Segoe UI, Microsoft YaHei UI, Yu Gothic UI, Malgun Gothic"
    Foreground="#F4F7F6"
    Focusable="True"
    UseLayoutRounding="True"
    SnapsToDevicePixels="True"
    AutomationProperties.Name="">
    <Grid
        x:Name="CircleHost"
        Width="82"
        Height="82"
        HorizontalAlignment="Center"
        VerticalAlignment="Center"
        Background="Transparent"
        Cursor="SizeAll"
        Focusable="True"
        AutomationProperties.Name=""
        AutomationProperties.HelpText="">
        <Ellipse
            x:Name="GlowRing"
            Margin="7"
            Stroke="#667BFFE0"
            StrokeThickness="7"
            IsHitTestVisible="False">
            <Ellipse.Effect>
                <BlurEffect Radius="12"/>
            </Ellipse.Effect>
        </Ellipse>
        <Ellipse
            Margin="5"
            Fill="#F0181D25"
            Stroke="#802C3946"
            StrokeThickness="1"
            IsHitTestVisible="False"/>
        <Ellipse
            x:Name="RingTrack"
            Margin="8"
            Stroke="#35485561"
            StrokeThickness="6"
            IsHitTestVisible="False"/>
        <Ellipse
            x:Name="RingValue"
            Margin="8"
            Stroke="#7BFFE0"
            StrokeThickness="6"
            StrokeStartLineCap="Round"
            StrokeEndLineCap="Round"
            StrokeDashArray="34.6,0.01"
            RenderTransformOrigin="0.5,0.5"
            IsHitTestVisible="False">
            <Ellipse.RenderTransform>
                <RotateTransform Angle="-90"/>
            </Ellipse.RenderTransform>
        </Ellipse>
        <Ellipse
            x:Name="ShimmerRing"
            Margin="8"
            StrokeThickness="6"
            StrokeDashArray="3,31.6"
            StrokeStartLineCap="Round"
            Opacity="0.72"
            RenderTransformOrigin="0.5,0.5"
            IsHitTestVisible="False">
            <Ellipse.Stroke>
                <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                    <GradientStop Color="#00FFFFFF" Offset="0"/>
                    <GradientStop Color="#CCFFFFFF" Offset="0.5"/>
                    <GradientStop Color="#00FFFFFF" Offset="1"/>
                </LinearGradientBrush>
            </Ellipse.Stroke>
            <Ellipse.RenderTransform>
                <RotateTransform x:Name="ShimmerRotation" Angle="-90"/>
            </Ellipse.RenderTransform>
        </Ellipse>
        <Ellipse
            x:Name="FocusRing"
            Margin="13"
            Stroke="{DynamicResource {x:Static SystemColors.HighlightBrushKey}}"
            StrokeThickness="2"
            StrokeDashArray="2,2"
            Opacity="0"
            IsHitTestVisible="False"/>
        <Ellipse Margin="17" IsHitTestVisible="False">
            <Ellipse.Fill>
                <RadialGradientBrush Center="0.38,0.30" GradientOrigin="0.32,0.24" RadiusX="0.78" RadiusY="0.78">
                    <GradientStop Color="#483C6970" Offset="0"/>
                    <GradientStop Color="#1A26333B" Offset="0.55"/>
                    <GradientStop Color="#00182027" Offset="1"/>
                </RadialGradientBrush>
            </Ellipse.Fill>
        </Ellipse>
        <TextBlock
            x:Name="RemainingText"
            Text="—"
            FontSize="22"
            FontWeight="SemiBold"
            Foreground="#F4F7F6"
            HorizontalAlignment="Center"
            VerticalAlignment="Center"
            IsHitTestVisible="False"/>

        <Popup
            x:Name="DetailPopup"
            AllowsTransparency="True"
            StaysOpen="True"
            Placement="AbsolutePoint">
            <Border
                x:Name="DetailCard"
                Width="310"
                MaxHeight="640"
                Padding="20"
                CornerRadius="19"
                BorderBrush="#2AFFF4D9"
                BorderThickness="1"
                UseLayoutRounding="True"
                Opacity="0">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
                        <GradientStop Color="#FF242421" Offset="0"/>
                        <GradientStop Color="#FF141513" Offset="0.68"/>
                    </LinearGradientBrush>
                </Border.Background>
                <Border.Effect>
                    <DropShadowEffect
                        Color="#CC000000"
                        BlurRadius="24"
                        ShadowDepth="8"
                        Opacity="0.75"/>
                </Border.Effect>
                <Border.RenderTransform>
                    <TranslateTransform x:Name="DetailCardTranslate" X="0" Y="8"/>
                </Border.RenderTransform>
                <Grid>
                    <Border
                        x:Name="DetailAccentGlow"
                        Width="36"
                        Height="36"
                        Margin="0,-10,-8,0"
                        HorizontalAlignment="Right"
                        VerticalAlignment="Top"
                        CornerRadius="18"
                        Opacity="0.08"
                        IsHitTestVisible="False"/>
                    <ScrollViewer
                        VerticalScrollBarVisibility="Hidden"
                        HorizontalScrollBarVisibility="Disabled">
                        <StackPanel>
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock
                                    x:Name="DetailTitleText"
                                    Text=""
                                    FontSize="18"
                                    FontWeight="Bold"
                                    Foreground="#FFF6F3EE"/>
                                <StackPanel
                                    Grid.Column="1"
                                    Margin="14,0,0,0"
                                    Orientation="Horizontal"
                                    VerticalAlignment="Center">
                                    <Ellipse
                                        x:Name="DetailAccentDot"
                                        Width="6"
                                        Height="6"
                                        Margin="0,0,7,0"
                                        Fill="#FF7BFFE0"/>
                                    <TextBlock
                                        x:Name="DetailStatusText"
                                        Text=""
                                        FontSize="11"
                                        Foreground="#FF7BFFE0"/>
                                </StackPanel>
                            </Grid>
                            <Grid Margin="0,17,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel>
                                    <TextBlock
                                        x:Name="RemainingLabelText"
                                        Text=""
                                        FontSize="12"
                                        Foreground="#999C9990"/>
                                    <StackPanel Margin="0,3,0,0" Orientation="Horizontal">
                                        <TextBlock
                                            x:Name="RemainingDetailText"
                                            Text="—"
                                            FontSize="42"
                                            FontWeight="Bold"
                                            Foreground="#FF7BFFE0"/>
                                        <TextBlock
                                            x:Name="RemainingDetailUnitText"
                                            Margin="2,0,0,5"
                                            Text="%"
                                            FontSize="20"
                                            FontWeight="SemiBold"
                                            VerticalAlignment="Bottom"
                                            Foreground="#FF7BFFE0"
                                            Visibility="Collapsed"/>
                                    </StackPanel>
                                </StackPanel>
                                <StackPanel Grid.Column="1" Margin="16,10,0,0" HorizontalAlignment="Right">
                                    <TextBlock
                                        x:Name="LimitWindowText"
                                        Text="—"
                                        FontSize="15"
                                        FontWeight="Bold"
                                        TextAlignment="Right"
                                        Foreground="#FFF6F3EE"/>
                                    <TextBlock
                                        x:Name="CountdownText"
                                        Margin="0,6,0,0"
                                        Text="—"
                                        FontSize="12"
                                        TextAlignment="Right"
                                        Foreground="#999C9990"/>
                                </StackPanel>
                            </Grid>
                            <Grid Margin="0,15,0,0">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="1"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <StackPanel Margin="0,0,12,0">
                                    <TextBlock
                                        x:Name="ObservedLabelText"
                                        Text=""
                                        FontSize="11"
                                        Foreground="#849C9990"/>
                                    <TextBlock
                                        x:Name="ObservedText"
                                        Margin="0,4,0,0"
                                        Text="—"
                                        FontSize="12"
                                        FontWeight="SemiBold"
                                        Foreground="#FFF6F3EE"/>
                                </StackPanel>
                                <Border Grid.Column="1" Background="#24FFFFFF"/>
                                <StackPanel Grid.Column="2" Margin="14,0,0,0">
                                    <TextBlock
                                        x:Name="StatusLabelText"
                                        Text=""
                                        FontSize="11"
                                        Foreground="#849C9990"/>
                                    <TextBlock
                                        x:Name="UsageStatusText"
                                        Margin="0,4,0,0"
                                        Text=""
                                        FontSize="12"
                                        FontWeight="SemiBold"
                                        Foreground="#FFF6F3EE"/>
                                </StackPanel>
                            </Grid>
                            <TextBlock
                                x:Name="ObservedDiagnosticText"
                                Margin="0,9,0,0"
                                TextWrapping="Wrap"
                                FontSize="11"
                                LineHeight="17"
                                Foreground="#A99C9990"
                                Visibility="Collapsed"/>
                            <StackPanel x:Name="TokenDetailsPanel">
                                <Border Height="1" Margin="0,15,0,14" Background="#25FFF4D9"/>
                                <Grid>
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock
                                        x:Name="ActivityTitleText"
                                        Text=""
                                        FontSize="15"
                                        FontWeight="SemiBold"
                                        Foreground="#FFF6F3EE"/>
                                    <TextBlock
                                        x:Name="ActivityWindowText"
                                        Grid.Column="1"
                                        Text=""
                                        FontSize="11"
                                        HorizontalAlignment="Right"
                                        VerticalAlignment="Center"
                                        Foreground="#729C9990"/>
                                </Grid>
                                <TextBlock
                                    x:Name="ActiveTaskEmptyText"
                                    Margin="0,9,0,0"
                                    Text=""
                                    FontSize="12"
                                    Foreground="#999C9990"/>
                                <StackPanel x:Name="ActiveTaskList" Margin="0,5,0,0"/>
                                <Border
                                    x:Name="TaskDetailsPanel"
                                    Margin="0,10,0,0"
                                    Padding="0,12,0,12"
                                    BorderBrush="#25FFFFFF"
                                    BorderThickness="0,1,0,1"
                                    Background="Transparent"
                                    Visibility="Collapsed">
                                    <StackPanel>
                                        <Border
                                            x:Name="TaskDetailAccentLine"
                                            Width="22"
                                            Height="1"
                                            Margin="0,0,0,10"
                                            HorizontalAlignment="Left"
                                            Background="#FF7BFFE0"/>
                                        <TextBlock
                                            x:Name="TaskTitleText"
                                            FontSize="13"
                                            FontWeight="Bold"
                                            Foreground="#FFF6F3EE"
                                            TextWrapping="Wrap"/>
                                        <TextBlock
                                            x:Name="TaskNoDataText"
                                            Margin="0,8,0,0"
                                            Text=""
                                            FontSize="12"
                                            Foreground="#999C9990"
                                            Visibility="Collapsed"/>
                                        <Grid x:Name="CumulativeRow" Margin="0,11,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="CumulativeLabelText" Text="" FontSize="12" Foreground="#C0BDBBB4"/>
                                            <TextBlock x:Name="CumulativeText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="12" FontWeight="SemiBold" Foreground="#FFF6F3EE"/>
                                        </Grid>
                                        <Grid x:Name="ContextRow" Margin="0,8,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="ContextLabelText" Text="" FontSize="12" Foreground="#C0BDBBB4"/>
                                            <TextBlock x:Name="ContextText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="12" FontWeight="SemiBold" Foreground="#FFF6F3EE"/>
                                        </Grid>
                                        <Grid x:Name="ContextPercentRow" Margin="0,6,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="ContextPercentLabelText" Text="" FontSize="11" Foreground="#999C9990"/>
                                            <TextBlock x:Name="ContextPercentText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="11" Foreground="#BDBDBBB4"/>
                                        </Grid>
                                        <Border
                                            x:Name="ContextBar"
                                            Height="5"
                                            Margin="0,6,0,0"
                                            CornerRadius="3"
                                            ClipToBounds="True"
                                            Background="#5033332F"
                                            Visibility="Collapsed">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition x:Name="ContextFillColumn" Width="0*"/>
                                                    <ColumnDefinition x:Name="ContextRestColumn" Width="1*"/>
                                                </Grid.ColumnDefinitions>
                                                <Border x:Name="ContextAccentFill" Grid.Column="0" Background="#FF62DDC5"/>
                                            </Grid>
                                        </Border>
                                        <Grid x:Name="CompositionRow" Margin="0,11,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="CompositionLabelText" Text="" FontSize="11" Foreground="#999C9990"/>
                                            <TextBlock x:Name="CompositionText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="11" Foreground="#BDBDBBB4"/>
                                        </Grid>
                                        <Border
                                            x:Name="CompositionBar"
                                            Height="5"
                                            Margin="0,6,0,0"
                                            CornerRadius="3"
                                            ClipToBounds="True"
                                            Background="#5033332F"
                                            Visibility="Collapsed">
                                            <Grid>
                                                <Grid.ColumnDefinitions>
                                                    <ColumnDefinition x:Name="InputColumn" Width="0*"/>
                                                    <ColumnDefinition x:Name="OutputColumn" Width="1*"/>
                                                </Grid.ColumnDefinitions>
                                                <Border x:Name="InputAccentFill" Grid.Column="0" Background="#FF62DDC5"/>
                                                <Border x:Name="OutputAccentFill" Grid.Column="1" Background="#FF758BFF"/>
                                            </Grid>
                                        </Border>
                                        <Grid x:Name="TaskCacheHitRow" Margin="0,10,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="TaskCacheHitLabelText" Text="" FontSize="11" Foreground="#999C9990"/>
                                            <TextBlock x:Name="TaskCachedText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="11" Foreground="#BDBDBBB4"/>
                                        </Grid>
                                        <Grid x:Name="TaskCacheMissRow" Margin="0,6,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="TaskCacheMissLabelText" Text="" FontSize="11" Foreground="#999C9990"/>
                                            <TextBlock x:Name="TaskCacheMissText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="11" Foreground="#BDBDBBB4"/>
                                        </Grid>
                                        <Grid x:Name="ReasoningRow" Margin="0,6,0,0" Visibility="Collapsed">
                                            <Grid.ColumnDefinitions>
                                                <ColumnDefinition Width="*"/>
                                                <ColumnDefinition Width="Auto"/>
                                            </Grid.ColumnDefinitions>
                                            <TextBlock x:Name="ReasoningLabelText" Text="" FontSize="11" Foreground="#999C9990"/>
                                            <TextBlock x:Name="ReasoningText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="11" Foreground="#BDBDBBB4"/>
                                        </Grid>
                                    </StackPanel>
                                </Border>
                                <Border x:Name="GlobalCacheDivider" Height="1" Margin="0,14,0,10" Background="#25FFFFFF" Visibility="Collapsed"/>
                                <Grid x:Name="GlobalCacheHitRow" Visibility="Collapsed">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="GlobalCacheHitLabelText" Text="" FontSize="12" Foreground="#999C9990"/>
                                    <TextBlock x:Name="CachedText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="12" Foreground="#BDBDBBB4"/>
                                </Grid>
                                <Grid x:Name="GlobalCacheMissRow" Margin="0,6,0,0" Visibility="Collapsed">
                                    <Grid.ColumnDefinitions>
                                        <ColumnDefinition Width="*"/>
                                        <ColumnDefinition Width="Auto"/>
                                    </Grid.ColumnDefinitions>
                                    <TextBlock x:Name="GlobalCacheMissLabelText" Text="" FontSize="12" Foreground="#999C9990"/>
                                    <TextBlock x:Name="CachedMissText" Grid.Column="1" Text="—" TextAlignment="Right" FontSize="12" Foreground="#BDBDBBB4"/>
                                </Grid>
                            </StackPanel>
                        </StackPanel>
                    </ScrollViewer>
                </Grid>
            </Border>
        </Popup>
    </Grid>
</Window>
'@
}

if ($SelfTest) {
    $ErrorActionPreference = 'Stop'
    Initialize-WidgetLocalization -Root $PSScriptRoot -SavedLanguage 'zh-CN' -UiCulture ([cultureinfo]'zh-CN')
    $languageCodes = @(Get-WidgetLanguageCodes)
    Assert-Widget (($languageCodes -join ',') -ceq 'zh-CN,zh-TW,en-US,ja-JP,ko-KR') 'the language catalog should expose the approved five codes.'
    Assert-Widget ((Resolve-WidgetLanguageCode $null ([cultureinfo]'zh-Hans-CN')) -ceq 'zh-CN') 'Simplified Chinese UI culture should map to zh-CN.'
    Assert-Widget ((Resolve-WidgetLanguageCode $null ([cultureinfo]'zh-Hant-TW')) -ceq 'zh-TW') 'Traditional Chinese UI culture should map to zh-TW.'
    Assert-Widget ((Resolve-WidgetLanguageCode $null ([cultureinfo]'ja-JP')) -ceq 'ja-JP') 'Japanese UI culture should map to ja-JP.'
    Assert-Widget ((Resolve-WidgetLanguageCode $null ([cultureinfo]'ko-KR')) -ceq 'ko-KR') 'Korean UI culture should map to ko-KR.'
    Assert-Widget ((Resolve-WidgetLanguageCode $null ([cultureinfo]'fr-FR')) -ceq 'en-US') 'unsupported UI cultures should fall back to English.'
    Assert-Widget ((Resolve-WidgetLanguageCode 'ja-JP' ([cultureinfo]'en-US')) -ceq 'ja-JP') 'a saved valid language should win.'
    Assert-Widget ((Resolve-WidgetLanguageCode 'bad-code' ([cultureinfo]'en-US')) -ceq 'en-US') 'an invalid saved language should be ignored.'
    Assert-Widget ((Resolve-WidgetLanguageCode 'JA-jp' ([cultureinfo]'en-US')) -ceq 'en-US') 'saved language codes should be case-sensitive.'

    $requiredLanguageKeys = @(Get-WidgetRequiredLanguageKeys)
    Assert-Widget ($requiredLanguageKeys.Count -eq 100 -and ($requiredLanguageKeys | Select-Object -Unique).Count -eq 100) 'the required language-key catalog should contain exactly 100 unique keys.'
    $temporaryParent = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath()).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
    $temporaryLocaleRoot = Join-Path $temporaryParent ('CodexUsageWidget-Locale-' + [guid]::NewGuid().ToString('N'))
    $temporaryLocales = Join-Path $temporaryLocaleRoot 'locales'
    try {
        [void][System.IO.Directory]::CreateDirectory($temporaryLocales)
        $temporaryPackPath = Join-Path $temporaryLocales 'en-US.json'
        [System.IO.File]::WriteAllText($temporaryPackPath, ('x' * 262145), [System.Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { [void](Read-WidgetLanguagePack 'en-US' $temporaryLocaleRoot) } catch { $rejected = $true }
        Assert-Widget $rejected 'language packs larger than 256 KiB should be rejected.'

        [System.IO.File]::WriteAllText($temporaryPackPath,
            ('{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":"' + ('x' * 63) + '"}}'),
            [System.Text.UTF8Encoding]::new($false))
        Assert-Widget ((Read-WidgetLanguagePack 'en-US' $temporaryLocaleRoot).Strings['app.title'].Length -eq 63) 'app.title should allow the NotifyIcon maximum of 63 characters.'

        [System.IO.File]::WriteAllText($temporaryPackPath,
            ('{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":"' + ('x' * 64) + '"}}'),
            [System.Text.UTF8Encoding]::new($false))
        $rejected = $false
        try { [void](Read-WidgetLanguagePack 'en-US' $temporaryLocaleRoot) } catch { $rejected = $true }
        Assert-Widget $rejected 'app.title must fit the NotifyIcon 63-character limit.'

        [System.IO.File]::WriteAllText($temporaryPackPath,
            '{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":"Usage widget","extension":{"value":"ignored"}}}',
            [System.Text.UTF8Encoding]::new($false))
        $packWithUnknownExtension = $null
        try { $packWithUnknownExtension = Read-WidgetLanguagePack 'en-US' $temporaryLocaleRoot } catch { }
        Assert-Widget ($null -ne $packWithUnknownExtension -and
            -not $packWithUnknownExtension.Strings.ContainsKey('extension')) 'unknown language-pack object keys should be ignored before value validation.'

        $invalidPacks = @(
            '{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":{"value":"bad"}}}',
            '{"code":"EN-us","nativeName":"English","culture":"en-US","strings":{"app.title":"Usage widget"}}',
            '{"code":"en-US","nativeName":"English","culture":"EN-us","strings":{"app.title":"Usage widget"}}',
            '{"code":"en-US","nativeName":"","culture":"en-US","strings":{"app.title":"Usage widget"}}',
            ('{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":"' + ('x' * 1001) + '"}}')
        )
        foreach ($invalidPack in $invalidPacks) {
            [System.IO.File]::WriteAllText($temporaryPackPath, $invalidPack, [System.Text.UTF8Encoding]::new($false))
            $rejected = $false
            try { [void](Read-WidgetLanguagePack 'en-US' $temporaryLocaleRoot) } catch { $rejected = $true }
            Assert-Widget $rejected 'invalid language-pack metadata or string values should be rejected.'
        }

        $temporaryJapanesePackPath = Join-Path $temporaryLocales 'ja-JP.json'
        [System.IO.File]::WriteAllText($temporaryPackPath,
            [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'locales\en-US.json')),
            [System.Text.UTF8Encoding]::new($false))
        $temporaryJapanesePack = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'locales\ja-JP.json')) | ConvertFrom-Json -ErrorAction Stop
        $temporaryJapanesePack.strings.'detail.title' = '   '
        [System.IO.File]::WriteAllText($temporaryJapanesePackPath,
            ($temporaryJapanesePack | ConvertTo-Json -Depth 5),
            [System.Text.UTF8Encoding]::new($false))
        $blankJapanesePack = Read-WidgetLanguagePack 'ja-JP' $temporaryLocaleRoot
        Assert-Widget (-not $blankJapanesePack.Strings.ContainsKey('detail.title')) 'blank optional translations should be treated as missing.'
        Initialize-WidgetLocalization $temporaryLocaleRoot 'ja-JP' ([cultureinfo]'en-US')
        Assert-Widget ($script:CurrentLanguageCode -ceq 'ja-JP' -and
            (Get-WidgetText 'detail.title') -ceq 'Usage details') 'blank optional translations should fall back to English.'

        $temporaryEnglishPack = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'locales\en-US.json')) | ConvertFrom-Json -ErrorAction Stop
        $temporaryEnglishPack.strings.'detail.title' = '   '
        [System.IO.File]::WriteAllText($temporaryPackPath,
            ($temporaryEnglishPack | ConvertTo-Json -Depth 5),
            [System.Text.UTF8Encoding]::new($false))
        $blankEnglishRejected = $false
        try { Initialize-WidgetLocalization $temporaryLocaleRoot $null ([cultureinfo]'en-US') } catch { $blankEnglishRejected = $true }
        Assert-Widget $blankEnglishRejected 'blank required English translations should reject localization initialization.'

        [System.IO.File]::WriteAllText($temporaryPackPath, '{"code":"en-US","nativeName":"English","culture":"en-US","strings":{"app.title":"Usage widget"}}', [System.Text.UTF8Encoding]::new($false))
        $safeEnglishFailure = $null
        try { Initialize-WidgetLocalization $temporaryLocaleRoot $null ([cultureinfo]'en-US') } catch { $safeEnglishFailure = $_.Exception.Message }
        Assert-Widget ($safeEnglishFailure -match 'English language pack' -and $safeEnglishFailure -match '英语语言包') 'invalid English packs should use the built-in bilingual exception contract.'
    }
    finally {
        $fullTemporaryLocaleRoot = [System.IO.Path]::GetFullPath($temporaryLocaleRoot).TrimEnd([System.IO.Path]::DirectorySeparatorChar)
        Assert-Widget ([System.IO.Path]::GetDirectoryName($fullTemporaryLocaleRoot) -ceq $temporaryParent -and
            [System.IO.Path]::GetFileName($fullTemporaryLocaleRoot).StartsWith('CodexUsageWidget-Locale-', [StringComparison]::Ordinal)) 'locale-test cleanup should remain inside the unique temporary root.'
        if ([System.IO.Directory]::Exists($fullTemporaryLocaleRoot)) { [System.IO.Directory]::Delete($fullTemporaryLocaleRoot, $true) }
    }

    Initialize-WidgetLocalization $PSScriptRoot 'zh-CN' ([cultureinfo]'en-US')
    Assert-Widget ($script:CurrentLanguageCode -ceq 'zh-CN' -and $script:CurrentLanguageCulture.Name -ceq 'zh-CN') 'localization should use the selected pack and culture.'
    Assert-Widget ((Get-WidgetText 'app.title') -ceq '用量小组件') 'the Simplified Chinese pack should expose approved UI text.'
    Assert-Widget ((Get-WidgetText 'countdown.daysHours' @(2, 3)) -ceq '2 天 3 小时后重置') 'localized placeholders should format with the active culture.'
    $englishStrings = ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'locales\en-US.json')) | ConvertFrom-Json -ErrorAction Stop).strings
    $englishKeys = @($englishStrings.PSObject.Properties.Name | Sort-Object)
    Assert-Widget ($englishKeys.Count -eq 100 -and ($englishKeys -join ',') -ceq (@($requiredLanguageKeys | Sort-Object) -join ',')) 'the raw English pack should contain exactly the canonical 100 keys.'
    foreach ($code in $languageCodes) {
        $strings = ([System.IO.File]::ReadAllText((Join-Path $PSScriptRoot ('locales\' + $code + '.json'))) | ConvertFrom-Json -ErrorAction Stop).strings
        $keys = @($strings.PSObject.Properties.Name | Sort-Object)
        Assert-Widget ($keys.Count -eq 100 -and ($keys -join ',') -ceq ($englishKeys -join ',')) ($code + ' raw JSON should contain exactly the same 100 keys as English.')
        foreach ($key in $requiredLanguageKeys) {
            Assert-Widget (-not [string]::IsNullOrWhiteSpace([string]$strings.$key)) ($code + ' raw JSON should contain nonblank text for ' + $key + '.')
            $englishPlaceholders = @([regex]::Matches($englishStrings.$key, '(?<!\{)\{[^{}]+\}(?!\})') | ForEach-Object Value | Sort-Object)
            $packPlaceholders = @([regex]::Matches($strings.$key, '(?<!\{)\{[^{}]+\}(?!\})') | ForEach-Object Value | Sort-Object)
            Assert-Widget (($englishPlaceholders -join "`n") -ceq ($packPlaceholders -join "`n")) ($code + ' should preserve the placeholder contract for ' + $key + '.')
        }
    }

    $widgetXaml = Get-WidgetXaml
    Assert-Widget ($widgetXaml -match '(?s)<Window\b[^>]*\bWidth="100"[^>]*\bHeight="100"') 'the widget window should be 100 by 100.'
    Assert-Widget ($widgetXaml -match 'FontFamily="Segoe UI, Microsoft YaHei UI, Yu Gothic UI, Malgun Gothic"' -and
        $widgetXaml -match 'Title=""' -and $widgetXaml -match 'AutomationProperties.Name=""' -and
        $widgetXaml -match 'AutomationProperties.HelpText=""' -and $widgetXaml -notmatch '[\p{IsCJKUnifiedIdeographs}]') 'XAML should keep the exact multilingual font fallback and contain no localized text.'
    Assert-Widget ($widgetXaml -match 'x:Name="CircleHost"\s+Width="82"\s+Height="82"') 'the circle host should be 82 by 82.'
    Assert-Widget ($widgetXaml -match 'x:Name="DetailPopup"') 'the detail popup should exist.'
    Assert-Widget ($widgetXaml -match 'x:Name="TokenDetailsPanel"') 'the token section should have one collapsible container.'
    Assert-Widget ($widgetXaml -match 'x:Name="ActiveTaskList"' -and
        $widgetXaml -match 'x:Name="TaskDetailsPanel"' -and
        $widgetXaml -match 'x:Name="TaskCachedText"' -and
        $widgetXaml -match 'x:Name="TaskCacheMissText"') 'the task list and aligned task cache rows should exist.'
    Assert-Widget ($widgetXaml -match 'x:Name="CachedText"' -and
        $widgetXaml -match 'x:Name="CachedMissText"' -and
        $widgetXaml -match 'x:Name="GlobalCacheHitLabelText"' -and
        $widgetXaml -match 'x:Name="GlobalCacheMissLabelText"') 'the two aligned global cache rows should remain.'
    Assert-Widget ($widgetXaml -notmatch ('x:Name="Close' + 'Button"')) 'the old close button should be absent.'
    Assert-Widget ($widgetXaml -match 'x:Name="FocusRing"') 'the circle should expose a keyboard focus ring.'
    foreach ($forbiddenText in ('Reading' + ' data'), ('NO' + ' DATA'), ('Reset' + ' '), ('Used' + ':'),
        ('Plan' + ':'), ('Credits' + ':'), ('Updated' + ':'), ('Reminder' + ':'), ('Codex Usage' + ' Widget')) {
        Assert-Widget ($widgetXaml -notmatch [regex]::Escape($forbiddenText)) ('the XAML should not contain old text: ' + $forbiddenText)
    }
    Assert-Widget ($widgetXaml -match 'x:Name="ObservedLabelText"' -and $widgetXaml -match 'x:Name="ActivityTitleText"' -and
        $widgetXaml -match 'x:Name="DetailStatusText"' -and
        $widgetXaml -match 'x:Name="UsageStatusText"') 'the selected quiet-editorial header and metadata should exist.'
    Assert-Widget ($widgetXaml -match 'x:Name="ObservedDiagnosticText"(?s:.*?)TextWrapping="Wrap"') 'diagnostics should wrap below the quiet metadata row.'
    foreach ($controlName in 'DetailAccentGlow', 'DetailAccentDot', 'TaskDetailAccentLine',
        'ContextAccentFill', 'InputAccentFill', 'OutputAccentFill') {
        Assert-Widget ($widgetXaml -match ('x:Name="' + $controlName + '"')) ('the quiet detail layout should expose: ' + $controlName)
    }
    Assert-Widget ($widgetXaml -match '(?s)<TextBlock\b(?=[^>]*\bx:Name="RemainingDetailText")(?=[^>]*\bFontSize="42")[^>]*>') 'remaining digits should stay at 42 pixels.'
    Assert-Widget ($widgetXaml -match '(?s)<TextBlock\b(?=[^>]*\bx:Name="RemainingDetailUnitText")(?=[^>]*\bText="%")(?=[^>]*\bFontSize="20")[^>]*>') 'the percent sign should be an independent 20-pixel control.'
    Assert-Widget ($widgetXaml -notmatch 'x:Name="ActivityHeaderCapsule"') 'the activity heading should not use a capsule.'
    $activityHeadingMatch = [regex]::Match($widgetXaml, '(?s)<StackPanel x:Name="TokenDetailsPanel">\s*<Border Height="1"[^>]*/>\s*(?<HeadingGrid><Grid\b[^>]*>.*?</Grid>)')
    Assert-Widget $activityHeadingMatch.Success 'the activity heading should be an ordinary title line immediately after the divider.'
    $activityHeadingGrid = if ($activityHeadingMatch.Success) { $activityHeadingMatch.Groups['HeadingGrid'].Value } else { '' }
    Assert-Widget ($activityHeadingGrid -match '(?s)<TextBlock\b(?=[^>]*\bx:Name="ActivityTitleText")(?=[^>]*\bFontSize="15")[^>]*>' -and
        $activityHeadingGrid -match '(?s)<TextBlock\b(?=[^>]*\bx:Name="ActivityWindowText")(?=[^>]*\bGrid.Column="1")(?=[^>]*\bFontSize="11")(?=[^>]*\bHorizontalAlignment="Right")[^>]*>') 'the ordinary activity title line should retain its right-aligned 11-pixel time range.'
    $staticFontContracts = @(
        @('ActivityTitleText', 15), @('ActivityWindowText', 11), @('RemainingLabelText', 12),
        @('ObservedLabelText', 11), @('StatusLabelText', 11), @('CumulativeLabelText', 12), @('ContextLabelText', 12),
        @('ContextPercentLabelText', 11), @('CompositionLabelText', 11), @('TaskCacheHitLabelText', 11),
        @('TaskCacheMissLabelText', 11), @('ReasoningLabelText', 11),
        @('GlobalCacheHitLabelText', 12), @('GlobalCacheMissLabelText', 12)
    )
    foreach ($fontContract in $staticFontContracts) {
        $controlName = [regex]::Escape($fontContract[0])
        $fontSize = $fontContract[1]
        $openingTagPattern = '(?s)<TextBlock\b(?=[^>]*\bx:Name="' + $controlName + '")(?=[^>]*\bFontSize="' + $fontSize + '")[^>]*>'
        Assert-Widget ($widgetXaml -match $openingTagPattern) ($fontContract[0] + ' should use ' + $fontSize + '-pixel text in one opening tag.')
    }
    Assert-Widget ($widgetXaml -match 'x:Name="DetailAccentGlow"(?s:.*?)Width="36"(?s:.*?)Height="36"(?s:.*?)CornerRadius="18"') 'the accent glow should be compact instead of a full-width color block.'
    Assert-Widget ($widgetXaml -notmatch 'x:Name="DetailAccentGlow"(?s:.*?)Height="120"') 'the rejected rectangular header tint must not return.'
    Assert-Widget ($widgetXaml -match '<ScrollViewer\s+VerticalScrollBarVisibility="Hidden"') 'overflow should remain scrollable without the bright system scrollbar.'
    Assert-Widget ($widgetXaml -match 'x:Name="TaskDetailsPanel"(?s:.*?)BorderThickness="0,1,0,1"(?s:.*?)Background="Transparent"') 'task details should use the selected quiet bordered layout.'
    foreach ($valueControl in 'CumulativeText', 'ContextText', 'ContextPercentText', 'CompositionText',
        'TaskCachedText', 'TaskCacheMissText', 'ReasoningText', 'CachedText', 'CachedMissText') {
        Assert-Widget ($widgetXaml -match ('x:Name="' + $valueControl + '"(?s:.*?)Grid.Column="1"(?s:.*?)TextAlignment="Right"')) ('quiet detail values should align right: ' + $valueControl)
    }

    $fatalText = Format-WidgetFatalError '无法启动用量小组件。' '当前启动环境不受支持。' '请双击启动文件运行。'
    Assert-Widget ($fatalText -ceq "无法启动用量小组件。`r`n`r`n原因：当前启动环境不受支持。`r`n处理：请双击启动文件运行。") 'fatal errors should use the exact safe Chinese template.'
    $initializedLanguagePacks = $script:WidgetLanguagePacks
    $script:WidgetLanguagePacks = $null
    $fallbackFatalText = Format-WidgetFatalError 'Language pack missing or damaged. / 语言包缺失或损坏。' `
        'The required English language pack could not be validated. / 必需的英语语言包未通过验证。' `
        'Restore the complete locales folder and restart. / 请恢复完整的 locales 文件夹后重启。'
    $script:WidgetLanguagePacks = $initializedLanguagePacks
    Assert-Widget ($fallbackFatalText -ceq
        "Problem / 问题：Language pack missing or damaged. / 语言包缺失或损坏。`r`n`r`nCause / 原因：The required English language pack could not be validated. / 必需的英语语言包未通过验证。`r`nFix / 解决办法：Restore the complete locales folder and restart. / 请恢复完整的 locales 文件夹后重启。") 'pre-localization fatal errors should use the one built-in bilingual template.'
    $visibilityProbe = [pscustomobject]@{ Visibility = $null }
    Set-DetailVisibility $visibilityProbe $true
    Assert-Widget ($visibilityProbe.Visibility -eq 'Visible') 'visible token details should use Visible.'
    Set-DetailVisibility $visibilityProbe $false
    Assert-Widget ($visibilityProbe.Visibility -eq 'Collapsed') 'missing token details should use Collapsed.'
    $textProbe = [pscustomobject]@{ Text = '旧文本'; Visibility = $null }
    Set-DetailText $textProbe $false $null
    Assert-Widget ($textProbe.Text -eq '' -and $textProbe.Visibility -eq 'Collapsed') 'hidden token text should clear its previous in-memory value.'
    Set-DetailText $textProbe $true '新文本'
    Assert-Widget ($textProbe.Text -eq '新文本' -and $textProbe.Visibility -eq 'Visible') 'visible token text should replace its previous value.'

    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase -ErrorAction Stop
    $rendererWindow = [Windows.Markup.XamlReader]::Parse($widgetXaml)
    foreach ($controlName in 'DetailCard', 'RingValue', 'GlowRing', 'RemainingText', 'CircleHost', 'LimitWindowText',
        'ObservedText', 'ObservedDiagnosticText', 'DetailStatusText', 'UsageStatusText', 'RemainingDetailText',
        'RemainingDetailUnitText',
        'DetailTitleText', 'RemainingLabelText', 'ObservedLabelText', 'StatusLabelText',
        'ActivityTitleText', 'ActivityWindowText',
        'TokenDetailsPanel', 'ActiveTaskEmptyText', 'ActiveTaskList', 'TaskDetailsPanel', 'TaskTitleText',
        'TaskNoDataText', 'CumulativeRow', 'ContextRow', 'ContextPercentRow', 'CompositionRow',
        'CumulativeLabelText', 'ContextLabelText', 'ContextPercentLabelText', 'CompositionLabelText',
        'TaskCacheHitRow', 'TaskCacheMissRow', 'ReasoningRow', 'TaskCachedText', 'TaskCacheMissText',
        'TaskCacheHitLabelText', 'TaskCacheMissLabelText', 'ReasoningLabelText',
        'CumulativeText', 'ContextText', 'ContextPercentText', 'ContextBar', 'ContextFillColumn',
        'ContextRestColumn', 'CompositionText', 'CompositionBar', 'InputColumn', 'OutputColumn',
        'GlobalCacheDivider', 'GlobalCacheHitRow', 'GlobalCacheMissRow', 'CachedText', 'CachedMissText', 'ReasoningText',
        'GlobalCacheHitLabelText', 'GlobalCacheMissLabelText',
        'CountdownText', 'DetailAccentGlow', 'DetailAccentDot', 'TaskDetailAccentLine', 'ContextAccentFill',
        'InputAccentFill', 'OutputAccentFill') {
        Set-Variable -Name $controlName -Scope Script -Value $rendererWindow.FindName($controlName)
        Assert-Widget ($null -ne (Get-Variable -Name $controlName -Scope Script -ValueOnly)) ('renderer control should bind: ' + $controlName)
    }
    $namedFontContracts = @(
        @('DetailTitleText', 18), @('RemainingLabelText', 12), @('ObservedLabelText', 11), @('StatusLabelText', 11),
        @('ActivityTitleText', 15), @('ActivityWindowText', 11),
        @('DetailStatusText', 11), @('LimitWindowText', 15), @('CountdownText', 12),
        @('ObservedText', 12), @('UsageStatusText', 12), @('ObservedDiagnosticText', 11),
        @('ActiveTaskEmptyText', 12), @('TaskTitleText', 13), @('TaskNoDataText', 12),
        @('CumulativeLabelText', 12), @('ContextLabelText', 12), @('ContextPercentLabelText', 11),
        @('CompositionLabelText', 11), @('TaskCacheHitLabelText', 11), @('TaskCacheMissLabelText', 11),
        @('ReasoningLabelText', 11), @('GlobalCacheHitLabelText', 12), @('GlobalCacheMissLabelText', 12),
        @('CumulativeText', 12), @('ContextText', 12), @('ContextPercentText', 11),
        @('CompositionText', 11), @('TaskCachedText', 11), @('TaskCacheMissText', 11),
        @('ReasoningText', 11), @('CachedText', 12), @('CachedMissText', 12)
    )
    foreach ($fontContract in $namedFontContracts) {
        $control = Get-Variable -Name $fontContract[0] -Scope Script -ValueOnly
        Assert-Widget ($control.FontSize -eq $fontContract[1]) ($fontContract[0] + ' should use ' + $fontContract[1] + '-pixel text.')
    }
    Assert-Widget ($script:ObservedDiagnosticText.LineHeight -eq 17) 'observed diagnostics should use 17-pixel line height.'
    Assert-Widget ($script:DetailCard.Background -is [System.Windows.Media.LinearGradientBrush] -and
        $script:DetailCard.Background.GradientStops[0].Color.ToString() -eq '#FF242421' -and
        $script:DetailCard.Background.GradientStops[1].Color.ToString() -eq '#FF141513') 'the detail card should use the selected warm neutral surface.'
    $script:WidgetWindow = $rendererWindow
    $script:LastUsageState = $null
    $script:LastUsageDiagnostic = $null
    $script:LastShimmerObservationKey = $null
    $script:RendererRingPercent = $null
    $script:ActiveTaskRow = $null
    $script:ActiveTaskId = $null
    $script:WidgetPreferences = [pscustomobject]@{ Left = $null; Top = $null; Monitor = $null; Theme = 4; CodexDataDirectory = $null; Language = 'zh-CN' }
    $script:DetailMenuItem = [System.Windows.Controls.MenuItem]::new()
    $script:LanguageMenuItem = [System.Windows.Controls.MenuItem]::new()
    $script:LanguageMenuItems = @(foreach ($code in Get-WidgetLanguageCodes) { [pscustomobject]@{ Tag = $code; Header = $null; IsChecked = $false } })
    $script:ThemeMenuItems = @(for ($index = 0; $index -lt @(Get-WidgetThemes).Count; $index++) { [pscustomobject]@{ Tag = $index; Header = $null; IsChecked = $false } })
    $script:NotifyIcon = [pscustomobject]@{ Text = $null }
    $script:TrayShowItem = [pscustomobject]@{ Text = $null }
    $script:TrayExitItem = [pscustomobject]@{ Text = $null }
    $script:ExitMenuItem = [pscustomobject]@{ Header = $null }
    $script:DetailAccentBrush = $null
    $script:DetailAccentSoftBrush = $null
    $script:TaskDetailHideTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $rendererReminderDefinition = (Get-Command Register-UsageReminderThreshold -CommandType Function -ErrorAction Stop).Definition
    function Set-RingPercent { param([double]$Percent) $script:RendererRingPercent = $Percent }
    function Start-ShimmerAnimation { }
    function Register-UsageReminderThreshold { param($State, $Threshold) return $false }
    function Show-UsageReminder { param($State) }
    function Show-DetailPopup { }
    Apply-WidgetLanguage
    Assert-Widget ($script:DetailTitleText.Text -ceq '用量详情' -and
        $script:RemainingLabelText.Text -ceq '剩余用量' -and
        $script:TaskNoDataText.Text -ceq '该任务暂无令牌数据') 'the shared language application should populate named static labels.'
    Assert-Widget ($script:NotifyIcon.Text -ceq '用量小组件' -and $script:TrayShowItem.Text -ceq '显示小组件' -and
        $script:TrayExitItem.Text -ceq '退出小组件' -and $script:LanguageMenuItem.Header -ceq '语言' -and
        $script:ThemeMenuItems[0].Header -ceq '冰川青' -and $script:LanguageMenuItems[2].Header -ceq '英语') 'the shared language application should populate tray and context menus.'

    $rendererObservedAt = [datetime]'2026-07-30T20:15:30'
    $rendererTokens = [pscustomobject]@{
        CumulativeTokens = 40860000
        ContextTokens = 206411
        ContextLimit = 258400
        ContextPercent = 79.9
        InputPercent = 99.9
        OutputPercent = 0.1
        CacheHitTokens = 19916800
        CacheMissTokens = 709300
        CacheHitPercent = 96.6
        CacheMissPercent = 3.4
        ReasoningOutputPercent = 42.7
    }
    $taskPresentation = Get-TokenDetailPresentation -Details $rendererTokens -TaskCache
    Assert-Widget ($taskPresentation.CachedText -ceq
        "该任务缓存命中令牌　1992 万（96.6%）`n该任务缓存未命中令牌　70.9 万（3.4%）") 'task cache labels should be explicit.'
    Assert-Widget ($taskPresentation.CacheHitValueText -ceq '1992 万（96.6%）' -and
        $taskPresentation.CacheMissValueText -ceq '70.9 万（3.4%）') 'aligned cache rows should expose values without repeating their labels.'
    $rendererState = [pscustomobject]@{
        LimitWindows = @([pscustomobject]@{
            Name = 'secondary'; RemainingPercent = 39; ResetAt = (Get-Date).AddHours(2); WindowMinutes = 300
        })
        TokenDetails = $rendererTokens
        ObservedAt = $rendererObservedAt
        ActiveTasks = @(
            [pscustomobject]@{ Id = 'a'; Name = '任务甲'; UpdatedAt = $rendererObservedAt; TokenDetails = $rendererTokens },
            [pscustomobject]@{ Id = 'b'; Name = '任务乙'; UpdatedAt = $rendererObservedAt.AddMinutes(-1); TokenDetails = $null }
        )
        TaskNamesAvailable = $true
    }
    Set-WidgetState $rendererState
    Assert-Widget ($script:RemainingText.Text -eq '39%' -and $script:RemainingDetailText.Text -eq '39' -and
        $script:RemainingDetailUnitText.Text -eq '%' -and $script:RemainingDetailUnitText.Visibility -eq 'Visible' -and
        $script:LimitWindowText.Text -eq '5 小时' -and $script:CountdownText.Text -match '后重置$') 'the real renderer should match the selected quiet limit format.'
    Assert-Widget ($script:DetailStatusText.Text -eq '本机观测正常' -and
        $script:UsageStatusText.Text -eq '余量充足' -and
        $script:ObservedText.Text -eq '2026/7/30 20:15' -and
        $script:ObservedDiagnosticText.Visibility -eq 'Collapsed') 'the quiet metadata should separate status, observation, and diagnostics.'
    Assert-Widget ($script:TokenDetailsPanel.Visibility -eq 'Visible' -and
        $script:TaskDetailsPanel.Visibility -eq 'Collapsed') 'global cache data should show the outer panel without opening task details.'
    Assert-Widget ($script:CachedText.Text -ceq '1992 万（96.6%）' -and
        $script:CachedMissText.Text -ceq '70.9 万（3.4%）') 'the real renderer should align cumulative cache-hit and cache-miss values.'
    $countdownNow = [datetime]'2026-07-30T10:00:00'
    $countdownState = [pscustomobject]@{ LimitWindows = @(
        [pscustomobject]@{ Name = 'primary'; RemainingPercent = 50; ResetAt = $countdownNow.AddDays(2).AddHours(3).AddMinutes(59) }
    ) }
    $script:DetailPopup = [pscustomobject]@{ IsOpen = $true }
    Set-WidgetLanguage -Code 'en-US'
    $statusWidthProbe = [System.Windows.Controls.TextBlock]::new()
    $statusWidthProbe.FontFamily = $script:UsageStatusText.FontFamily
    $statusWidthProbe.FontSize = $script:UsageStatusText.FontSize
    $statusWidthProbe.FontStretch = $script:UsageStatusText.FontStretch
    $statusWidthProbe.FontStyle = $script:UsageStatusText.FontStyle
    $statusWidthProbe.FontWeight = $script:UsageStatusText.FontWeight
    foreach ($statusKey in 'status.sufficient', 'status.attention', 'status.waiting', 'status.waitingObservation') {
        $statusWidthProbe.Text = Get-WidgetText $statusKey
        $statusWidthProbe.Measure([System.Windows.Size]::new([double]::PositiveInfinity, [double]::PositiveInfinity))
        Assert-Widget ($statusWidthProbe.DesiredSize.Width -le 118) ('English ' + $statusKey + ' is ' +
            $statusWidthProbe.DesiredSize.Width.ToString('0.##', [cultureinfo]::InvariantCulture) + 'px; it should fit the 118px status column.')
    }
    Assert-Widget ((Format-TokenCount 40860000) -ceq '40.9M') 'English token counts should use M.'
    Assert-Widget ((Format-TokenCount 12300) -ceq '12.3K' -and
        (Format-TokenCount 1250000000) -ceq '1.25B') 'English compact token counts should preserve the K and B rounding contracts.'
    Assert-Widget ((Format-LimitWindow 300) -ceq '5 hours') 'English limit windows should use English units.'
    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -ceq 'Resets in 2 days 3 hours') 'English countdown should be localized.'
    Assert-Widget ($script:DetailTitleText.Text -ceq 'Usage details') 'live language switching should update static labels.'
    Assert-Widget ($script:DetailMenuItem.Header -ceq 'Hide details') 'live language switching should update menus.'
    Assert-Widget ($script:NotifyIcon.Text -ceq 'Usage widget' -and $script:TrayShowItem.Text -ceq 'Show widget' -and
        $script:TrayExitItem.Text -ceq 'Exit widget' -and $script:LanguageMenuItem.Header -ceq 'Language' -and
        $script:ThemeMenuItems[0].Header -ceq 'Glacier' -and $script:LanguageMenuItems[0].Header -ceq 'Simplified Chinese') 'live language switching should update every menu surface.'
    Assert-Widget ($script:CachedText.Text -notmatch '[\u4e00-\u9fff]') 'English rerendering should replace Chinese cache labels.'
    Assert-Widget ((Format-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.workerCause') (Get-WidgetText 'fatal.restoreFix')) -ceq
        "The usage widget could not start.`r`n`r`nCause: The background reader could not start.`r`nFix: Run the self-test; if it fails, restore the previous version.") 'English startup and worker errors should render through the localized fatal template.'
    Assert-Widget ((Get-WidgetText 'reminder.title' @(20)) -ceq '20% usage remaining' -and
        (Get-WidgetText 'reminder.body' @([datetime]'2026-07-30T20:15:30')) -ceq 'Resets at 7/30/2026 8:15 PM') 'English notification text and dates should use the active culture.'
    Set-WidgetLanguage -Code 'zh-TW'
    Assert-Widget ((Get-WidgetText 'detail.title') -ceq '用量詳細資料') 'Traditional Chinese title should be translated.'
    Set-WidgetLanguage -Code 'ja-JP'
    Assert-Widget ((Get-WidgetText 'detail.title') -ceq '使用量の詳細') 'Japanese title should be translated.'
    Assert-Widget ((Get-WidgetText 'cache.localHit') -ceq '累計キャッシュヒット' -and
        (Get-WidgetText 'cache.localMiss') -ceq '累計キャッシュミス') 'Japanese cumulative cache labels should fit the detail card.'
    Assert-Widget ((Format-TokenCount 40860000) -ceq '4086万') 'Japanese token counts should use 万.'
    Set-WidgetLanguage -Code 'ko-KR'
    Assert-Widget ((Get-WidgetText 'detail.title') -ceq '사용량 세부 정보') 'Korean title should be translated.'
    Assert-Widget ((Format-TokenCount 40860000) -ceq '4086만') 'Korean token counts should use 만.'
    Set-WidgetLanguage -Code 'zh-CN'
    $script:DetailPopup = $null
    $traditionalChinesePack = $script:WidgetLanguagePacks['zh-TW']
    [void]$script:WidgetLanguagePacks.Remove('zh-TW')
    $languageStateBeforeMissingPack = $script:CurrentLanguageCode + '|' + $script:CurrentLanguageCulture.Name + '|' + $script:WidgetPreferences.Language
    Set-WidgetLanguage -Code 'zh-TW' -Persist
    Assert-Widget (($script:CurrentLanguageCode + '|' + $script:CurrentLanguageCulture.Name + '|' + $script:WidgetPreferences.Language) -ceq
        $languageStateBeforeMissingPack) 'a missing optional language pack should leave language state unchanged.'
    $script:WidgetLanguagePacks['zh-TW'] = $traditionalChinesePack
    Assert-Widget ($script:ActiveTaskList.Children.Count -eq 2 -and
        $script:TaskDetailsPanel.Visibility -eq 'Collapsed') 'normal mode should show names without task details.'
    Assert-Widget ($script:ActiveTaskList.Children[0].Child.Text -ceq '任务甲') 'a task row should contain only the task name.'
    foreach ($taskRow in $script:ActiveTaskList.Children) {
        Assert-Widget ($taskRow.Padding.Left -eq 10 -and $taskRow.Padding.Top -eq 6 -and
            $taskRow.Padding.Right -eq 10 -and $taskRow.Padding.Bottom -eq 6 -and
            $taskRow.Margin.Top -eq 3 -and $taskRow.Margin.Bottom -eq 3 -and
            $taskRow.CornerRadius.TopLeft -eq 12 -and $taskRow.CornerRadius.TopRight -eq 12 -and
            $taskRow.CornerRadius.BottomRight -eq 12 -and $taskRow.CornerRadius.BottomLeft -eq 12 -and
            $taskRow.BorderThickness.Left -eq 1 -and $taskRow.BorderThickness.Top -eq 1 -and
            $taskRow.BorderThickness.Right -eq 1 -and $taskRow.BorderThickness.Bottom -eq 1 -and
            $taskRow.Child.FontSize -eq 12) 'each task row should be created with the light capsule geometry.'
    }
    if ([System.Windows.SystemParameters]::HighContrast) {
        foreach ($taskRow in $script:ActiveTaskList.Children) {
            Assert-Widget ([object]::ReferenceEquals($taskRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
                [object]::ReferenceEquals($taskRow.BorderBrush, [System.Windows.SystemColors]::GrayTextBrush) -and
                [object]::ReferenceEquals($taskRow.Child.Foreground, [System.Windows.SystemColors]::WindowTextBrush)) 'high-contrast task list initialization should use system neutral colors.'
        }
    }
    else {
        foreach ($taskRow in $script:ActiveTaskList.Children) {
            Assert-Widget ($taskRow.Background -is [System.Windows.Media.SolidColorBrush] -and
                $taskRow.Background.Color.ToString() -eq '#10FFFFFF' -and
                $taskRow.BorderBrush -is [System.Windows.Media.SolidColorBrush] -and
                $taskRow.BorderBrush.Color.ToString() -eq '#20FFFFFF' -and
                $taskRow.Child.Foreground -is [System.Windows.Media.SolidColorBrush] -and
                $taskRow.Child.Foreground.Color.ToString() -eq '#D0BDBBB4') 'normal task list initialization should use neutral light capsule colors.'
        }
    }
    foreach ($taskRow in $script:ActiveTaskList.Children) {
        Set-ActiveTaskRowAppearance -Row $taskRow -Selected $false -HighContrast $false
        Assert-Widget ($taskRow.Background -is [System.Windows.Media.SolidColorBrush] -and
            $taskRow.Background.Color.ToString() -eq '#10FFFFFF' -and
            $taskRow.BorderBrush -is [System.Windows.Media.SolidColorBrush] -and
            $taskRow.BorderBrush.Color.ToString() -eq '#20FFFFFF' -and
            $taskRow.Child.Foreground -is [System.Windows.Media.SolidColorBrush] -and
            $taskRow.Child.Foreground.Color.ToString() -eq '#D0BDBBB4') 'normal task row appearance should use neutral light capsule colors.'
    }
    Set-WidgetAppearance 39 -HighContrast $false
    $firstEnter = [System.Windows.Input.MouseEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0)
    $firstEnter.RoutedEvent = [System.Windows.UIElement]::MouseEnterEvent
    $script:ActiveTaskList.Children[0].RaiseEvent($firstEnter)
    $selectedRow = $script:ActiveTaskList.Children[0]
    Assert-Widget ($script:ActiveTaskRow -eq $selectedRow -and $selectedRow.Child.Text -ceq '•　任务甲') 'hover should make the first task active and mark it with the full-width-space dot.'
    if ([System.Windows.SystemParameters]::HighContrast) {
        Assert-Widget ([object]::ReferenceEquals($selectedRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
            [object]::ReferenceEquals($selectedRow.BorderBrush, [System.Windows.SystemColors]::HighlightBrush) -and
            [object]::ReferenceEquals($selectedRow.Child.Foreground, [System.Windows.SystemColors]::HighlightBrush)) 'high-contrast hover should use the system highlight task style.'
    }
    else {
        Assert-Widget ([object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush) -and
            [object]::ReferenceEquals($selectedRow.BorderBrush, $script:DetailAccentBrush) -and
            [object]::ReferenceEquals($selectedRow.Child.Foreground, $script:DetailAccentBrush)) 'normal hover should use the current themed task capsule.'
    }
    Set-ActiveTaskRowAppearance -Row $selectedRow -Selected $true -HighContrast $false
    Assert-Widget ($script:TaskTitleText.Text -ceq '任务甲' -and
        $script:TaskDetailsPanel.Visibility -eq 'Visible' -and
        $script:TaskCachedText.Text -ceq '1992 万（96.6%）' -and
        $script:TaskCacheMissText.Text -ceq '70.9 万（3.4%）') 'hover should show aligned selected-task details.'
    Assert-Widget ($selectedRow.Child.Text -ceq '•　任务甲' -and
        $selectedRow.Child.FontSize -eq 12 -and
        [object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $script:DetailAccentBrush) -and
        [object]::ReferenceEquals($selectedRow.Child.Foreground, $script:DetailAccentBrush)) 'the selected task should use the themed light capsule and full-width-space dot.'
    $cacheBeforeAppearance = $script:CachedText.Text + '|' + $script:CachedMissText.Text
    $visibilityControls = @(
        $script:TokenDetailsPanel, $script:TaskDetailsPanel, $script:ContextBar,
        $script:CompositionBar, $script:TaskCachedText, $script:TaskCacheMissText,
        $script:CachedText, $script:CachedMissText
    )
    $visibilityBeforeAppearance = @($visibilityControls | ForEach-Object { $_.Visibility })

    Set-WidgetAppearance 21 -HighContrast $false
    $themeBrush = $script:RingValue.Stroke
    Assert-Widget ($themeBrush -is [System.Windows.Media.LinearGradientBrush] -and
        $themeBrush.GradientStops[0].Color.ToString() -eq '#FF7CFFB2' -and
        $themeBrush.GradientStops[1].Color.ToString() -eq '#FF38D989') '21 percent should render the selected green theme.'
    foreach ($actualBrush in $script:GlowRing.Stroke, $script:RemainingDetailText.Foreground,
        $script:RemainingDetailUnitText.Foreground,
        $script:DetailAccentGlow.Background, $script:DetailAccentDot.Fill,
        $script:TaskDetailAccentLine.Background, $script:ContextAccentFill.Background,
        $script:DetailStatusText.Foreground, $selectedRow.Child.Foreground) {
        Assert-Widget ([object]::ReferenceEquals($actualBrush, $themeBrush)) 'theme appearance should share one accent brush across real controls.'
    }
    Assert-Widget ($script:InputAccentFill.Background.Color.ToString() -eq '#FF7CFFB2' -and
        $script:OutputAccentFill.Background.Color.ToString() -eq '#FF38D989' -and
        [object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $themeBrush) -and
        -not [object]::ReferenceEquals($script:TaskTitleText.Foreground, $themeBrush)) 'theme appearance should color bars and the selected task capsule without tinting the detail title.'

    Set-WidgetAppearance 20 -HighContrast $false
    Assert-Widget ($script:RingValue.Stroke.GradientStops[0].Color.ToString() -eq '#FFFFD166' -and
        $script:RingValue.Stroke.GradientStops[1].Color.ToString() -eq '#FFFFD166' -and
        [object]::ReferenceEquals($selectedRow.Child.Foreground, $script:RingValue.Stroke) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $script:RingValue.Stroke) -and
        [object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush) -and
        [object]::ReferenceEquals($script:RemainingDetailUnitText.Foreground, $script:RingValue.Stroke)) '20 percent should synchronize the gold warning accent.'

    Set-WidgetAppearance 10 -HighContrast $false
    Assert-Widget ($script:RingValue.Stroke.GradientStops[0].Color.ToString() -eq '#FFFF657D' -and
        $script:RingValue.Stroke.GradientStops[1].Color.ToString() -eq '#FFFF657D' -and
        [object]::ReferenceEquals($selectedRow.Child.Foreground, $script:RingValue.Stroke) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $script:RingValue.Stroke) -and
        [object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush) -and
        [object]::ReferenceEquals($script:RemainingDetailUnitText.Foreground, $script:RingValue.Stroke)) '10 percent should synchronize the red warning accent.'

    Set-WidgetAppearance -Unavailable -HighContrast $false
    $unavailableBrush = $script:RingValue.Stroke
    Assert-Widget ($unavailableBrush.Color.ToString() -eq '#FF708090' -and
        [object]::ReferenceEquals($script:GlowRing.Stroke, $unavailableBrush) -and
        [object]::ReferenceEquals($script:RemainingDetailText.Foreground, $unavailableBrush) -and
        [object]::ReferenceEquals($script:DetailAccentGlow.Background, $unavailableBrush) -and
        [object]::ReferenceEquals($script:DetailAccentDot.Fill, $unavailableBrush) -and
        [object]::ReferenceEquals($script:TaskDetailAccentLine.Background, $unavailableBrush) -and
        [object]::ReferenceEquals($script:ContextAccentFill.Background, $unavailableBrush) -and
        [object]::ReferenceEquals($script:InputAccentFill.Background, $unavailableBrush) -and
        [object]::ReferenceEquals($script:OutputAccentFill.Background, $unavailableBrush) -and
        [object]::ReferenceEquals($script:RemainingDetailUnitText.Foreground, $unavailableBrush) -and
        [object]::ReferenceEquals($selectedRow.Child.Foreground, $unavailableBrush) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $unavailableBrush) -and
        [object]::ReferenceEquals($selectedRow.Background, $script:DetailAccentSoftBrush)) 'unavailable appearance should synchronize gray accents with the selected row.'

    Set-WidgetAppearance 21 -HighContrast $true
    $highlightBrush = [System.Windows.SystemColors]::HighlightBrush
    $grayTextBrush = [System.Windows.SystemColors]::GrayTextBrush
    foreach ($actualBrush in $script:RingValue.Stroke, $script:GlowRing.Stroke,
        $script:RemainingDetailText.Foreground, $script:RemainingDetailUnitText.Foreground,
        $script:DetailAccentGlow.Background,
        $script:DetailAccentDot.Fill, $script:TaskDetailAccentLine.Background,
        $script:ContextAccentFill.Background, $script:DetailStatusText.Foreground,
        $selectedRow.Child.Foreground) {
        Assert-Widget ([object]::ReferenceEquals($actualBrush, $highlightBrush)) 'high contrast should share the system highlight brush across real controls.'
    }
    Assert-Widget ([object]::ReferenceEquals($script:InputAccentFill.Background, $highlightBrush) -and
        [object]::ReferenceEquals($script:OutputAccentFill.Background, $grayTextBrush) -and
        [object]::ReferenceEquals($selectedRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $highlightBrush)) 'high contrast should use system composition colors and a transparent selected row.'

    Set-WidgetAppearance 21 -Unavailable -HighContrast $true
    foreach ($actualBrush in $script:RingValue.Stroke, $script:GlowRing.Stroke,
        $script:RemainingDetailText.Foreground, $script:RemainingDetailUnitText.Foreground,
        $script:DetailAccentGlow.Background,
        $script:DetailAccentDot.Fill, $script:TaskDetailAccentLine.Background,
        $script:ContextAccentFill.Background, $script:InputAccentFill.Background,
        $script:OutputAccentFill.Background, $script:DetailStatusText.Foreground,
        $selectedRow.Child.Foreground) {
        Assert-Widget ([object]::ReferenceEquals($actualBrush, $grayTextBrush)) 'unavailable high contrast should share the system gray-text brush across real controls.'
    }
    Assert-Widget ([object]::ReferenceEquals($selectedRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
        [object]::ReferenceEquals($selectedRow.BorderBrush, $grayTextBrush)) 'unavailable high contrast should retain a transparent selected row.'
    Set-WidgetAppearance 21 -HighContrast $false

    Assert-Widget (($script:CachedText.Text + '|' + $script:CachedMissText.Text) -ceq $cacheBeforeAppearance) 'visual appearance changes must not replace global cache data.'
    for ($index = 0; $index -lt $visibilityControls.Count; $index++) {
        Assert-Widget ($visibilityControls[$index].Visibility -eq $visibilityBeforeAppearance[$index]) 'visual appearance changes must not alter control visibility.'
    }
    $secondEnter = [System.Windows.Input.MouseEventArgs]::new([System.Windows.Input.Mouse]::PrimaryDevice, 0)
    $secondEnter.RoutedEvent = [System.Windows.UIElement]::MouseEnterEvent
    $script:ActiveTaskList.Children[1].RaiseEvent($secondEnter)
    $secondRow = $script:ActiveTaskList.Children[1]
    Assert-Widget ($script:ActiveTaskRow -eq $secondRow -and $selectedRow.Child.Text -ceq '任务甲' -and
        $secondRow.Child.Text -ceq '•　任务乙') 'hover should move the active task marker from the first row to the second row.'
    if ([System.Windows.SystemParameters]::HighContrast) {
        Assert-Widget ([object]::ReferenceEquals($selectedRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
            [object]::ReferenceEquals($selectedRow.BorderBrush, [System.Windows.SystemColors]::GrayTextBrush) -and
            [object]::ReferenceEquals($selectedRow.Child.Foreground, [System.Windows.SystemColors]::WindowTextBrush) -and
            [object]::ReferenceEquals($secondRow.Background, [System.Windows.Media.Brushes]::Transparent) -and
            [object]::ReferenceEquals($secondRow.BorderBrush, [System.Windows.SystemColors]::HighlightBrush) -and
            [object]::ReferenceEquals($secondRow.Child.Foreground, [System.Windows.SystemColors]::HighlightBrush)) 'high-contrast hover should restore neutral colors before highlighting the next task.'
    }
    else {
        Assert-Widget ($selectedRow.Background -is [System.Windows.Media.SolidColorBrush] -and
            $selectedRow.Background.Color.ToString() -eq '#10FFFFFF' -and
            $selectedRow.BorderBrush -is [System.Windows.Media.SolidColorBrush] -and
            $selectedRow.BorderBrush.Color.ToString() -eq '#20FFFFFF' -and
            $selectedRow.Child.Foreground -is [System.Windows.Media.SolidColorBrush] -and
            $selectedRow.Child.Foreground.Color.ToString() -eq '#D0BDBBB4' -and
            [object]::ReferenceEquals($secondRow.Background, $script:DetailAccentSoftBrush) -and
            [object]::ReferenceEquals($secondRow.BorderBrush, $script:DetailAccentBrush) -and
            [object]::ReferenceEquals($secondRow.Child.Foreground, $script:DetailAccentBrush)) 'normal hover should restore the first neutral capsule before theming the second task.'
    }
    Set-ActiveTaskRowAppearance -Row $selectedRow -Selected $false -HighContrast $false
    Set-ActiveTaskRowAppearance -Row $secondRow -Selected $true -HighContrast $false
    Assert-Widget ($script:TaskTitleText.Text -ceq '任务乙' -and
        $script:TaskNoDataText.Visibility -eq 'Visible' -and
        $selectedRow.Child.Text -ceq '任务甲' -and
        $selectedRow.Background -is [System.Windows.Media.SolidColorBrush] -and
        $selectedRow.Background.Color.ToString() -eq '#10FFFFFF' -and
        $selectedRow.BorderBrush -is [System.Windows.Media.SolidColorBrush] -and
        $selectedRow.BorderBrush.Color.ToString() -eq '#20FFFFFF' -and
        $selectedRow.Child.Foreground -is [System.Windows.Media.SolidColorBrush] -and
        $selectedRow.Child.Foreground.Color.ToString() -eq '#D0BDBBB4' -and
        [object]::ReferenceEquals($secondRow.Background, $script:DetailAccentSoftBrush) -and
        [object]::ReferenceEquals($secondRow.BorderBrush, $script:DetailAccentBrush) -and
        [object]::ReferenceEquals($secondRow.Child.Foreground, $script:DetailAccentBrush)) 'hover should restore the first task neutral capsule and theme the second task.'
    $highContrastProbe = [System.Windows.Controls.Border]::new()
    $highContrastProbe.Tag = [pscustomobject]@{ Name = '高对比任务' }
    $highContrastProbe.Child = [System.Windows.Controls.TextBlock]::new()
    $childlessRow = [System.Windows.Controls.Border]::new()
    Set-ActiveTaskRowAppearance -Row $childlessRow -Selected $false -HighContrast $false
    Assert-Widget ($null -eq $childlessRow.Child) 'task row appearance should ignore a row without a child.'
    Set-ActiveTaskRowAppearance -Row $highContrastProbe -Selected $false -HighContrast $true
    Assert-Widget ([object]::ReferenceEquals($highContrastProbe.Background, [System.Windows.Media.Brushes]::Transparent) -and
        [object]::ReferenceEquals($highContrastProbe.BorderBrush, [System.Windows.SystemColors]::GrayTextBrush) -and
        [object]::ReferenceEquals($highContrastProbe.Child.Foreground, [System.Windows.SystemColors]::WindowTextBrush)) 'an unselected high-contrast task should use system neutral colors.'
    Set-ActiveTaskRowAppearance -Row $highContrastProbe -Selected $true -HighContrast $true
    Assert-Widget ([object]::ReferenceEquals($highContrastProbe.Background, [System.Windows.Media.Brushes]::Transparent) -and
        [object]::ReferenceEquals($highContrastProbe.BorderBrush, [System.Windows.SystemColors]::HighlightBrush) -and
        [object]::ReferenceEquals($highContrastProbe.Child.Foreground, [System.Windows.SystemColors]::HighlightBrush)) 'a selected high-contrast task should use system highlight colors.'
    Hide-ActiveTaskDetails
    foreach ($element in $script:CumulativeText, $script:ContextText, $script:ContextPercentText,
        $script:ContextBar, $script:CompositionText, $script:CompositionBar, $script:TaskCachedText,
        $script:TaskCacheMissText, $script:ReasoningText) {
        Assert-Widget ($element.Visibility -eq 'Collapsed') 'global cache rendering should leave task-only details hidden.'
    }

    $script:LastUsageState = $null
    $script:LastUsageDiagnostic = 'missing_directory'
    Set-WidgetState $null
    Assert-Widget ($script:RemainingText.Text -eq '—' -and $script:RemainingDetailText.Text -eq '—' -and
        $script:RemainingDetailUnitText.Visibility -eq 'Collapsed' -and
        $script:LimitWindowText.Text -eq '暂无可用数据' -and
        $script:DetailStatusText.Text -eq '等待本机观测' -and $script:UsageStatusText.Text -eq '暂无数据' -and
        $script:ObservedText.Text -eq '—' -and
        $script:ObservedDiagnosticText.Text -eq '未找到本机会话目录，请先完成一次编码任务。') 'no history should render the quiet safe Chinese diagnostic.'
    Assert-Widget ($script:TokenDetailsPanel.Visibility -eq 'Collapsed' -and $script:TaskDetailsPanel.Visibility -eq 'Collapsed' -and
        $script:ContextBar.Visibility -eq 'Collapsed' -and $script:CompositionBar.Visibility -eq 'Collapsed') 'no history should collapse the real token panel and bars.'
    foreach ($element in $script:CumulativeText, $script:ContextText, $script:ContextPercentText,
        $script:CompositionText, $script:TaskCachedText, $script:TaskCacheMissText,
        $script:CachedText, $script:CachedMissText, $script:ReasoningText) {
        Assert-Widget ($element.Visibility -eq 'Collapsed' -and $element.Text -eq '') 'no history should clear and collapse every real token text row.'
    }

    $partialRendererState = [pscustomobject]@{
        LimitWindows = $rendererState.LimitWindows
        TokenDetails = [pscustomobject]@{ CumulativeTokens = 40860000; ContextTokens = 206411 }
        ObservedAt = $rendererObservedAt
    }
    $script:LastUsageDiagnostic = $null
    Set-WidgetState $partialRendererState
    Assert-Widget ($script:TokenDetailsPanel.Visibility -eq 'Collapsed' -and
        $script:TaskDetailsPanel.Visibility -eq 'Collapsed' -and $script:CachedText.Visibility -eq 'Collapsed') 'non-cache global details should not populate the task panel.'

    $expiredRendererState = [pscustomobject]@{
        LimitWindows = @([pscustomobject]@{
            Name = 'primary'; RemainingPercent = 77; ResetAt = (Get-Date).AddMinutes(-1); WindowMinutes = 10080
        })
        TokenDetails = [pscustomobject]@{ CumulativeTokens = 40860000 }
        ObservedAt = $rendererObservedAt
    }
    Set-WidgetState $expiredRendererState
    Assert-Widget ($script:RemainingText.Text -eq '—' -and $script:LimitWindowText.Text -eq '等待新周期' -and
        $script:UsageStatusText.Text -eq '等待新周期' -and
        $script:TokenDetailsPanel.Visibility -eq 'Collapsed') 'expired limits should wait without treating global totals as task details.'

    $script:LastUsageDiagnostic = $null
    Set-WidgetState $rendererState
    $script:LastUsageDiagnostic = 'read_failed'
    Set-WidgetState $null
    Assert-Widget ($script:RemainingText.Text -eq '39%' -and
        $script:CachedText.Text -eq '1992 万（96.6%）' -and
        $script:CachedMissText.Text -eq '70.9 万（3.4%）' -and
        $script:TokenDetailsPanel.Visibility -eq 'Visible') 'a failed refresh should retain the real limit and global cache presentation.'
    Assert-Widget ($script:ObservedText.Text -eq '2026/7/30 20:15' -and
        $script:ObservedDiagnosticText.Text -eq '会话记录读取失败，请确认当前账户可以读取后重试。') 'a failed refresh should preserve observation time and show its safe diagnostic separately.'
    $script:TaskDetailHideTimer.Stop()
    $rendererWindow.Close()
    Set-Item -Path Function:Register-UsageReminderThreshold -Value ([scriptblock]::Create($rendererReminderDefinition))

    $popupWorkArea = [pscustomobject]@{ Left = 0.0; Top = 0.0; Width = 1920.0; Height = 1080.0; Right = 1920.0; Bottom = 1080.0 }
    $popupPosition = Get-DetailPopupPosition 100 100 82 310 400 $popupWorkArea
    Assert-Widget (-not $popupPosition.OpensLeft -and $popupPosition.Left -eq 194 -and $popupPosition.Top -eq 100) 'detail popup should open to the right when space allows.'
    $popupPosition = Get-DetailPopupPosition 1800 100 82 310 400 $popupWorkArea
    Assert-Widget ($popupPosition.OpensLeft -and $popupPosition.Left -eq 1478 -and $popupPosition.Top -eq 100) 'detail popup should open left when the right side is constrained.'
    $popupPosition = Get-DetailPopupPosition 100 1000 82 310 300 $popupWorkArea
    Assert-Widget ($popupPosition.Top -eq 772) 'detail popup should clamp to the bottom work-area inset.'
    $negativePopupArea = [pscustomobject]@{ Left = -1920.0; Top = -200.0; Width = 1920.0; Height = 1080.0; Right = 0.0; Bottom = 880.0 }
    $popupPosition = Get-DetailPopupPosition -1900 -180 82 310 1000 $negativePopupArea
    Assert-Widget (-not [double]::IsNaN([double]$popupPosition.Left) -and -not [double]::IsInfinity([double]$popupPosition.Left) -and
        -not [double]::IsNaN([double]$popupPosition.Top) -and -not [double]::IsInfinity([double]$popupPosition.Top) -and
        $popupPosition.Left -ge -1912 -and $popupPosition.Left + 310 -le -8 -and
        $popupPosition.Top -ge -192 -and $popupPosition.Top + 1000 -le 872) 'negative-coordinate popup output should remain finite and clamped.'
    $smallPopupArea = [pscustomobject]@{ Left = -600.0; Top = -200.0; Width = 300.0; Height = 170.0; Right = -300.0; Bottom = -30.0 }
    $popupPosition = Get-DetailPopupPosition -580 -180 82 310 180 $smallPopupArea
    Assert-Widget ($popupPosition.CardWidth -eq 284 -and $popupPosition.CardHeight -eq 154 -and
        $popupPosition.Left -ge -592 -and $popupPosition.Left + $popupPosition.CardWidth -le -308 -and
        $popupPosition.Top -ge -192 -and $popupPosition.Top + $popupPosition.CardHeight -le -38) 'oversized popup cards should shrink inside a small negative-coordinate work area.'

    $primaryScreen = [pscustomobject]@{ DeviceName = 'PRIMARY' }
    $requestedScreen = [pscustomobject]@{ DeviceName = 'DISPLAY2' }
    $actualScreen = [pscustomobject]@{ DeviceName = 'DISPLAY1' }
    Assert-Widget ((Resolve-WidgetRestoreScreen $requestedScreen $actualScreen $primaryScreen $false) -eq $actualScreen) 'a failed coarse move should use the actual screen.'
    Assert-Widget ((Resolve-WidgetRestoreScreen $requestedScreen $actualScreen $primaryScreen $true) -eq $actualScreen) 'a coarse move landing on another screen should use the actual screen.'
    $matchingActual = [pscustomobject]@{ DeviceName = 'DISPLAY2' }
    Assert-Widget ((Resolve-WidgetRestoreScreen $requestedScreen $matchingActual $primaryScreen $true) -eq $requestedScreen) 'a successful coarse move to the requested screen should retain that screen.'

    $sourceText = [System.IO.File]::ReadAllText($PSCommandPath)
    $runtimeMarker = 'if ($SelfTest) { return }'
    $runtimeStart = $sourceText.LastIndexOf($runtimeMarker, [StringComparison]::Ordinal)
    $runtimeSource = if ($runtimeStart -ge 0) { $sourceText.Substring($runtimeStart) } else { '' }
    Assert-Widget ($runtimeSource.Length -gt 0) 'runtime source should follow the self-test return guard.'
    Assert-Widget ($runtimeSource.Contains('-UiCulture ([cultureinfo]::CurrentUICulture)')) 'startup localization should evaluate the current UI culture before argument binding.'
    Assert-Widget ($runtimeSource.Contains('if ($null -eq $script:WidgetPreferences.Language) { $script:WidgetPreferences.Language = $script:CurrentLanguageCode }')) 'startup should default only a null language preference to the active fallback language.'
    $pickerFunctionName = 'Show-CodexDataDirectoryPicker'
    Assert-Widget ($runtimeSource.Contains(('function ' + $pickerFunctionName))) 'runtime should provide a Codex data directory picker.'
    $pickerCallMarker = '$selectedCodexDataDirectory = Show-CodexDataDirectoryPicker'
    $pickerCallIndex = $runtimeSource.IndexOf($pickerCallMarker, [StringComparison]::Ordinal)
    $workerInitializeIndex = $runtimeSource.LastIndexOf('Initialize-UsageWorker', [StringComparison]::Ordinal)
    Assert-Widget ($pickerCallIndex -ge 0 -and $workerInitializeIndex -gt $pickerCallIndex) 'directory selection should run once before the usage worker starts.'
    $refreshStart = $runtimeSource.IndexOf('function Start-UsageRefresh', [StringComparison]::Ordinal)
    $refreshEnd = $runtimeSource.IndexOf('function Complete-UsageRefresh', $refreshStart, [StringComparison]::Ordinal)
    $refreshSource = if ($refreshStart -ge 0 -and $refreshEnd -gt $refreshStart) { $runtimeSource.Substring($refreshStart, $refreshEnd - $refreshStart) } else { '' }
    Assert-Widget ($refreshSource.Contains("AddParameter('DataDirectory'")) 'the background refresh should receive the resolved data directory.'
    $timerStart = $runtimeSource.IndexOf('$script:WidgetTimer.Add_Tick({', [StringComparison]::Ordinal)
    $timerEnd = $runtimeSource.IndexOf('$script:WidgetTimer.Start()', $timerStart, [StringComparison]::Ordinal)
    $timerSource = if ($timerStart -ge 0 -and $timerEnd -gt $timerStart) { $runtimeSource.Substring($timerStart, $timerEnd - $timerStart) } else { '' }
    Assert-Widget (-not $timerSource.Contains($pickerFunctionName)) 'the refresh timer should never repeat the directory prompt.'
    foreach ($runtimeBinding in @(
        '$script:RemainingDetailUnitText = $script:WidgetWindow.FindName(''RemainingDetailUnitText'')',
        '$script:DetailTitleText = $script:WidgetWindow.FindName(''DetailTitleText'')',
        '$script:RemainingLabelText = $script:WidgetWindow.FindName(''RemainingLabelText'')',
        '$script:ObservedLabelText = $script:WidgetWindow.FindName(''ObservedLabelText'')',
        '$script:StatusLabelText = $script:WidgetWindow.FindName(''StatusLabelText'')',
        '$script:ActivityTitleText = $script:WidgetWindow.FindName(''ActivityTitleText'')',
        '$script:ActivityWindowText = $script:WidgetWindow.FindName(''ActivityWindowText'')',
        '$script:TaskNoDataText = $script:WidgetWindow.FindName(''TaskNoDataText'')',
        '$script:CumulativeLabelText = $script:WidgetWindow.FindName(''CumulativeLabelText'')',
        '$script:ContextLabelText = $script:WidgetWindow.FindName(''ContextLabelText'')',
        '$script:ContextPercentLabelText = $script:WidgetWindow.FindName(''ContextPercentLabelText'')',
        '$script:CompositionLabelText = $script:WidgetWindow.FindName(''CompositionLabelText'')',
        '$script:TaskCacheHitLabelText = $script:WidgetWindow.FindName(''TaskCacheHitLabelText'')',
        '$script:TaskCacheMissLabelText = $script:WidgetWindow.FindName(''TaskCacheMissLabelText'')',
        '$script:ReasoningLabelText = $script:WidgetWindow.FindName(''ReasoningLabelText'')',
        '$script:GlobalCacheHitLabelText = $script:WidgetWindow.FindName(''GlobalCacheHitLabelText'')',
        '$script:GlobalCacheMissLabelText = $script:WidgetWindow.FindName(''GlobalCacheMissLabelText'')'
    )) {
        Assert-Widget ($runtimeSource.Contains($runtimeBinding)) ('runtime control binding should exist: ' + $runtimeBinding)
    }
    Assert-Widget (-not $runtimeSource.Contains('$script:ActivityHeaderCapsule = $script:WidgetWindow.FindName(''ActivityHeaderCapsule'')')) 'runtime source should not bind the removed activity header capsule.'
    $positionStart = $runtimeSource.LastIndexOf('function Set-WidgetPosition', [StringComparison]::Ordinal)
    $positionEnd = $runtimeSource.IndexOf('function Get-WidgetHwnd', $positionStart, [StringComparison]::Ordinal)
    Assert-Widget ($positionStart -ge 0 -and $positionEnd -gt $positionStart) 'the position animation function should be inspectable.'
    $positionSource = $runtimeSource.Substring($positionStart, $positionEnd - $positionStart)
    Assert-Widget (-not $positionSource.Contains('Add_Completed')) 'position animation should not depend on an asynchronous completion callback.'
    foreach ($contract in ('Get-Detail' + 'PopupPosition'), ('Set-Widget' + 'Appearance'), ('Start-Shimmer' + 'Animation'),
        ('SetProcessDpiAwareness' + 'Context'), ('Focus' + 'Ring'), 'theme.glacier', 'theme.nebula', 'theme.ocean', 'theme.sakura',
        ('FromMilliseconds' + '(250)'), ('FromMilliseconds' + '(150)'),
        ('[System.Windows.Input.Key]' + '::System'), ('[System.Windows.Input.Keyboard]' + '::Modifiers')) {
        Assert-Widget ($sourceText.Contains($contract)) ('interaction contract should contain: ' + $contract)
    }
    $cancelHideName = 'Cancel-DetailPopup' + 'Hide'
    Assert-Widget ($sourceText.Contains(('function ' + $cancelHideName))) 'popup hover entry should share one fade-cancellation function.'
    $circleEnterSource = [regex]::Match($sourceText, '(?s)\$script:CircleHost\.Add_MouseEnter\(\{(.*?)\}\)').Groups[1].Value
    $cardEnterSource = [regex]::Match($sourceText, '(?s)\$script:DetailCard\.Add_MouseEnter\(\{(.*?)\}\)').Groups[1].Value
    Assert-Widget ($circleEnterSource.Contains($cancelHideName) -and $cardEnterSource.Contains($cancelHideName)) 'both hover-entry paths should cancel an active detail fade.'
    $hideStart = $sourceText.IndexOf(('function Hide-' + 'DetailPopup'), [StringComparison]::Ordinal)
    $hideEnd = $sourceText.IndexOf(('function Toggle-' + 'DetailPopup'), $hideStart, [StringComparison]::Ordinal)
    $hideDefinition = if ($hideStart -ge 0 -and $hideEnd -gt $hideStart) { $sourceText.Substring($hideStart, $hideEnd - $hideStart) } else { '' }
    Assert-Widget ($hideDefinition -match 'CircleHost\.IsMouseOver' -and $hideDefinition -match 'DetailCard\.IsMouseOver') 'fade completion should recheck both hover targets before closing.'
    $showStart = $sourceText.IndexOf(('function Show-' + 'DetailPopup'), [StringComparison]::Ordinal)
    $showEnd = $sourceText.IndexOf(('function Cancel-' + 'DetailPopupHide'), $showStart, [StringComparison]::Ordinal)
    $showDefinition = if ($showStart -ge 0 -and $showEnd -gt $showStart) { $sourceText.Substring($showStart, $showEnd - $showStart) } else { '' }
    Assert-Widget ($showDefinition -match '\$FromHover' -and $showDefinition -match '\$script:HasShownHoverShimmer') 'detail popup shimmer should be gated to its first hover opening.'
    $stateStart = $sourceText.IndexOf(('function Set-' + 'WidgetState'), [StringComparison]::Ordinal)
    $stateEnd = $sourceText.IndexOf(('function Initialize-' + 'UsageWorker'), $stateStart, [StringComparison]::Ordinal)
    $stateDefinition = if ($stateStart -ge 0 -and $stateEnd -gt $stateStart) { $sourceText.Substring($stateStart, $stateEnd - $stateStart) } else { '' }
    Assert-Widget ($stateDefinition -match '\$observationKey' -and $stateDefinition -match '\$script:LastShimmerObservationKey') 'fresh usage shimmer should be gated by an observation key.'
    Assert-Widget ([regex]::Matches($stateDefinition, 'AutomationProperties\]::SetName').Count -ge 2 -and
        $stateDefinition -match '\$script:CircleHost' -and $stateDefinition -match '\$script:WidgetWindow') 'state rendering should update automation names on both the circle and window.'
    foreach ($stateLabel in 'accessibility.normalState', 'accessibility.attentionState', 'accessibility.criticalState',
        'accessibility.waitingState', 'accessibility.unavailableState', 'accessibility.usageSummary') {
        Assert-Widget ($stateDefinition.Contains($stateLabel)) ('automation state should include: ' + $stateLabel)
    }
    foreach ($startupContract in
        'fatal.unsupportedHost', 'fatal.unsupportedThread', 'fatal.uiLoadCause',
        'fatal.mutexCause', 'fatal.windowCause', 'fatal.notificationCause', 'fatal.workerCause',
        'fatal.useLauncherFix', 'fatal.uiRepairFix', 'fatal.exitOldFix', 'fatal.restoreFix', 'fatal.restartNotificationFix') {
        Assert-Widget ($runtimeSource.Contains($startupContract)) ('startup errors should include: ' + $startupContract)
    }
    foreach ($runtimeContract in 'app.alreadyRunning', 'menu.showWidget', 'menu.exit', 'menu.language',
        'reminder.title', 'reminder.body', 'ContextMenuStrip', 'TrayMenu', 'LanguageMenuItems') {
        Assert-Widget ($runtimeSource.Contains($runtimeContract)) ('runtime UI contract should include: ' + $runtimeContract)
    }
    Assert-Widget ($runtimeSource.Contains('foreach ($theme in @(Get-WidgetThemes))')) 'the theme menu should use the shared catalog.'
    foreach ($legacyText in ('Reading' + ' data'), ('NO' + ' DATA'), ('Reset' + ' '), ('Used' + ':'),
        ('Plan' + ':'), ('Credits' + ':'), ('Updated' + ':'), ('Reminder' + ':'), ('Codex Usage' + ' Widget')) {
        Assert-Widget (-not $sourceText.Contains($legacyText)) ('source should not contain legacy visible text: ' + $legacyText)
    }
    Assert-Widget (-not $sourceText.Contains(('Drag' + 'Region'))) 'the obsolete drag-only region should remain absent.'

    $themeAppearances = @(
        [pscustomobject]@{ NameKey = 'theme.glacier'; Start = '#7BFFE0'; End = '#55CFFF' },
        [pscustomobject]@{ NameKey = 'theme.nebula'; Start = '#D8A7FF'; End = '#7C8CFF' },
        [pscustomobject]@{ NameKey = 'theme.ocean'; Start = '#82D9FF'; End = '#4478FF' },
        [pscustomobject]@{ NameKey = 'theme.sakura'; Start = '#FFB1D8'; End = '#FF719D' },
        [pscustomobject]@{ NameKey = 'theme.aurora'; Start = '#7CFFB2'; End = '#38D989' },
        [pscustomobject]@{ NameKey = 'theme.mica'; Start = '#F1F5FF'; End = '#9DAAC3' },
        [pscustomobject]@{ NameKey = 'theme.sunset'; Start = '#FFC28A'; End = '#FF806D' },
        [pscustomobject]@{ NameKey = 'theme.lime'; Start = '#DCFF7C'; End = '#7DDB66' }
    )
    $themes = @(Get-WidgetThemes)
    Assert-Widget ($themes.Count -eq 8) 'the theme catalog should expose eight themes.'
    foreach ($theme in 0..7) {
        $appearance = Get-WidgetAppearance -RemainingPercent 21 -Theme $theme
        Assert-Widget ($appearance.NameKey -ceq $themeAppearances[$theme].NameKey -and
            $appearance.Start -eq $themeAppearances[$theme].Start -and
            $appearance.End -eq $themeAppearances[$theme].End) 'each normal theme should match the approved catalog.'
    }
    $attentionAppearance = Get-WidgetAppearance -RemainingPercent 20 -Theme 7
    $urgentAppearance = Get-WidgetAppearance -RemainingPercent 10 -Theme 6
    Assert-Widget ($attentionAppearance.NameKey -ceq 'accessibility.attentionState' -and
        $attentionAppearance.Start -eq '#FFD166' -and $attentionAppearance.End -eq '#FFD166') 'attention should override every theme.'
    Assert-Widget ($urgentAppearance.NameKey -ceq 'accessibility.criticalState' -and
        $urgentAppearance.Start -eq '#FF657D' -and $urgentAppearance.End -eq '#FF657D') 'urgent should override every theme.'

    Assert-Widget ((Format-TokenCount 40860000) -eq '4086 万') 'large token counts should use Chinese ten-thousand formatting.'
    Assert-Widget ((Format-TokenCount 206411) -eq '20.6 万') 'compact token counts should preserve one decimal place.'
    Assert-Widget ((Format-TokenCount 9999) -eq '9,999') 'small token counts should use grouped Chinese-region formatting.'
    Assert-Widget ((Format-LimitWindow 300) -eq '5 小时') 'hour windows should use Chinese text.'
    Assert-Widget ((Format-LimitWindow 10080) -eq '7 天') 'day windows should use Chinese text.'
    Assert-Widget ((Format-LimitWindow 45) -eq '45 分钟') 'other positive integer windows should remain in minutes.'
    Assert-Widget ((Format-LimitWindow $null) -eq '未知周期') 'missing window length should remain visible.'
    $largeIntegerMinutes = [decimal]::Parse('9007199254740993', [Globalization.CultureInfo]::InvariantCulture)
    $largeFractionalMinutes = [decimal]::Parse('9007199254740992.5', [Globalization.CultureInfo]::InvariantCulture)
    Assert-Widget ((Format-LimitWindow $largeIntegerMinutes) -eq '9007199254740993 分钟') 'large integer minutes must retain their exact value.'
    Assert-Widget ((Format-LimitWindow ([double]9007199254740991)) -eq '9007199254740991 分钟') 'the largest lossless double integer must retain its exact value.'
    Assert-Widget ((Format-LimitWindow ([single]16777215)) -eq '16777215 分钟') 'the largest lossless single integer must retain its exact value.'

    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -eq '2 天 3 小时后重置') 'day countdowns should use Chinese day and hour units.'
    $countdownState.LimitWindows[0].ResetAt = $countdownNow.AddHours(3).AddMinutes(4).AddSeconds(59)
    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -eq '3 小时 4 分钟后重置') 'hour countdowns should use Chinese hour and minute units.'
    $countdownState.LimitWindows[0].ResetAt = $countdownNow.AddSeconds(61)
    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -eq '2 分钟后重置') 'minute countdowns should round up.'
    $countdownState.LimitWindows[0].ResetAt = $countdownNow.AddMilliseconds(1)
    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -eq '1 分钟后重置') 'positive sub-minute countdowns should remain visible.'
    $countdownState.LimitWindows[0].ResetAt = $countdownNow
    Assert-Widget ((Format-ResetCountdown -State $countdownState -Now $countdownNow) -eq '等待新周期') 'expired historical windows should wait for a new cycle.'
    Assert-Widget ((Format-ResetCountdown -State $null -Now $countdownNow) -eq '—') 'missing history should show an em dash.'

    $diagnostics = [ordered]@{
        missing_directory = '未找到本机会话目录，请先完成一次编码任务。'
        empty_directory   = '还没有本机会话记录，完成一次编码任务后会自动刷新。'
        read_failed       = '会话记录读取失败，请确认当前账户可以读取后重试。'
        no_valid_event    = '没有找到可识别的用量事件，可先运行自检确认兼容性。'
        unknown           = '暂无可用数据。'
    }
    foreach ($code in $diagnostics.Keys) {
        Assert-Widget ((Format-UsageDiagnostic $code) -eq $diagnostics[$code]) 'diagnostics should map to safe Chinese text.'
    }

    $visibleStrings = @(Get-WidgetVisibleStrings)
    Assert-Widget ($visibleStrings.Count -eq $requiredLanguageKeys.Count) 'visible strings should cover the complete canonical language-key catalog.'
    foreach ($key in $requiredLanguageKeys) {
        $required = Get-WidgetText $key
        Assert-Widget ($visibleStrings -ccontains $required -and -not [string]::IsNullOrWhiteSpace($required)) ('visible strings should include: ' + $key)
    }

    foreach ($invalidCase in @(
        @{ Name = 'negative remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent -1 -Theme 0 } },
        @{ Name = 'remaining percentage above 100'; Call = { Get-WidgetAppearance -RemainingPercent 101 -Theme 0 } },
        @{ Name = 'non-finite remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent ([double]::NaN) -Theme 0 } },
        @{ Name = 'infinite remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent ([double]::PositiveInfinity) -Theme 0 } },
        @{ Name = 'boolean remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent $true -Theme 0 } },
        @{ Name = 'string remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent '20' -Theme 0 } },
        @{ Name = 'negative theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme -1 } },
        @{ Name = 'theme above 7'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme 8 } },
        @{ Name = 'fractional theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme 1.5 } },
        @{ Name = 'non-finite theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme ([double]::NaN) } },
        @{ Name = 'boolean theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme $true } },
        @{ Name = 'string theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme '1' } },
        @{ Name = 'enum appearance value'; Call = { Get-WidgetAppearance -RemainingPercent ([DayOfWeek]::Monday) -Theme 0 } },
        @{ Name = 'null remaining percentage'; Call = { Get-WidgetAppearance -RemainingPercent $null -Theme 0 } },
        @{ Name = 'null theme'; Call = { Get-WidgetAppearance -RemainingPercent 50 -Theme $null } },
        @{ Name = 'negative token count'; Call = { Format-TokenCount -1 } },
        @{ Name = 'non-finite token count'; Call = { Format-TokenCount ([double]::PositiveInfinity) } },
        @{ Name = 'boolean token count'; Call = { Format-TokenCount $false } },
        @{ Name = 'string token count'; Call = { Format-TokenCount '9999' } },
        @{ Name = 'enum token count'; Call = { Format-TokenCount ([DayOfWeek]::Monday) } },
        @{ Name = 'null token count'; Call = { Format-TokenCount $null } },
        @{ Name = 'zero limit window'; Call = { Format-LimitWindow 0 } },
        @{ Name = 'negative limit window'; Call = { Format-LimitWindow -1 } },
        @{ Name = 'non-finite limit window'; Call = { Format-LimitWindow ([double]::NaN) } },
        @{ Name = 'fractional limit window'; Call = { Format-LimitWindow 1.5 } },
        @{ Name = 'large fractional limit window'; Call = { Format-LimitWindow $largeFractionalMinutes } },
        @{ Name = 'overflowing limit window'; Call = { Format-LimitWindow ([double]::MaxValue) } },
        @{ Name = 'single above its lossless integer range'; Call = { Format-LimitWindow ([single]16777216) } },
        @{ Name = 'boolean limit window'; Call = { Format-LimitWindow $true } },
        @{ Name = 'string limit window'; Call = { Format-LimitWindow '300' } },
        @{ Name = 'enum limit window'; Call = { Format-LimitWindow ([DayOfWeek]::Monday) } }
    )) {
        $rejected = $false
        try { & $invalidCase.Call | Out-Null }
        catch [System.ArgumentException] { $rejected = $true }
        catch [System.Management.Automation.ParameterBindingException] { $rejected = $true }
        Assert-Widget $rejected ($invalidCase.Name + ' should be rejected.')
    }

    $future = [DateTimeOffset]::UtcNow.AddHours(1).ToUnixTimeSeconds()
    $fixtureEvent = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures\rate-limits.jsonl') | Select-Object -First 1 | ConvertFrom-Json -ErrorAction Stop
    $valid = (Get-EventRateLimits $fixtureEvent) | ConvertTo-Json -Depth 10 -Compress
    $state = ConvertTo-UsageState -Json $valid
    Assert-Widget ($state.LimitWindows.Count -eq 2) 'both valid limit windows should be retained.'
    Assert-Widget ((@($state.PSObject.Properties.Name) -join ',') -eq 'LimitWindows') 'usage state should expose only limit windows.'
    Assert-Widget ($state.LimitWindows[0].Name -eq 'primary' -and $state.LimitWindows[0].UsedPercent -eq 23 -and $state.LimitWindows[0].RemainingPercent -eq 77 -and $state.LimitWindows[0].WindowMinutes -eq 10080) 'primary window should preserve validated values.'
    Assert-Widget ($state.LimitWindows[1].Name -eq 'secondary' -and $state.LimitWindows[1].UsedPercent -eq 61 -and $state.LimitWindows[1].RemainingPercent -eq 39 -and $state.LimitWindows[1].WindowMinutes -eq 300) 'secondary window should preserve validated values.'
    Assert-Widget ($state.LimitWindows[0].PSObject.Properties.Name -notcontains 'PlanType' -and $state.PSObject.Properties.Name -notcontains 'IsStale') 'legacy and stale fields should be absent.'

    $singleValid = ConvertTo-UsageState -Json "{`"primary`":{`"used_percent`":23,`"resets_at`":$future},`"secondary`":{`"used_percent`":-1,`"resets_at`":$future}}"
    Assert-Widget ($singleValid.LimitWindows.Count -eq 1 -and $singleValid.LimitWindows[0].Name -eq 'primary') 'one invalid window should not reject its valid sibling.'
    $missingMinutes = ConvertTo-UsageState -Json "{`"primary`":{`"used_percent`":23,`"resets_at`":$future}}"
    Assert-Widget ($missingMinutes.LimitWindows[0].PSObject.Properties.Name -notcontains 'WindowMinutes') 'window_minutes should be optional.'
    Assert-Widget ((Get-CurrentLimitState -State $missingMinutes -Now (Get-Date)).Name -eq 'primary') 'a valid window without window_minutes should remain selectable.'
    $pastState = ConvertTo-UsageState -Json '{"primary":{"used_percent":23,"resets_at":1}}'
    Assert-Widget ($pastState.LimitWindows.Count -eq 1) 'historical windows should remain valid event data.'

    $now = Get-Date
    $primaryWindow = [pscustomobject]@{ Name = 'primary'; UsedPercent = 40; RemainingPercent = 60; ResetAt = $now.AddHours(2) }
    $secondaryWindow = [pscustomobject]@{ Name = 'secondary'; UsedPercent = 70; RemainingPercent = 30; ResetAt = $now.AddHours(1) }
    Assert-Widget ((Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($primaryWindow) }) $now).Name -eq 'primary') 'primary-only state should select primary.'
    Assert-Widget ((Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($secondaryWindow) }) $now).Name -eq 'secondary') 'secondary-only state should select secondary.'
    Assert-Widget ((Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($primaryWindow, $secondaryWindow) }) $now).Name -eq 'secondary') 'the tighter remaining limit should win.'
    $secondaryWindow.RemainingPercent = 60
    Assert-Widget ((Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($secondaryWindow, $primaryWindow) }) $now).Name -eq 'primary') 'equal limits should prefer primary regardless of input order.'
    $secondaryWindow.RemainingPercent = 30
    Assert-Widget ((Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($primaryWindow, $secondaryWindow) }) $now.AddHours(1.5)).Name -eq 'primary') 'an expired secondary should fall back to primary.'
    Assert-Widget ($null -eq (Get-CurrentLimitState ([pscustomobject]@{ LimitWindows = @($primaryWindow, $secondaryWindow) }) $now.AddHours(3))) 'all expired windows should return null.'

    Assert-Widget ($null -eq (Get-TokenNumber $null 'value')) 'null token values should be rejected.'
    Assert-Widget ($null -eq (Get-TokenNumber ([pscustomobject]@{ value = $true }) 'value')) 'boolean token values should be rejected.'
    Assert-Widget ($null -eq (Get-TokenNumber ([pscustomobject]@{ value = '1' }) 'value')) 'non-numeric token values should be rejected.'
    Assert-Widget ($null -eq (Get-TokenNumber ([pscustomobject]@{ value = [double]::NaN }) 'value') -and $null -eq (Get-TokenNumber ([pscustomobject]@{ value = [double]::PositiveInfinity }) 'value') -and $null -eq (Get-TokenNumber ([pscustomobject]@{ value = -1 }) 'value')) 'non-finite and negative token values should be rejected.'
    Assert-Widget ((Get-TokenNumber ([pscustomobject]@{ value = 0 }) 'value') -eq 0 -and (Get-TokenNumber ([pscustomobject]@{ value = [long]::MaxValue }) 'value') -eq [long]::MaxValue) 'signed 64-bit token values should be accepted exactly.'
    Assert-Widget ($null -eq (Get-TokenNumber ([pscustomobject]@{ value = 12.5 }) 'value') -and $null -eq (Get-TokenNumber ([pscustomobject]@{ value = [decimal]::MaxValue }) 'value')) 'fractional and overflowing token values should be rejected.'
    Assert-Widget ($null -eq (Get-TokenPercent $null 10) -and $null -eq (Get-TokenPercent 1 0)) 'token percentages need a value and positive denominator.'
    Assert-Widget ($null -eq (Get-TokenPercent -1 10) -and $null -eq (Get-TokenPercent ([double]::NaN) 10)) 'token percentages should reject negative and non-finite numerators.'
    Assert-Widget ($null -eq (Get-TokenPercent 1 -10) -and $null -eq (Get-TokenPercent 1 ([double]::PositiveInfinity))) 'token percentages should reject negative and non-finite denominators.'
    Assert-Widget ((Get-TokenPercent ([long]::MaxValue - 1) ([long]::MaxValue)) -eq 100.0) 'token percentages should divide before multiplying and round without overflowing.'
    Assert-Widget ((Get-TokenPercent 1 3) -eq 33.3 -and (Get-TokenPercent 200 100) -eq 100) 'token percentages should round and clamp.'

    $tokenDetails = Get-EventTokenDetails $fixtureEvent
    Assert-Widget ($tokenDetails.CacheHitTokens -eq 19916800) 'cumulative cached input should become cache-hit tokens.'
    Assert-Widget ($tokenDetails.CacheMissTokens -eq 709300) 'uncached cumulative input should become cache-miss tokens.'
    Assert-Widget ($tokenDetails.CacheHitPercent -eq 96.6 -and $tokenDetails.CacheMissPercent -eq 3.4) 'cache ratios should be complementary and rounded.'
    Assert-Widget ((Format-TokenCount 161225728) -eq '1.61 亿') 'hundred-million token values should use compact Chinese formatting.'
    Assert-Widget ((Format-TokenCount 4252025) -eq '425.2 万') 'sub-ten-million token values should retain one decimal place.'

    $zeroCacheEvent = $fixtureEvent | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $zeroCacheEvent.payload.info.total_token_usage.input_tokens = 0
    $zeroCacheEvent.payload.info.total_token_usage.cached_input_tokens = 0
    $zeroCache = Get-EventTokenDetails $zeroCacheEvent
    Assert-Widget ($zeroCache.CacheHitTokens -eq 0 -and $zeroCache.CacheMissTokens -eq 0 -and
        $null -eq $zeroCache.CacheHitPercent -and $null -eq $zeroCache.CacheMissPercent) 'zero input should preserve counts without inventing ratios.'

    $invalidCacheEvent = $fixtureEvent | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $invalidCacheEvent.payload.info.total_token_usage.cached_input_tokens = 20626101
    $invalidCache = Get-EventTokenDetails $invalidCacheEvent
    Assert-Widget ($null -ne $invalidCache) 'cached input above total input should not discard other token details.'
    Assert-Widget ($invalidCache.CumulativeTokens -eq 40860000) 'cached input above total input should preserve the cumulative total.'
    Assert-Widget ($null -eq $invalidCache.CacheHitTokens -and $null -eq $invalidCache.CacheMissTokens -and
        $null -eq $invalidCache.CacheHitPercent -and $null -eq $invalidCache.CacheMissPercent) 'cached input above total input should hide the complete cache statistic.'

    $missingCacheEvent = $fixtureEvent | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $missingCacheEvent.payload.info.total_token_usage.PSObject.Properties.Remove('cached_input_tokens')
    $missingCache = Get-EventTokenDetails $missingCacheEvent
    Assert-Widget ($null -ne $missingCache) 'missing cumulative cached input should not discard other token details.'
    Assert-Widget ($missingCache.CumulativeTokens -eq 40860000) 'missing cumulative cached input should preserve the cumulative total.'
    Assert-Widget ($null -eq $missingCache.CacheHitTokens -and $null -eq $missingCache.CacheMissTokens -and
        $null -eq $missingCache.CacheHitPercent -and $null -eq $missingCache.CacheMissPercent) 'missing cumulative cached input should hide the complete cache statistic.'

    $missingInputEvent = $fixtureEvent | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $missingInputEvent.payload.info.total_token_usage.PSObject.Properties.Remove('input_tokens')
    $missingInput = Get-EventTokenDetails $missingInputEvent
    Assert-Widget ($null -ne $missingInput) 'missing cumulative input should not discard other token details.'
    Assert-Widget ($missingInput.CumulativeTokens -eq 40860000) 'missing cumulative input should preserve the cumulative total.'
    Assert-Widget ($null -eq $missingInput.CacheHitTokens -and $null -eq $missingInput.CacheMissTokens -and
        $null -eq $missingInput.CacheHitPercent -and $null -eq $missingInput.CacheMissPercent) 'missing cumulative input should hide the complete cache statistic.'

    Assert-Widget ($tokenDetails.CumulativeTokens -eq 40860000 -and $tokenDetails.ContextTokens -eq 206411 -and $tokenDetails.ContextLimit -eq 258400) 'fixture token totals should be preserved.'
    Assert-Widget ($tokenDetails.ContextPercent -eq 79.9 -and $tokenDetails.InputPercent -eq 99.9 -and $tokenDetails.OutputPercent -eq 0.1 -and $tokenDetails.ReasoningOutputPercent -eq 42.7) 'fixture token percentages should be derived and rounded.'
    $tokenPresentation = Get-TokenDetailPresentation $tokenDetails
    Assert-Widget $tokenPresentation.AnyVisible 'complete token details should show the token section.'
    Assert-Widget ($tokenPresentation.CumulativeVisible -and $tokenPresentation.CumulativeText -eq '累计令牌　4086 万') 'the cumulative token row should use Chinese compact formatting.'
    Assert-Widget ($tokenPresentation.ContextVisible -and $tokenPresentation.ContextText -eq '上下文　20.6 万 / 25.8 万') 'the context row should show current and limit token counts.'
    Assert-Widget ($tokenPresentation.ContextPercentVisible -and $tokenPresentation.ContextBarVisible -and
        $tokenPresentation.ContextPercentText -eq '上下文占用　79.9%' -and $tokenPresentation.ContextPercent -eq 79.9) 'the context percentage and bar should share one presentation value.'
    Assert-Widget ($tokenPresentation.CompositionVisible -and $tokenPresentation.CompositionBarVisible -and
        $tokenPresentation.CompositionText -eq '输入 / 输出构成　输入 99.9%　输出 0.1%' -and
        $tokenPresentation.InputPercent -eq 99.9 -and $tokenPresentation.OutputPercent -eq 0.1) 'the input and output composition should be fully presented.'
    $expectedCacheText = "本机累计缓存命中令牌　1992 万（96.6%）`n本机累计缓存未命中令牌　70.9 万（3.4%）"
    Assert-Widget ($tokenPresentation.CachedVisible -and
        $tokenPresentation.CachedText -ceq $expectedCacheText) 'cumulative cache-hit and cache-miss tokens should share one two-line presentation.'

    $zeroCachePresentation = Get-TokenDetailPresentation ([pscustomobject]@{
        CacheHitTokens = 0
        CacheMissTokens = 0
        CacheHitPercent = $null
        CacheMissPercent = $null
    })
    Assert-Widget ($zeroCachePresentation.CachedVisible -and
        $zeroCachePresentation.CachedText -ceq "本机累计缓存命中令牌　0（—）`n本机累计缓存未命中令牌　0（—）") 'zero input should show counts and suppress ratios.'

    $largeCachePresentation = Get-TokenDetailPresentation ([pscustomobject]@{
        CacheHitTokens = 161225728
        CacheMissTokens = 4252025
        CacheHitPercent = 97.4
        CacheMissPercent = 2.6
    })
    Assert-Widget ($largeCachePresentation.CachedText -ceq "本机累计缓存命中令牌　1.61 亿（97.4%）`n本机累计缓存未命中令牌　425.2 万（2.6%）") 'large cumulative cache values should match the approved Chinese display.'
    Assert-Widget ($tokenPresentation.ReasoningVisible -and $tokenPresentation.ReasoningText -eq '输出中推理占比　42.7%') 'the reasoning-output ratio should be presented.'

    $emptyTokenPresentation = Get-TokenDetailPresentation $null
    Assert-Widget (-not $emptyTokenPresentation.AnyVisible) 'missing token details should collapse the complete token section.'
    foreach ($visibilityName in 'CumulativeVisible', 'ContextVisible', 'ContextPercentVisible', 'ContextBarVisible',
        'CompositionVisible', 'CompositionBarVisible', 'CachedVisible', 'ReasoningVisible') {
        Assert-Widget (-not $emptyTokenPresentation.$visibilityName) 'missing token details should collapse every token element.'
    }
    $partialTokenPresentation = Get-TokenDetailPresentation ([pscustomobject]@{
        CumulativeTokens = 40860000
        ContextTokens = 206411
    })
    Assert-Widget $partialTokenPresentation.AnyVisible 'one real token value should show the token section.'
    Assert-Widget ($partialTokenPresentation.CumulativeVisible -and $partialTokenPresentation.CumulativeText -eq '累计令牌　4086 万') 'an independently available cumulative value should remain visible.'
    foreach ($visibilityName in 'ContextVisible', 'ContextPercentVisible', 'ContextBarVisible',
        'CompositionVisible', 'CompositionBarVisible', 'CachedVisible', 'ReasoningVisible') {
        Assert-Widget (-not $partialTokenPresentation.$visibilityName) 'partial token details should collapse only unavailable elements.'
    }
    $badTokenEvent = $fixtureEvent | ConvertTo-Json -Depth 10 | ConvertFrom-Json
    $badTokenEvent.payload.info.last_token_usage.reasoning_output_tokens = 200
    Assert-Widget ($null -eq (Get-EventTokenDetails $badTokenEvent).ReasoningOutputPercent) 'reasoning output greater than output should hide only that ratio.'
    Assert-Widget ($null -eq (Get-EventTokenDetails ([pscustomobject]@{ payload = [pscustomobject]@{ info = [pscustomobject]@{} } }))) 'an event without token fields should return null.'

    $older = [pscustomobject]@{ timestamp = [DateTimeOffset]::UtcNow.AddMinutes(-2).ToString('o'); payload = [pscustomobject]@{ info = $fixtureEvent.payload.info; rate_limits = ($valid | ConvertFrom-Json) } }
    $newerLimits = $valid | ConvertFrom-Json
    $newerLimits.secondary.used_percent = 42
    $newer = [pscustomobject]@{ timestamp = [DateTimeOffset]::UtcNow.AddSeconds(-10).ToString('o'); payload = [pscustomobject]@{ info = $fixtureEvent.payload.info; rate_limits = $newerLimits } }
    $newest = Get-NewestUsageState -Events @($older, $newer)
    Assert-Widget ($newest.LimitWindows[1].UsedPercent -eq 42 -and $newest.ObservedAt -gt $older.timestamp -and $null -ne $newest.TokenDetails) 'newest valid rate-limit event should attach observation and token details.'
    Assert-Widget ($newest.PSObject.Properties.Name -notcontains 'IsStale') 'newest state should not expose stale state.'

    $deep = [pscustomobject]@{}
    $node = $deep
    1..1000 | ForEach-Object { $next = [pscustomobject]@{}; $node | Add-Member -NotePropertyName child -NotePropertyValue $next; $node = $next }
    $node | Add-Member -NotePropertyName rate_limits -NotePropertyValue ($valid | ConvertFrom-Json)
    Assert-Widget ($null -eq (Get-EventRateLimits $deep)) 'rate-limit traversal should stop after 1000 objects.'

    $savedProfile = $env:USERPROFILE
    $savedCodexHome = $env:CODEX_HOME
    $savedSessionTestLocalAppData = $env:LOCALAPPDATA
    $testProfile = Join-Path ([System.IO.Path]::GetTempPath()) ('CodexUsageWidget-' + [guid]::NewGuid())
    try {
        $env:LOCALAPPDATA = Join-Path $testProfile 'local'
        $env:CODEX_HOME = $null
        $script:CacheTokenLedger = $null
        $sessionDirectory = Join-Path $testProfile '.codex\sessions'
        [System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
        $manualRoot = Join-Path $testProfile 'manual-codex'
        $customRoot = Join-Path $testProfile 'custom-codex'
        $profileRoot = Join-Path $testProfile 'profile-probe'
        $defaultRoot = Join-Path $profileRoot '.codex'
        foreach ($root in $manualRoot, $customRoot, $defaultRoot) {
            [System.IO.Directory]::CreateDirectory((Join-Path $root 'sessions')) | Out-Null
        }
        Assert-Widget ((Resolve-CodexDataDirectory $manualRoot $customRoot $profileRoot) -eq $manualRoot) 'a saved manual directory should win.'
        [System.IO.Directory]::Delete((Join-Path $manualRoot 'sessions'))
        Assert-Widget ((Resolve-CodexDataDirectory $manualRoot $customRoot $profileRoot) -eq $customRoot) 'an invalid saved directory should fall back to CODEX_HOME.'
        [System.IO.Directory]::Delete((Join-Path $customRoot 'sessions'))
        Assert-Widget ((Resolve-CodexDataDirectory $manualRoot $null $profileRoot) -eq $defaultRoot) 'an unset CODEX_HOME should use the current profile.'
        [System.IO.Directory]::Delete((Join-Path $defaultRoot 'sessions'))
        Assert-Widget ($null -eq (Resolve-CodexDataDirectory $manualRoot $customRoot $profileRoot)) 'missing candidates should require manual selection.'
        $activityNow = [datetime]'2026-07-31T12:00:00Z'
        $activityIndex = Join-Path $testProfile '.codex\session_index.jsonl'
        [System.IO.File]::WriteAllLines($activityIndex, @(
            '{"id":"11111111-1111-1111-1111-111111111111","thread_name":"旧名称","updated_at":"2026-07-31T11:00:00Z"}',
            '{"id":"11111111-1111-1111-1111-111111111111","thread_name":"任务一","updated_at":"2026-07-31T11:59:00Z"}',
            '{"id":"22222222-2222-2222-2222-222222222222","thread_name":"任务二","updated_at":"2026-07-31T11:58:00Z"}',
            '{bad json'
        ))
        $taskNames = Read-TaskNameIndex $activityIndex
        Assert-Widget ($taskNames['11111111-1111-1111-1111-111111111111'] -ceq '任务一') 'the latest valid task name should win.'
        Assert-Widget ($taskNames['22222222-2222-2222-2222-222222222222'] -ceq '任务二') 'a second valid task name should be loaded.'

        $candidateFiles = @(
            [pscustomobject]@{
                BaseName = 'rollout-11111111-1111-1111-1111-111111111111'
                FullName = 'newer-a.jsonl'
                LastWriteTimeUtc = $activityNow.AddMinutes(-1)
            },
            [pscustomobject]@{
                BaseName = 'rollout-11111111-1111-1111-1111-111111111111'
                FullName = 'older-a.jsonl'
                LastWriteTimeUtc = $activityNow.AddMinutes(-5)
            },
            [pscustomobject]@{
                BaseName = 'rollout-22222222-2222-2222-2222-222222222222'
                FullName = 'boundary-b.jsonl'
                LastWriteTimeUtc = $activityNow.AddMinutes(-30)
            },
            [pscustomobject]@{
                BaseName = 'rollout-33333333-3333-3333-3333-333333333333'
                FullName = 'unindexed.jsonl'
                LastWriteTimeUtc = $activityNow.AddMinutes(-2)
            },
            [pscustomobject]@{
                BaseName = 'rollout-22222222-2222-2222-2222-222222222222'
                FullName = 'expired-b.jsonl'
                LastWriteTimeUtc = $activityNow.AddMinutes(-30).AddMilliseconds(-1)
            }
        )
        $candidates = @(Get-ActiveTaskCandidates -Files $candidateFiles -Names $taskNames -Now $activityNow)
        Assert-Widget ($candidates.Count -eq 2) 'only named tasks updated within 30 minutes should remain.'
        Assert-Widget ($candidates[0].Id -eq '11111111-1111-1111-1111-111111111111' -and
            $candidates[0].Name -ceq '任务一' -and $candidates[0].FullName -eq 'newer-a.jsonl') 'newer duplicate tasks should win and sort first.'
        Assert-Widget ($candidates[1].Id -eq '22222222-2222-2222-2222-222222222222') 'the exact 30-minute boundary should remain active.'

        $eventLine = "{`"timestamp`":`"$([DateTimeOffset]::UtcNow.ToString('o'))`",`"payload`":{`"info`":$($fixtureEvent.payload.info | ConvertTo-Json -Depth 10 -Compress),`"rate_limits`":$valid}}"
        $fallbackFile = Join-Path $sessionDirectory 'fallback.jsonl'
        [System.IO.File]::WriteAllText($fallbackFile, ('x' * 300000) + "`n" + $eventLine + "`n" + ('x' * 300000))
        $env:USERPROFILE = $testProfile
        $fallback = Get-CodexUsageState
        Assert-Widget ($fallback.LimitWindows[0].UsedPercent -eq 23) 'a truncated tail without a valid event should use the bounded fallback.'

        $baseCycle = [DateTimeOffset]::UtcNow.AddDays(7).ToUnixTimeSeconds()
        $baseLimits = $valid | ConvertFrom-Json
        $baseLimits | Add-Member -NotePropertyName limit_id -NotePropertyValue 'codex'
        $baseLimits.primary.used_percent = 2
        $baseLimits.primary.resets_at = $baseCycle
        $baseLimits.secondary = $null
        $baseEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(10).ToString('o')
            payload = [pscustomobject]@{ rate_limits = $baseLimits }
        }
        $baseFile = Join-Path $sessionDirectory 'base-limit.jsonl'
        [System.IO.File]::WriteAllText($baseFile, ($baseEvent | ConvertTo-Json -Depth 10 -Compress))

        $individualLimits = $baseLimits | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $individualLimits.limit_id = 'codex_bengalfox'
        $individualLimits | Add-Member -NotePropertyName limit_name -NotePropertyValue 'GPT-5.3-Codex-Spark'
        $individualLimits.primary.used_percent = 0
        $individualLimits.primary.resets_at = [DateTimeOffset]::UtcNow.AddDays(8).ToUnixTimeSeconds()
        $individualEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(11).ToString('o')
            payload = [pscustomobject]@{ rate_limits = $individualLimits }
        }
        $individualFile = Join-Path $sessionDirectory 'individual-limit.jsonl'
        [System.IO.File]::WriteAllText($individualFile, ($individualEvent | ConvertTo-Json -Depth 10 -Compress))
        $baseUsage = Get-CodexUsageState
        Assert-Widget ($baseUsage.LimitWindows[0].UsedPercent -eq 2) 'the main gauge should ignore newer model-specific rate-limit pools.'

        $staleLimits = $baseLimits | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $staleLimits.primary.used_percent = 0
        $staleEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(12).ToString('o')
            payload = [pscustomobject]@{ rate_limits = $staleLimits }
        }
        $staleFile = Join-Path $sessionDirectory 'stale-base-limit.jsonl'
        [System.IO.File]::WriteAllText($staleFile, ($staleEvent | ConvertTo-Json -Depth 10 -Compress))
        $stableUsage = Get-CodexUsageState
        Assert-Widget ($stableUsage.LimitWindows[0].UsedPercent -eq 2) 'a later stale snapshot must not make usage fall within one limit cycle.'

        $nextLimits = $baseLimits | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $nextLimits.primary.used_percent = 1
        $nextLimits.primary.resets_at = $baseCycle + 86400
        $nextEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(13).ToString('o')
            payload = [pscustomobject]@{ rate_limits = $nextLimits }
        }
        $nextFile = Join-Path $sessionDirectory 'next-base-limit.jsonl'
        [System.IO.File]::WriteAllText($nextFile, ($nextEvent | ConvertTo-Json -Depth 10 -Compress))

        $lateOldLimits = $baseLimits | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $lateOldLimits.primary.used_percent = 50
        $lateOldEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(14).ToString('o')
            payload = [pscustomobject]@{ rate_limits = $lateOldLimits }
        }
        $lateOldFile = Join-Path $sessionDirectory 'late-old-base-limit.jsonl'
        [System.IO.File]::WriteAllText($lateOldFile, ($lateOldEvent | ConvertTo-Json -Depth 10 -Compress))
        $currentCycleUsage = Get-CodexUsageState
        Assert-Widget ($currentCycleUsage.LimitWindows[0].UsedPercent -eq 1) 'a late event from an older cycle must not replace the newer limit cycle.'
        [System.IO.File]::Delete($baseFile)
        [System.IO.File]::Delete($individualFile)
        [System.IO.File]::Delete($staleFile)
        [System.IO.File]::Delete($nextFile)
        [System.IO.File]::Delete($lateOldFile)

        $otherInfo = $fixtureEvent.payload.info | ConvertTo-Json -Depth 10 | ConvertFrom-Json
        $otherInfo.total_token_usage.input_tokens = 1100
        $otherInfo.total_token_usage.cached_input_tokens = 1000
        $otherFile = Join-Path $sessionDirectory 'other-session.jsonl'
        $otherEvent = [pscustomobject]@{
            timestamp = [DateTimeOffset]::UtcNow.AddSeconds(1).ToString('o')
            payload = [pscustomobject]@{ info = $otherInfo; rate_limits = ($valid | ConvertFrom-Json) }
        }
        [System.IO.File]::WriteAllText($otherFile, ($otherEvent | ConvertTo-Json -Depth 10 -Compress))
        $aggregate = Get-CodexUsageState
        Assert-Widget ($aggregate.TokenDetails.CacheHitTokens -eq 19917800 -and
            $aggregate.TokenDetails.CacheMissTokens -eq 709400) 'different session snapshots should be added instead of replacing each other.'
        $otherInfo.total_token_usage.input_tokens = 990
        $otherInfo.total_token_usage.cached_input_tokens = 900
        $otherEvent.timestamp = [DateTimeOffset]::UtcNow.AddSeconds(2).ToString('o')
        [System.IO.File]::WriteAllText($otherFile, ($otherEvent | ConvertTo-Json -Depth 10 -Compress))
        $aggregate = Get-CodexUsageState
        Assert-Widget ($aggregate.TokenDetails.CacheHitTokens -eq 19917800 -and
            $aggregate.TokenDetails.CacheMissTokens -eq 709400) 'a lower session snapshot should not make the displayed totals fall.'
        [System.IO.File]::Delete($otherFile)

        $activeA = Join-Path $sessionDirectory 'rollout-11111111-1111-1111-1111-111111111111.jsonl'
        $activeB = Join-Path $sessionDirectory 'rollout-22222222-2222-2222-2222-222222222222.jsonl'
        [System.IO.File]::WriteAllText($activeA, $eventLine)
        $otherInfo.total_token_usage.input_tokens = 1100
        $otherInfo.total_token_usage.cached_input_tokens = 1000
        $otherEvent.timestamp = [DateTimeOffset]::UtcNow.AddSeconds(3).ToString('o')
        [System.IO.File]::WriteAllText($activeB, ($otherEvent | ConvertTo-Json -Depth 10 -Compress))
        $activeState = Get-CodexUsageState
        Assert-Widget (@($activeState.ActiveTasks).Count -eq 2) 'two named active tasks should be attached.'
        $activeTaskB = @($activeState.ActiveTasks | Where-Object Id -eq '22222222-2222-2222-2222-222222222222')[0]
        Assert-Widget ($activeTaskB.Name -ceq '任务二' -and $activeTaskB.TokenDetails.CacheHitTokens -eq 1000 -and
            $activeTaskB.TokenDetails.CacheMissTokens -eq 100) 'active task details must retain the task snapshot.'
        Assert-Widget ($activeState.TokenDetails.CacheHitTokens -gt $activeTaskB.TokenDetails.CacheHitTokens) 'global cumulative cache totals must remain separate.'
        [System.IO.File]::Delete($activeA)
        [System.IO.File]::Delete($activeB)
        [System.IO.File]::Delete($activityIndex)

        [System.IO.File]::WriteAllText($fallbackFile, $eventLine + "`n" + ('x' * 1048577))
        Assert-Widget ($null -eq (Get-CodexUsageState)) 'events beyond the bounded fallback should remain unavailable.'
        Assert-Widget ((Get-CodexUsageDiagnostic) -eq 'no_valid_event') 'files without a bounded valid event should use a safe internal code.'

        $readFailed = $false
        Assert-Widget ((Read-SessionEvents -Path (Join-Path $sessionDirectory 'missing.jsonl') -ReadFailed ([ref]$readFailed)).Count -eq 0 -and $readFailed) 'read failure should set only the boolean ref flag.'

        [System.IO.File]::Delete($fallbackFile)
        Assert-Widget ($null -eq (Get-CodexUsageState) -and (Get-CodexUsageDiagnostic) -eq 'empty_directory') 'an empty sessions directory should be distinguished.'
        [System.IO.Directory]::Delete($sessionDirectory)
        Assert-Widget ($null -eq (Get-CodexUsageState) -and (Get-CodexUsageDiagnostic) -eq 'missing_directory') 'a missing sessions directory should be distinguished.'

        [System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
        [System.IO.File]::WriteAllText($fallbackFile, '{bad json')
        Assert-Widget ($null -eq (Get-CodexUsageState) -and (Get-CodexUsageDiagnostic) -eq 'no_valid_event') 'invalid events should be distinguished from read failures.'
        [System.IO.File]::WriteAllText($fallbackFile, $eventLine)
        $snapshot = Get-CodexUsageSnapshot
        Assert-Widget ($null -ne $snapshot.State -and $null -eq $snapshot.Diagnostic) 'a valid snapshot should include state and clear diagnostics.'

        $refreshFailure = Resolve-UsageRefreshResult -Snapshot $snapshot -ErrorCount 1
        Assert-Widget ($null -eq $refreshFailure.State -and $refreshFailure.Diagnostic -eq 'read_failed') 'a non-terminating worker error should reject an otherwise valid snapshot.'
        $malformedRefresh = Resolve-UsageRefreshResult -Snapshot ([pscustomobject]@{ Value = 1 }) -ErrorCount 0
        Assert-Widget ($null -eq $malformedRefresh.State -and $malformedRefresh.Diagnostic -eq 'read_failed') 'a malformed worker result should become a safe read failure.'
        $validRefresh = Resolve-UsageRefreshResult -Snapshot $snapshot -ErrorCount 0
        Assert-Widget ($validRefresh.State -eq $snapshot.State -and $null -eq $validRefresh.Diagnostic) 'a valid state with no diagnostic should be preserved.'
        foreach ($diagnostic in 'missing_directory', 'empty_directory', 'read_failed', 'no_valid_event') {
            $diagnosticRefresh = Resolve-UsageRefreshResult -Snapshot ([pscustomobject]@{ State = $null; Diagnostic = $diagnostic }) -ErrorCount 0
            Assert-Widget ($null -eq $diagnosticRefresh.State -and $diagnosticRefresh.Diagnostic -eq $diagnostic) 'a safe null-state diagnostic should be preserved.'
        }

        $workerNames = @(Get-UsageWorkerFunctionNames)
        Assert-Widget ($workerNames -contains 'ConvertTo-LimitWindow' -and $workerNames -contains 'Get-TokenPercent' -and $workerNames -contains 'Get-CodexUsageSnapshot') 'the worker list should contain the complete data pipeline.'
        $incompleteState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($functionName in @($workerNames | Where-Object { $_ -ne 'Get-CodexUsageState' })) {
            $definition = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).Definition
            $incompleteState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($functionName, $definition))
        }
        $incompleteRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($incompleteState)
        $incompleteRunspace.Open()
        $incompleteWorker = [System.Management.Automation.PowerShell]::Create()
        $incompleteWorker.Runspace = $incompleteRunspace
        try {
            [void]$incompleteWorker.AddCommand('Get-CodexUsageSnapshot')
            [void]$incompleteWorker.Invoke()
            Assert-Widget ($incompleteWorker.HadErrors) 'omitting a real worker dependency should make the invocation fail.'
        }
        finally {
            $incompleteWorker.Dispose()
            $incompleteRunspace.Dispose()
        }

        $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
        foreach ($functionName in $workerNames) {
            $definition = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).Definition
            $initialState.Commands.Add([System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($functionName, $definition))
        }
        $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
        $runspace.Open()
        $worker = [System.Management.Automation.PowerShell]::Create()
        $worker.Runspace = $runspace
        try {
            [void]$worker.AddCommand('Get-CodexUsageSnapshot')
            $workerSnapshot = @($worker.Invoke())[-1]
            Assert-Widget (-not $worker.HadErrors -and $worker.Streams.Error.Count -eq 0 -and $null -ne $workerSnapshot.State -and $null -eq $workerSnapshot.Diagnostic) 'restoring the production worker list should execute a valid snapshot without command errors.'

            [System.IO.File]::Delete($fallbackFile)
            $worker.Commands.Clear()
            $worker.Streams.Error.Clear()
            [void]$worker.AddCommand('Get-CodexUsageSnapshot')
            $emptySnapshot = @($worker.Invoke())[-1]
            Assert-Widget (-not $worker.HadErrors -and $worker.Streams.Error.Count -eq 0 -and $null -eq $emptySnapshot.State -and $emptySnapshot.Diagnostic -eq 'empty_directory') 'the worker snapshot should distinguish an empty directory.'

            [System.IO.Directory]::Delete($sessionDirectory)
            $worker.Commands.Clear()
            $worker.Streams.Error.Clear()
            [void]$worker.AddCommand('Get-CodexUsageSnapshot')
            $missingSnapshot = @($worker.Invoke())[-1]
            Assert-Widget (-not $worker.HadErrors -and $worker.Streams.Error.Count -eq 0 -and $null -eq $missingSnapshot.State -and $missingSnapshot.Diagnostic -eq 'missing_directory') 'the worker snapshot should distinguish a missing directory.'

            [System.IO.Directory]::CreateDirectory($sessionDirectory) | Out-Null
            [System.IO.File]::WriteAllText($fallbackFile, '{bad json')
            $worker.Commands.Clear()
            $worker.Streams.Error.Clear()
            [void]$worker.AddCommand('Get-CodexUsageSnapshot')
            $invalidSnapshot = @($worker.Invoke())[-1]
            Assert-Widget (-not $worker.HadErrors -and $worker.Streams.Error.Count -eq 0 -and $null -eq $invalidSnapshot.State -and $invalidSnapshot.Diagnostic -eq 'no_valid_event') 'the worker snapshot should distinguish invalid events.'

            [System.IO.File]::WriteAllText($fallbackFile, $eventLine)
            $lockedSession = [System.IO.File]::Open($fallbackFile, 'Open', 'Read', 'None')
            try {
                $worker.Commands.Clear()
                $worker.Streams.Error.Clear()
                [void]$worker.AddCommand('Get-CodexUsageSnapshot')
                $failedSnapshot = @($worker.Invoke())[-1]
                Assert-Widget (-not $worker.HadErrors -and $worker.Streams.Error.Count -eq 0 -and $null -eq $failedSnapshot.State -and $failedSnapshot.Diagnostic -eq 'read_failed') 'the worker snapshot should distinguish a session read failure.'
            }
            finally {
                $lockedSession.Dispose()
            }
        }
        finally {
            $worker.Dispose()
            $runspace.Dispose()
        }
    }
    finally {
        $env:USERPROFILE = $savedProfile
        $env:CODEX_HOME = $savedCodexHome
        $env:LOCALAPPDATA = $savedSessionTestLocalAppData
        $script:CacheTokenLedger = $null
        if ([System.IO.Directory]::Exists($testProfile)) { [System.IO.Directory]::Delete($testProfile, $true) }
    }

    $savedLocalAppData = $env:LOCALAPPDATA
    $testLocalAppData = Join-Path ([System.IO.Path]::GetTempPath()) ('CodexUsageWidget-' + [guid]::NewGuid())
    try {
        $env:LOCALAPPDATA = $testLocalAppData
        $script:CacheTokenLedger = $null
        $cacheTotals = Update-CumulativeCacheTokens @(
            [pscustomobject]@{ Id = 'session-a'; CacheHitTokens = 100; CacheMissTokens = 20 },
            [pscustomobject]@{ Id = 'session-b'; CacheHitTokens = 50; CacheMissTokens = 10 }
        )
        Assert-Widget ($cacheTotals.CacheHitTokens -eq 150 -and $cacheTotals.CacheMissTokens -eq 30) 'two sessions should be added once.'
        $cacheTotals = Update-CumulativeCacheTokens @(
            [pscustomobject]@{ Id = 'session-b'; CacheHitTokens = 80; CacheMissTokens = 15 },
            [pscustomobject]@{ Id = 'session-a'; CacheHitTokens = 100; CacheMissTokens = 20 }
        )
        Assert-Widget ($cacheTotals.CacheHitTokens -eq 180 -and $cacheTotals.CacheMissTokens -eq 35) 'switching active sessions should add only new tokens.'
        $cacheTotals = Update-CumulativeCacheTokens @(
            [pscustomobject]@{ Id = 'session-a'; CacheHitTokens = 110; CacheMissTokens = 22 },
            [pscustomobject]@{ Id = 'session-b'; CacheHitTokens = 70; CacheMissTokens = 14 }
        )
        Assert-Widget ($cacheTotals.CacheHitTokens -eq 190 -and $cacheTotals.CacheMissTokens -eq 37) 'lower snapshots must not reduce cumulative totals.'
        $script:CacheTokenLedger = $null
        $cacheTotals = Update-CumulativeCacheTokens @(
            [pscustomobject]@{ Id = 'session-a'; CacheHitTokens = 110; CacheMissTokens = 22 },
            [pscustomobject]@{ Id = 'session-b'; CacheHitTokens = 80; CacheMissTokens = 15 }
        )
        Assert-Widget ($cacheTotals.CacheHitTokens -eq 190 -and $cacheTotals.CacheMissTokens -eq 37) 'reloading the ledger must not count the same tokens twice.'

        $script:ReminderGateCache = $null
        $primaryCycleTime = [DateTimeOffset]::UtcNow.AddHours(1)
        $secondaryCycleTime = $primaryCycleTime.AddMinutes(30)
        $primaryReminder = [pscustomobject]@{ Name = 'primary'; RemainingPercent = 20; ResetAt = $primaryCycleTime }
        $secondaryReminder = [pscustomobject]@{ Name = 'secondary'; RemainingPercent = 20; ResetAt = $secondaryCycleTime }
        foreach ($reminder in $primaryReminder, $secondaryReminder) {
            Assert-Widget (Register-UsageReminderThreshold -State $reminder -Threshold 20) 'each window should trigger its 20 percent reminder once.'
            Assert-Widget (-not (Register-UsageReminderThreshold -State $reminder -Threshold 20)) 'each window should suppress its repeated 20 percent reminder.'
        }
        foreach ($reminder in $primaryReminder, $secondaryReminder) {
            $reminder.RemainingPercent = 10
            Assert-Widget (Register-UsageReminderThreshold -State $reminder -Threshold 10) 'each window should trigger its 10 percent reminder once.'
            Assert-Widget (-not (Register-UsageReminderThreshold -State $reminder -Threshold 10)) 'each window should suppress its repeated 10 percent reminder.'
        }
        Assert-Widget (-not (Register-UsageReminderThreshold -State $null -Threshold 20)) 'null state should not trigger.'
        Assert-Widget (-not (Register-UsageReminderThreshold -State ([pscustomobject]@{ Name = 'primary'; RemainingPercent = 21; ResetAt = $primaryCycleTime }) -Threshold 20)) 'a percentage above the threshold should not trigger.'
        Assert-Widget (-not (Register-UsageReminderThreshold -State ([pscustomobject]@{ Name = 'primary'; RemainingPercent = 20; ResetAt = [DateTimeOffset]::UtcNow.AddSeconds(-1) }) -Threshold 20)) ('an already re' + 'set window should not trigger.')
        Assert-Widget (-not (Register-UsageReminderThreshold -State ([pscustomobject]@{ Name = 'primary'; RemainingPercent = 20; ResetAt = [datetime]::MinValue }) -Threshold 20)) ('an unrepresentable local re' + 'set time should safely return false.')
        Assert-Widget (-not (Register-UsageReminderThreshold -State ([pscustomobject]@{ Name = 'Primary'; RemainingPercent = 20; ResetAt = $primaryCycleTime }) -Threshold 20)) 'window names should use the exact primary or secondary values.'
        $reminderPath = Join-Path $testLocalAppData 'CodexUsageWidget\reminders.json'
        $persisted = Get-Content -LiteralPath $reminderPath -Raw | ConvertFrom-Json
        Assert-Widget ((@($persisted.PSObject.Properties.Name) -join ',') -eq 'SentKeys') 'only SentKeys should be persisted.'
        Assert-Widget (@($persisted.SentKeys).Count -eq 4) 'both thresholds for both windows should survive persistence.'

        $oldJson = [System.IO.File]::ReadAllText($reminderPath)
        $lockedReminder = [System.IO.File]::Open($reminderPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            Assert-Widget (-not (Save-ReminderGateState ([pscustomobject]@{ SentKeys = @('primary|4102444800|10') }))) 'a locked reminder target should reject replacement.'
        }
        finally {
            $lockedReminder.Dispose()
        }
        Assert-Widget ([System.IO.File]::ReadAllText($reminderPath) -eq $oldJson) 'a failed atomic replacement should preserve the old reminder file.'
        Assert-Widget ([System.IO.Directory]::GetFiles((Split-Path $reminderPath), '*.tmp').Count -eq 0) 'a failed atomic replacement should clean up its temporary file.'
        Assert-Widget ([System.IO.Directory]::GetFiles((Split-Path $reminderPath), '*.bak').Count -eq 0) 'atomic replacement should not leave a backup file.'

        $primaryReminder.ResetAt = $primaryCycleTime.AddHours(1)
        $primaryReminder.RemainingPercent = 20
        Assert-Widget (Register-UsageReminderThreshold -State $primaryReminder -Threshold 20) 'a new primary cycle should reopen only the primary threshold.'
        Assert-Widget (-not (Register-UsageReminderThreshold -State $secondaryReminder -Threshold 10)) ('a primary re' + 'set should not reopen the secondary threshold.')
        $script:ReminderGateCache = $null
        Assert-Widget (-not (Register-UsageReminderThreshold -State $primaryReminder -Threshold 20)) 'new-cycle state should persist across a reload.'

        [System.IO.File]::WriteAllText($reminderPath, '{bad json')
        $script:ReminderGateCache = $null
        Assert-Widget (@((Get-ReminderGateState).SentKeys).Count -eq 0) 'damaged reminder JSON should load as an empty set.'
        [System.IO.File]::WriteAllText($reminderPath, '{"ResetKey":"4102444800","Sent":[10,20]}')
        $script:ReminderGateCache = $null
        Assert-Widget (@((Get-ReminderGateState).SentKeys).Count -eq 0) 'legacy reminder state should load as an empty set.'
        $futureKeyTime = [DateTimeOffset]::UtcNow.AddHours(3).ToUnixTimeSeconds()
        $expiredKeyTime = [DateTimeOffset]::UtcNow.AddHours(-3).ToUnixTimeSeconds()
        [System.IO.File]::WriteAllText($reminderPath, ([pscustomobject]@{ SentKeys = @(
            "primary|$futureKeyTime|20",
            "primary|$futureKeyTime|20",
            "secondary|$futureKeyTime|10",
            "primary|$expiredKeyTime|10",
            "other|$futureKeyTime|10",
            "primary|1.5|10",
            "primary|$futureKeyTime|30",
            'broken'
        ) } | ConvertTo-Json -Compress))
        $script:ReminderGateCache = $null
        $cleanedReminderState = Get-ReminderGateState
        Assert-Widget ((@($cleanedReminderState.SentKeys | Sort-Object) -join ',') -eq "primary|$futureKeyTime|20,secondary|$futureKeyTime|10") 'expired, duplicate, and malformed reminder keys should be discarded.'

        $blockedLocalAppData = Join-Path $testLocalAppData 'blocked'
        [System.IO.File]::WriteAllText($blockedLocalAppData, '')
        $env:LOCALAPPDATA = $blockedLocalAppData
        $script:ReminderGateCache = $null
        $primaryReminder.ResetAt = $primaryCycleTime.AddHours(4)
        Assert-Widget (Register-UsageReminderThreshold -State $primaryReminder -Threshold 20) 'persistence failure should still allow an in-memory trigger.'
        Assert-Widget (-not (Register-UsageReminderThreshold -State $primaryReminder -Threshold 20)) 'persistence failure should still suppress in-memory repeats.'

        $env:LOCALAPPDATA = $testLocalAppData
        $preferenceCodexRoot = Join-Path $testLocalAppData 'chosen-codex'
        [System.IO.Directory]::CreateDirectory((Join-Path $preferenceCodexRoot 'sessions')) | Out-Null
        Assert-Widget (Save-WidgetPreferences -Left (-640.5) -Top 120.25 -Monitor '\\.\DISPLAY2' -Theme 3 -CodexDataDirectory $preferenceCodexRoot -Language 'ja-JP') 'valid preferences should save.'
        $preferences = Get-WidgetPreferences
        Assert-Widget ($preferences.Left -eq -640.5 -and $preferences.Top -eq 120.25 -and $preferences.Monitor -eq '\\.\DISPLAY2' -and
            $preferences.Theme -eq 3 -and $preferences.CodexDataDirectory -eq $preferenceCodexRoot -and
            $preferences.Language -ceq 'ja-JP') 'saved preferences should round-trip, including the Codex data directory and language.'
        $preferencesPath = Join-Path $testLocalAppData 'CodexUsageWidget\preferences.json'
        $storedPreferences = [System.IO.File]::ReadAllText($preferencesPath) | ConvertFrom-Json
        Assert-Widget ((@($storedPreferences.PSObject.Properties.Name | Sort-Object) -join ',') -eq 'CodexDataDirectory,Language,Left,Monitor,Theme,Top') 'preferences should persist only the six whitelisted properties.'

        $fallbackLocaleRoot = Join-Path $testLocalAppData 'fallback-locale-root'
        $fallbackLocales = Join-Path $fallbackLocaleRoot 'locales'
        [void][System.IO.Directory]::CreateDirectory($fallbackLocales)
        [System.IO.File]::Copy((Join-Path $PSScriptRoot 'locales\en-US.json'), (Join-Path $fallbackLocales 'en-US.json'))
        $fallbackPreferences = Get-WidgetPreferences
        Initialize-WidgetLocalization $fallbackLocaleRoot $fallbackPreferences.Language ([cultureinfo]'ja-JP')
        Assert-Widget ($script:CurrentLanguageCode -ceq 'en-US' -and $fallbackPreferences.Language -ceq 'ja-JP') 'an unavailable saved optional language should activate English without changing the in-memory preference.'
        if ($null -eq $fallbackPreferences.Language) { $fallbackPreferences.Language = $script:CurrentLanguageCode }
        Assert-Widget (Save-WidgetPreferences -Left $fallbackPreferences.Left -Top $fallbackPreferences.Top -Monitor $fallbackPreferences.Monitor `
            -Theme $fallbackPreferences.Theme -CodexDataDirectory $fallbackPreferences.CodexDataDirectory -Language $fallbackPreferences.Language) 'position-style persistence after localization fallback should succeed.'
        $storedFallbackPreferences = [System.IO.File]::ReadAllText($preferencesPath) | ConvertFrom-Json
        Assert-Widget ($storedFallbackPreferences.Language -ceq 'ja-JP') 'position-style persistence should preserve an unavailable but valid saved language.'
        Initialize-WidgetLocalization $PSScriptRoot 'zh-CN' ([cultureinfo]'zh-CN')

        $validPreferencesJson = [System.IO.File]::ReadAllText($preferencesPath)
        Assert-Widget (-not (Save-WidgetPreferences -Left 1 -Top 2 -Monitor 'x' -Theme 0 -Language 'fr-FR')) 'an unsupported language should be rejected.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $validPreferencesJson) 'an invalid language should not replace preferences.'
        Assert-Widget (Save-WidgetPreferences -Left (-640.5) -Top 120.25 -Monitor '\\.\DISPLAY2' -Theme 7 -CodexDataDirectory $preferenceCodexRoot -Language 'ja-JP') 'theme seven should save.'
        $preferences = Get-WidgetPreferences
        Assert-Widget ($preferences.Theme -eq 7 -and $preferences.CodexDataDirectory -eq $preferenceCodexRoot -and
            $preferences.Language -ceq 'ja-JP') 'theme seven, the Codex directory, and language should round-trip together.'
        $themeSevenJson = [System.IO.File]::ReadAllText($preferencesPath)
        Assert-Widget (-not (Save-WidgetPreferences -Left 1 -Top 2 -Monitor 'x' -Theme 0 -CodexDataDirectory '.\relative')) 'a relative Codex directory should be rejected.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $themeSevenJson) 'an invalid Codex directory should not replace preferences.'
        Assert-Widget (-not (Save-WidgetPreferences -Left 1 -Top 2 -Monitor 'x' -Theme 8)) 'theme eight should be rejected.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $themeSevenJson) 'an invalid theme should not replace preferences.'
        $validPreferencesJson = $themeSevenJson
        Assert-Widget (-not (Save-WidgetPreferences -Left $true -Top 1 -Monitor 'x' -Theme 0)) 'boolean coordinates should be rejected before conversion.'
        Assert-Widget (-not (Save-WidgetPreferences -Left 1 -Top $true -Monitor 'x' -Theme 0)) 'a boolean top coordinate should be rejected before conversion.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $validPreferencesJson) 'boolean coordinates should not replace the old preference file.'
        Assert-Widget (-not (Save-WidgetPreferences -Left '-640.5' -Top '120.25' -Monitor 'x' -Theme 0)) 'string coordinates should be rejected before conversion.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $validPreferencesJson) 'string coordinates should not replace the old preference file.'
        Assert-Widget (-not (Save-WidgetPreferences -Left ([double]::NaN) -Top 1 -Monitor 'x' -Theme 0)) 'non-finite coordinates should be rejected.'
        Assert-Widget (-not (Save-WidgetPreferences -Left 1 -Top 2 -Monitor 'x' -Theme 1.5)) 'non-integer themes should be rejected.'
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $validPreferencesJson) 'invalid preference inputs should not replace the old file.'

        [System.IO.File]::WriteAllText($preferencesPath, '{"Left":true,"Top":"120","Monitor":" ","Theme":8,"CodexDataDirectory":"relative","Language":"fr-FR","Extra":1}')
        $preferences = Get-WidgetPreferences
        Assert-Widget ($null -eq $preferences.Left -and $null -eq $preferences.Top -and $null -eq $preferences.Monitor -and
            $preferences.Theme -eq 0 -and $null -eq $preferences.CodexDataDirectory -and $null -eq $preferences.Language) 'damaged preference types should fall back independently.'
        [System.IO.File]::WriteAllText($preferencesPath, '{bad json')
        $preferences = Get-WidgetPreferences
        Assert-Widget ($null -eq $preferences.Left -and $null -eq $preferences.Top -and $null -eq $preferences.Monitor -and
            $preferences.Theme -eq 0 -and $null -eq $preferences.CodexDataDirectory -and $null -eq $preferences.Language) 'invalid preference JSON should safely return defaults.'
        [System.IO.File]::WriteAllText($preferencesPath, '[]')
        $preferences = Get-WidgetPreferences
        Assert-Widget ($null -eq $preferences.Left -and $null -eq $preferences.Top -and $null -eq $preferences.Monitor -and $preferences.Theme -eq 0) 'an invalid preference structure should safely return defaults.'
        $oldJson = '{"Left":-1,"Top":2,"Monitor":"old","Theme":1}'
        [System.IO.File]::WriteAllText($preferencesPath, $oldJson)
        $lockedPreferences = [System.IO.File]::Open($preferencesPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try {
            Assert-Widget (-not (Save-WidgetPreferences -Left 3 -Top 4 -Monitor 'new' -Theme 2)) 'a locked preference target should reject replacement.'
        }
        finally {
            $lockedPreferences.Dispose()
        }
        Assert-Widget ([System.IO.File]::ReadAllText($preferencesPath) -eq $oldJson) 'a failed preference replacement should preserve readable old content.'

        $workArea = [pscustomobject]@{ Left = 0.0; Top = 0.0; Width = 1920.0; Height = 1080.0 }
        $snap = Get-SnappedWidgetPosition 12 300 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq -1 -and $snap.Top -eq 300 -and $snap.Edge -eq 'Left') 'left proximity should snap only the horizontal axis.'
        $snap = Get-SnappedWidgetPosition 1815 300 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq 1821 -and $snap.Top -eq 300 -and $snap.Edge -eq 'Right') 'right proximity should snap to the safe inset.'
        $snap = Get-SnappedWidgetPosition 600 10 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq 600 -and $snap.Top -eq -1 -and $snap.Edge -eq 'Top') 'top proximity should snap only the vertical axis.'
        $snap = Get-SnappedWidgetPosition 600 1005 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq 600 -and $snap.Top -eq 981 -and $snap.Edge -eq 'Bottom') 'bottom proximity should snap to the safe inset.'
        $snap = Get-SnappedWidgetPosition 600 400 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq 600 -and $snap.Top -eq 400 -and $null -eq $snap.Edge) 'positions outside the threshold should remain unchanged.'
        $snap = Get-SnappedWidgetPosition 9 20 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq -1 -and $snap.Top -eq 20 -and $snap.Edge -eq 'Left') 'a corner should choose the nearest edge.'
        $snap = Get-SnappedWidgetPosition 0 -20 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq -1 -and $snap.Top -eq -20 -and $snap.Edge -eq 'Left') 'horizontal snapping should preserve an off-screen orthogonal coordinate.'
        $negativeWorkArea = [pscustomobject]@{ Left = -1920.0; Top = 0.0; Width = 1920.0; Height = 1080.0 }
        $snap = Get-SnappedWidgetPosition -1910 300 100 100 82 $negativeWorkArea
        Assert-Widget ($snap.Left -eq -1921 -and $snap.Edge -eq 'Left') 'negative-coordinate work areas should snap correctly.'
        $snap = Get-SnappedWidgetPosition 10 10 100 100 82 $workArea
        Assert-Widget ($snap.Left -eq -1 -and $snap.Top -eq 10 -and $snap.Edge -eq 'Left') 'equal distances should use stable left-before-top ordering.'
    }
    finally {
        $script:ReminderGateCache = $null
        $env:LOCALAPPDATA = $savedLocalAppData
        if ([System.IO.Directory]::Exists($testLocalAppData)) { [System.IO.Directory]::Delete($testLocalAppData, $true) }
    }

    Test-ConversionFails "{`"primary`":{`"used_percent`":-1,`"resets_at`":$future}}" 'negative used percent'
    Test-ConversionFails "{`"primary`":{`"used_percent`":101,`"resets_at`":$future}}" 'over-limit used percent'
    Test-ConversionFails "{`"primary`":{`"used_percent`":-1,`"resets_at`":$future},`"secondary`":{`"used_percent`":101,`"resets_at`":$future}}" 'both windows invalid'
    Test-ConversionFails '{bad json' 'invalid JSON'
    '自检通过。'
}

if ($SelfTest) { return }

$script:WidgetPreferences = Get-WidgetPreferences
try {
    Initialize-WidgetLocalization -Root $PSScriptRoot `
        -SavedLanguage $script:WidgetPreferences.Language `
        -UiCulture ([cultureinfo]::CurrentUICulture)
}
catch {
    Show-WidgetFatalError `
        "Language pack missing or damaged.`r`n语言包缺失或损坏。" `
        "The required English language pack could not be validated.`r`n必需的英语语言包未通过验证。" `
        "Restore the complete locales folder and restart.`r`n请恢复完整的 locales 文件夹后重启。"
    return
}
if ($null -eq $script:WidgetPreferences.Language) { $script:WidgetPreferences.Language = $script:CurrentLanguageCode }

$isWindowsPowerShell51 = $PSVersionTable.PSEdition -eq 'Desktop' -and
    $PSVersionTable.PSVersion.Major -eq 5 -and $PSVersionTable.PSVersion.Minor -ge 1
if (-not $isWindowsPowerShell51) {
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.unsupportedHost') (Get-WidgetText 'fatal.useLauncherFix')
    return
}
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne [System.Threading.ApartmentState]::STA) {
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.unsupportedThread') (Get-WidgetText 'fatal.useLauncherFix')
    return
}

try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class WidgetNativeMethods {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDpiAwarenessContext(IntPtr value);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(
        IntPtr hwnd, IntPtr insertAfter, int x, int y, int width, int height, uint flags);
}
'@ -ErrorAction Stop
    if (-not [WidgetNativeMethods]::SetProcessDpiAwarenessContext([IntPtr](-4))) {
        throw 'Per-monitor DPI awareness was not enabled.'
    }
}
catch { }

try {
    Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing -ErrorAction Stop
}
catch {
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.uiLoadCause') (Get-WidgetText 'fatal.uiRepairFix')
    return
}

$createdNew = $false
try {
    $script:InstanceMutex = [System.Threading.Mutex]::new($true, 'Local\CodexUsageWidget.SingleInstance', [ref]$createdNew)
    $script:OwnsInstanceMutex = $createdNew
}
catch {
    Stop-InstanceMutex
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.mutexCause') (Get-WidgetText 'fatal.exitOldFix')
    return
}
if (-not $createdNew) {
    try {
        [void][System.Windows.MessageBox]::Show(
            (Get-WidgetText 'app.alreadyRunning'),
            (Get-WidgetText 'app.title'),
            [System.Windows.MessageBoxButton]::OK,
            [System.Windows.MessageBoxImage]::Information
        )
    }
    catch {
        try {
            $shell = New-Object -ComObject WScript.Shell
            [void]$shell.Popup((Get-WidgetText 'app.alreadyRunning'), 0, (Get-WidgetText 'app.title'), 64)
            [void][Runtime.InteropServices.Marshal]::FinalReleaseComObject($shell)
        }
        catch { }
    }
    Stop-InstanceMutex
    return
}

$xaml = Get-WidgetXaml

try {
    $script:WidgetWindow = [Windows.Markup.XamlReader]::Parse($xaml)
}
catch {
    Stop-InstanceMutex
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.windowCause') (Get-WidgetText 'fatal.restoreFix')
    return
}

$script:RingValue = $script:WidgetWindow.FindName('RingValue')
$script:GlowRing = $script:WidgetWindow.FindName('GlowRing')
$script:ShimmerRing = $script:WidgetWindow.FindName('ShimmerRing')
$script:ShimmerRotation = $script:WidgetWindow.FindName('ShimmerRotation')
$script:RemainingText = $script:WidgetWindow.FindName('RemainingText')
$script:CircleHost = $script:WidgetWindow.FindName('CircleHost')
$script:FocusRing = $script:WidgetWindow.FindName('FocusRing')
$script:DetailPopup = $script:WidgetWindow.FindName('DetailPopup')
$script:DetailCard = $script:WidgetWindow.FindName('DetailCard')
$script:DetailCardTranslate = $script:WidgetWindow.FindName('DetailCardTranslate')
$script:LimitWindowText = $script:WidgetWindow.FindName('LimitWindowText')
$script:ObservedText = $script:WidgetWindow.FindName('ObservedText')
$script:ObservedDiagnosticText = $script:WidgetWindow.FindName('ObservedDiagnosticText')
$script:DetailStatusText = $script:WidgetWindow.FindName('DetailStatusText')
$script:UsageStatusText = $script:WidgetWindow.FindName('UsageStatusText')
$script:DetailTitleText = $script:WidgetWindow.FindName('DetailTitleText')
$script:RemainingLabelText = $script:WidgetWindow.FindName('RemainingLabelText')
$script:ObservedLabelText = $script:WidgetWindow.FindName('ObservedLabelText')
$script:StatusLabelText = $script:WidgetWindow.FindName('StatusLabelText')
$script:RemainingDetailText = $script:WidgetWindow.FindName('RemainingDetailText')
$script:RemainingDetailUnitText = $script:WidgetWindow.FindName('RemainingDetailUnitText')
$script:TokenDetailsPanel = $script:WidgetWindow.FindName('TokenDetailsPanel')
$script:ActivityTitleText = $script:WidgetWindow.FindName('ActivityTitleText')
$script:ActivityWindowText = $script:WidgetWindow.FindName('ActivityWindowText')
$script:ActiveTaskEmptyText = $script:WidgetWindow.FindName('ActiveTaskEmptyText')
$script:ActiveTaskList = $script:WidgetWindow.FindName('ActiveTaskList')
$script:TaskDetailsPanel = $script:WidgetWindow.FindName('TaskDetailsPanel')
$script:TaskTitleText = $script:WidgetWindow.FindName('TaskTitleText')
$script:TaskNoDataText = $script:WidgetWindow.FindName('TaskNoDataText')
$script:CumulativeLabelText = $script:WidgetWindow.FindName('CumulativeLabelText')
$script:ContextLabelText = $script:WidgetWindow.FindName('ContextLabelText')
$script:ContextPercentLabelText = $script:WidgetWindow.FindName('ContextPercentLabelText')
$script:CompositionLabelText = $script:WidgetWindow.FindName('CompositionLabelText')
$script:TaskCacheHitLabelText = $script:WidgetWindow.FindName('TaskCacheHitLabelText')
$script:TaskCacheMissLabelText = $script:WidgetWindow.FindName('TaskCacheMissLabelText')
$script:ReasoningLabelText = $script:WidgetWindow.FindName('ReasoningLabelText')
$script:CumulativeRow = $script:WidgetWindow.FindName('CumulativeRow')
$script:ContextRow = $script:WidgetWindow.FindName('ContextRow')
$script:ContextPercentRow = $script:WidgetWindow.FindName('ContextPercentRow')
$script:CompositionRow = $script:WidgetWindow.FindName('CompositionRow')
$script:TaskCacheHitRow = $script:WidgetWindow.FindName('TaskCacheHitRow')
$script:TaskCacheMissRow = $script:WidgetWindow.FindName('TaskCacheMissRow')
$script:ReasoningRow = $script:WidgetWindow.FindName('ReasoningRow')
$script:TaskCachedText = $script:WidgetWindow.FindName('TaskCachedText')
$script:TaskCacheMissText = $script:WidgetWindow.FindName('TaskCacheMissText')
$script:CumulativeText = $script:WidgetWindow.FindName('CumulativeText')
$script:ContextText = $script:WidgetWindow.FindName('ContextText')
$script:ContextPercentText = $script:WidgetWindow.FindName('ContextPercentText')
$script:ContextBar = $script:WidgetWindow.FindName('ContextBar')
$script:ContextFillColumn = $script:WidgetWindow.FindName('ContextFillColumn')
$script:ContextRestColumn = $script:WidgetWindow.FindName('ContextRestColumn')
$script:CompositionText = $script:WidgetWindow.FindName('CompositionText')
$script:CompositionBar = $script:WidgetWindow.FindName('CompositionBar')
$script:InputColumn = $script:WidgetWindow.FindName('InputColumn')
$script:OutputColumn = $script:WidgetWindow.FindName('OutputColumn')
$script:GlobalCacheDivider = $script:WidgetWindow.FindName('GlobalCacheDivider')
$script:GlobalCacheHitRow = $script:WidgetWindow.FindName('GlobalCacheHitRow')
$script:GlobalCacheMissRow = $script:WidgetWindow.FindName('GlobalCacheMissRow')
$script:GlobalCacheHitLabelText = $script:WidgetWindow.FindName('GlobalCacheHitLabelText')
$script:GlobalCacheMissLabelText = $script:WidgetWindow.FindName('GlobalCacheMissLabelText')
$script:CachedText = $script:WidgetWindow.FindName('CachedText')
$script:CachedMissText = $script:WidgetWindow.FindName('CachedMissText')
$script:ReasoningText = $script:WidgetWindow.FindName('ReasoningText')
$script:CountdownText = $script:WidgetWindow.FindName('CountdownText')
$script:DetailAccentGlow = $script:WidgetWindow.FindName('DetailAccentGlow')
$script:DetailAccentDot = $script:WidgetWindow.FindName('DetailAccentDot')
$script:TaskDetailAccentLine = $script:WidgetWindow.FindName('TaskDetailAccentLine')
$script:ContextAccentFill = $script:WidgetWindow.FindName('ContextAccentFill')
$script:InputAccentFill = $script:WidgetWindow.FindName('InputAccentFill')
$script:OutputAccentFill = $script:WidgetWindow.FindName('OutputAccentFill')
$script:DetailAccentBrush = $null
$script:DetailAccentSoftBrush = $null
$script:LastUsageState = $null
$script:LastUsageDiagnostic = $null
$script:RefreshTicks = 0
$script:WidgetTimer = $null
$script:UsageRunspace = $null
$script:UsagePowerShell = $null
$script:UsageAsyncResult = $null
$script:PendingUsageState = $null
$script:NotifyIcon = $null
$script:TrayMenu = $null
$script:TrayShowItem = $null
$script:TrayExitItem = $null
$script:CodexDataDirectory = $null
$script:ThemeMenuItems = @()
$script:LanguageMenuItems = @()
$script:DetailMenuItem = $null
$script:LanguageMenuItem = $null
$script:ExitMenuItem = $null
$script:WidgetContextMenu = $null
$script:PercentAnimationTimer = $null
$script:DisplayedRingPercent = 0.0
$script:HoverShowTimer = $null
$script:HoverHideTimer = $null
$script:TaskDetailHideTimer = $null
$script:ActiveTaskRow = $null
$script:ActiveTaskId = $null
$script:HasShownHoverShimmer = $false
$script:LastShimmerObservationKey = $null

try {
    $script:NotifyIcon = [System.Windows.Forms.NotifyIcon]::new()
    $script:NotifyIcon.Icon = [System.Drawing.SystemIcons]::Information
    $script:NotifyIcon.Text = Get-WidgetText 'app.title'
    $script:TrayMenu = [System.Windows.Forms.ContextMenuStrip]::new()
    $script:TrayShowItem = [System.Windows.Forms.ToolStripMenuItem]::new((Get-WidgetText 'menu.showWidget'))
    $script:TrayShowItem.Add_Click({
        [void]$script:WidgetWindow.Dispatcher.BeginInvoke([System.Action]{
            if (-not $script:WidgetWindow.IsVisible) { $script:WidgetWindow.Show() }
            [void]$script:WidgetWindow.Activate()
        })
    })
    $script:TrayExitItem = [System.Windows.Forms.ToolStripMenuItem]::new((Get-WidgetText 'menu.exit'))
    $script:TrayExitItem.Add_Click({
        [void]$script:WidgetWindow.Dispatcher.BeginInvoke([System.Action]{ $script:WidgetWindow.Close() })
    })
    [void]$script:TrayMenu.Items.Add($script:TrayShowItem)
    [void]$script:TrayMenu.Items.Add($script:TrayExitItem)
    $script:NotifyIcon.ContextMenuStrip = $script:TrayMenu
    $script:NotifyIcon.Visible = $true
}
catch {
    if ($null -ne $script:TrayMenu) {
        try { $script:TrayMenu.Dispose() } catch { }
        $script:TrayMenu = $null
    }
    if ($null -ne $script:NotifyIcon) {
        try { $script:NotifyIcon.Dispose() } catch { }
        $script:NotifyIcon = $null
    }
    Stop-InstanceMutex
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.notificationCause') (Get-WidgetText 'fatal.restartNotificationFix')
    return
}

function Test-WidgetAnimationEnabled {
    return [System.Windows.SystemParameters]::ClientAreaAnimation -and -not [System.Windows.SystemParameters]::HighContrast
}

function Set-RingPercentCore {
    param([double]$Percent)

    $bounded = [math]::Max(0, [math]::Min(100, $Percent))
    $stroke = [math]::Max(0.01, [double]$script:RingValue.StrokeThickness)
    $diameter = [math]::Max($stroke, [double]$script:RingValue.ActualWidth)
    $circumference = [math]::PI * [math]::Max(0.01, $diameter - $stroke) / $stroke
    $dash = New-Object System.Windows.Media.DoubleCollection
    [void]$dash.Add([math]::Max(0.01, $circumference * $bounded / 100))
    [void]$dash.Add([math]::Max(0.01, $circumference * (100 - $bounded) / 100))
    $script:RingValue.StrokeDashArray = $dash
    $script:RingValue.Opacity = if ($bounded -le 0) { 0 } else { 1 }
    $script:DisplayedRingPercent = $bounded
}

function Set-RingPercent {
    param([double]$Percent)

    $target = [math]::Max(0, [math]::Min(100, $Percent))
    if ($null -ne $script:PercentAnimationTimer) {
        $script:PercentAnimationTimer.Stop()
        $script:PercentAnimationTimer = $null
    }
    if (-not (Test-WidgetAnimationEnabled) -or [math]::Abs($target - $script:DisplayedRingPercent) -lt 0.01) {
        Set-RingPercentCore $target
        return
    }

    $script:RingAnimationFrom = [double]$script:DisplayedRingPercent
    $script:RingAnimationTo = $target
    $script:RingAnimationClock = [Diagnostics.Stopwatch]::StartNew()
    $script:PercentAnimationTimer = [System.Windows.Threading.DispatcherTimer]::new()
    $script:PercentAnimationTimer.Interval = [TimeSpan]::FromMilliseconds(16)
    $script:PercentAnimationTimer.Add_Tick({
        $progress = [math]::Min(1.0, $script:RingAnimationClock.Elapsed.TotalMilliseconds / 240.0)
        $eased = 1 - [math]::Pow(1 - $progress, 3)
        Set-RingPercentCore ($script:RingAnimationFrom + (($script:RingAnimationTo - $script:RingAnimationFrom) * $eased))
        if ($progress -ge 1) {
            $script:PercentAnimationTimer.Stop()
            $script:PercentAnimationTimer = $null
            $script:RingAnimationClock.Stop()
        }
    })
    $script:PercentAnimationTimer.Start()
}

function Start-ShimmerAnimation {
    try {
        $script:ShimmerRotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        $script:ShimmerRotation.Angle = -90
        if (-not (Test-WidgetAnimationEnabled)) { return }
        $animation = [System.Windows.Media.Animation.DoubleAnimation]::new(-90, 270, [TimeSpan]::FromMilliseconds(900))
        $animation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
        $animation.Add_Completed({
            $script:ShimmerRotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
            $script:ShimmerRotation.Angle = 270
        })
        $script:ShimmerRotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $animation)
    }
    catch { }
}

function Clear-WidgetPositionAnimation {
    try {
        $script:WidgetWindow.BeginAnimation([System.Windows.Window]::LeftProperty, $null)
        $script:WidgetWindow.BeginAnimation([System.Windows.Window]::TopProperty, $null)
    }
    catch { }
}

function Set-WidgetPosition {
    param([double]$Left, [double]$Top, [switch]$Animate)

    Clear-WidgetPositionAnimation
    if (-not $Animate -or -not (Test-WidgetAnimationEnabled)) {
        $script:WidgetWindow.Left = $Left
        $script:WidgetWindow.Top = $Top
        return
    }
    $startLeft = $script:WidgetWindow.Left
    $startTop = $script:WidgetWindow.Top
    $script:WidgetWindow.Left = $Left
    $script:WidgetWindow.Top = $Top
    $leftAnimation = [System.Windows.Media.Animation.DoubleAnimation]::new($startLeft, $Left, [TimeSpan]::FromMilliseconds(180))
    $topAnimation = [System.Windows.Media.Animation.DoubleAnimation]::new($startTop, $Top, [TimeSpan]::FromMilliseconds(180))
    $ease = [System.Windows.Media.Animation.CubicEase]::new()
    $ease.EasingMode = [System.Windows.Media.Animation.EasingMode]::EaseOut
    $leftAnimation.EasingFunction = $ease
    $topAnimation.EasingFunction = $ease
    $leftAnimation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $topAnimation.FillBehavior = [System.Windows.Media.Animation.FillBehavior]::Stop
    $script:WidgetWindow.BeginAnimation([System.Windows.Window]::LeftProperty, $leftAnimation)
    $script:WidgetWindow.BeginAnimation([System.Windows.Window]::TopProperty, $topAnimation)
}

function Get-WidgetHwnd {
    try { return [System.Windows.Interop.WindowInteropHelper]::new($script:WidgetWindow).Handle }
    catch { return [IntPtr]::Zero }
}

function Get-WidgetScreen {
    $handle = Get-WidgetHwnd
    if ($handle -ne [IntPtr]::Zero) {
        try { return [System.Windows.Forms.Screen]::FromHandle($handle) } catch { }
    }
    try {
        $scale = [System.Windows.Media.VisualTreeHelper]::GetDpi($script:WidgetWindow)
        $x = [int](($script:WidgetWindow.Left + ($script:WidgetWindow.Width / 2)) * $scale.DpiScaleX)
        $y = [int](($script:WidgetWindow.Top + ($script:WidgetWindow.Height / 2)) * $scale.DpiScaleY)
        return [System.Windows.Forms.Screen]::FromPoint([System.Drawing.Point]::new($x, $y))
    }
    catch { return [System.Windows.Forms.Screen]::PrimaryScreen }
}

function Get-ScreenWorkArea {
    param([Parameter(Mandatory)][System.Windows.Forms.Screen]$Screen)

    $scaleX = 1.0
    $scaleY = 1.0
    try {
        $dpi = [System.Windows.Media.VisualTreeHelper]::GetDpi($script:WidgetWindow)
        $candidateX = [double]$dpi.DpiScaleX
        $candidateY = [double]$dpi.DpiScaleY
        if (-not [double]::IsNaN($candidateX) -and -not [double]::IsInfinity($candidateX) -and $candidateX -gt 0) { $scaleX = $candidateX }
        if (-not [double]::IsNaN($candidateY) -and -not [double]::IsInfinity($candidateY) -and $candidateY -gt 0) { $scaleY = $candidateY }
    }
    catch { }
    $area = $Screen.WorkingArea
    $left = [double]$area.Left / $scaleX
    $top = [double]$area.Top / $scaleY
    $width = [double]$area.Width / $scaleX
    $height = [double]$area.Height / $scaleY
    return [pscustomobject]@{
        Left = $left; Top = $top; Width = $width; Height = $height
        Right = $left + $width; Bottom = $top + $height
    }
}

function Complete-WidgetPositionRestore {
    param(
        [Parameter(Mandatory)][System.Windows.Forms.Screen]$RequestedScreen,
        [Parameter(Mandatory)][bool]$MoveSucceeded
    )

    $actualScreen = try { Get-WidgetScreen } catch { $null }
    $screen = Resolve-WidgetRestoreScreen $RequestedScreen $actualScreen ([System.Windows.Forms.Screen]::PrimaryScreen) $MoveSucceeded
    if ($null -eq $screen) { return }
    $area = Get-ScreenWorkArea $screen
    $left = if ($null -ne $script:WidgetPreferences.Left) { [double]$script:WidgetPreferences.Left } else { $area.Right - 99 }
    $top = if ($null -ne $script:WidgetPreferences.Top) { [double]$script:WidgetPreferences.Top } else { $area.Top + 15 }
    $left = [Math]::Max($area.Left - 1, [Math]::Min($area.Right - 99, $left))
    $top = [Math]::Max($area.Top - 1, [Math]::Min($area.Bottom - 99, $top))
    Set-WidgetPosition $left $top
    $script:WidgetPreferences.Left = $left
    $script:WidgetPreferences.Top = $top
    $script:WidgetPreferences.Monitor = $screen.DeviceName
    [void](Save-WidgetPreferences -Left $left -Top $top -Monitor $screen.DeviceName -Theme $script:WidgetPreferences.Theme -CodexDataDirectory $script:WidgetPreferences.CodexDataDirectory -Language $script:WidgetPreferences.Language)
}

function Restore-WidgetPosition {
    $screen = $null
    if ($null -ne $script:WidgetPreferences.Monitor) {
        $screen = [System.Windows.Forms.Screen]::AllScreens |
            Where-Object { $_.DeviceName -eq $script:WidgetPreferences.Monitor } |
            Select-Object -First 1
    }
    if ($null -eq $screen) { $screen = [System.Windows.Forms.Screen]::PrimaryScreen }
    $moveSucceeded = $false
    $handle = Get-WidgetHwnd
    if ($handle -ne [IntPtr]::Zero) {
        $area = $screen.WorkingArea
        try {
            $moveSucceeded = [WidgetNativeMethods]::SetWindowPos(
                $handle, [IntPtr]::Zero, $area.Left + 16, $area.Top + 16, 0, 0, 0x0015)
        }
        catch { $moveSucceeded = $false }
    }
    $restoreScreen = $screen
    $restoreMoveSucceeded = $moveSucceeded
    [void]$script:WidgetWindow.Dispatcher.BeginInvoke(
        [System.Windows.Threading.DispatcherPriority]::ApplicationIdle,
        [System.Action]{ Complete-WidgetPositionRestore $restoreScreen $restoreMoveSucceeded }.GetNewClosure())
}

function Snap-And-SaveWidgetPosition {
    $screen = Get-WidgetScreen
    $area = Get-ScreenWorkArea $screen
    $position = Get-SnappedWidgetPosition $script:WidgetWindow.Left $script:WidgetWindow.Top 100 100 82 $area
    Set-WidgetPosition $position.Left $position.Top -Animate
    $script:WidgetPreferences.Left = [double]$position.Left
    $script:WidgetPreferences.Top = [double]$position.Top
    $script:WidgetPreferences.Monitor = $screen.DeviceName
    [void](Save-WidgetPreferences -Left $position.Left -Top $position.Top -Monitor $screen.DeviceName -Theme $script:WidgetPreferences.Theme -CodexDataDirectory $script:WidgetPreferences.CodexDataDirectory -Language $script:WidgetPreferences.Language)
}

function Set-WidgetTheme {
    param([Parameter(Mandatory)][ValidateRange(0, 7)][int]$Theme)

    $script:WidgetPreferences.Theme = $Theme
    foreach ($item in $script:ThemeMenuItems) { $item.IsChecked = ([int]$item.Tag -eq $Theme) }
    $current = if ($null -ne $script:LastUsageState) {
        Get-CurrentLimitState -State $script:LastUsageState -Now (Get-Date)
    }
    if ($null -ne $current) {
        Set-WidgetAppearance ([double]$current.RemainingPercent)
        Start-ShimmerAnimation
    }
    if ($null -ne $script:WidgetPreferences.Left -and $null -ne $script:WidgetPreferences.Top) {
        [void](Save-WidgetPreferences -Left $script:WidgetPreferences.Left -Top $script:WidgetPreferences.Top -Monitor $script:WidgetPreferences.Monitor -Theme $Theme -CodexDataDirectory $script:WidgetPreferences.CodexDataDirectory -Language $script:WidgetPreferences.Language)
    }
}

function Show-DetailPopup {
    param([switch]$FromHover)

    $screen = Get-WidgetScreen
    $area = Get-ScreenWorkArea $screen
    $availableWidth = [Math]::Max(1, [Math]::Min(310, $area.Width - 16))
    $availableHeight = [Math]::Max(1, $area.Height - 16)
    $script:DetailCard.Width = $availableWidth
    $script:DetailCard.MaxHeight = $availableHeight
    $script:DetailCard.Measure([System.Windows.Size]::new($availableWidth, $availableHeight))
    $height = [Math]::Min($script:DetailCard.MaxHeight, [double]$script:DetailCard.DesiredSize.Height)
    $position = Get-DetailPopupPosition ($script:WidgetWindow.Left + 9) ($script:WidgetWindow.Top + 9) 82 $availableWidth $height $area
    $script:DetailCard.Width = $position.CardWidth
    $script:DetailPopup.HorizontalOffset = $position.Left
    $script:DetailPopup.VerticalOffset = $position.Top
    if ($script:DetailPopup.IsOpen) {
        $script:DetailCard.Opacity = 1
        return
    }
    $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    $script:DetailCardTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
    $script:DetailCard.Opacity = 0
    $script:DetailCardTranslate.X = if ($position.OpensLeft) { 8 } else { -8 }
    $script:DetailPopup.IsOpen = $true
    if (Test-WidgetAnimationEnabled) {
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new(0, 1, [TimeSpan]::FromMilliseconds(160))
        $slide = [System.Windows.Media.Animation.DoubleAnimation]::new($script:DetailCardTranslate.X, 0, [TimeSpan]::FromMilliseconds(160))
        $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
        $script:DetailCardTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $slide)
    }
    else {
        $script:DetailCard.Opacity = 1
        $script:DetailCardTranslate.X = 0
    }
    if ($null -ne $script:DetailMenuItem) { $script:DetailMenuItem.Header = Get-WidgetText 'menu.hideDetails' }
    if ($FromHover -and -not $script:HasShownHoverShimmer) {
        $script:HasShownHoverShimmer = $true
        Start-ShimmerAnimation
    }
}

function Cancel-DetailPopupHide {
    $script:HoverHideTimer.Stop()
    $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
    if ($script:DetailPopup.IsOpen) {
        $script:DetailCard.Opacity = 1
        if ($null -ne $script:DetailMenuItem) { $script:DetailMenuItem.Header = Get-WidgetText 'menu.hideDetails' }
    }
}

function Hide-DetailPopup {
    param([switch]$Immediate)

    if (-not $script:DetailPopup.IsOpen) {
        Hide-ActiveTaskDetails
        return
    }
    if ($Immediate -or -not (Test-WidgetAnimationEnabled)) {
        $script:DetailPopup.IsOpen = $false
        Hide-ActiveTaskDetails
        if ($null -ne $script:DetailMenuItem) { $script:DetailMenuItem.Header = Get-WidgetText 'menu.showDetails' }
    }
    else {
        $fade = [System.Windows.Media.Animation.DoubleAnimation]::new($script:DetailCard.Opacity, 0, [TimeSpan]::FromMilliseconds(120))
        $fade.Add_Completed({
            if ($script:CircleHost.IsMouseOver -or $script:DetailCard.IsMouseOver) {
                Cancel-DetailPopupHide
            }
            else {
                $script:DetailPopup.IsOpen = $false
                Hide-ActiveTaskDetails
                $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
                if ($null -ne $script:DetailMenuItem) { $script:DetailMenuItem.Header = Get-WidgetText 'menu.showDetails' }
            }
        })
        $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $fade)
    }
}

function Toggle-DetailPopup {
    if ($script:DetailPopup.IsOpen) { Hide-DetailPopup } else { Show-DetailPopup }
}

function Show-UsageReminder {
    param([Parameter(Mandatory)]$State)

    if ($null -eq $script:NotifyIcon) { return }
    try {
        $remaining = [double]$State.RemainingPercent
        $resetAt = [datetime]$State.ResetAt
        $script:NotifyIcon.ShowBalloonTip(
            5000,
            (Get-WidgetText 'reminder.title' @($remaining)),
            (Get-WidgetText 'reminder.body' @($resetAt)),
            [System.Windows.Forms.ToolTipIcon]::Warning
        )
    }
    catch { }
}

function Show-CodexDataDirectoryPicker {
    while ($true) {
        $dialog = $null
        $selectedDirectory = $null
        try {
            $dialog = [System.Windows.Forms.FolderBrowserDialog]::new()
            $dialog.Description = Get-WidgetText 'picker.description'
            $dialog.ShowNewFolderButton = $false
            if ($dialog.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
            $selectedDirectory = Resolve-CodexDataDirectory $dialog.SelectedPath $null $null
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-WidgetText 'picker.openFailed'),
                (Get-WidgetText 'app.title'),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            return $null
        }
        finally {
            if ($null -ne $dialog) { $dialog.Dispose() }
        }
        if ($null -ne $selectedDirectory) { return $selectedDirectory }
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-WidgetText 'picker.invalidDirectory'),
            (Get-WidgetText 'app.title'),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
    }
}

function Initialize-UsageWorker {
    $initialState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    foreach ($functionName in Get-UsageWorkerFunctionNames) {
        $definition = (Get-Command -Name $functionName -CommandType Function -ErrorAction Stop).Definition
        $entry = [System.Management.Automation.Runspaces.SessionStateFunctionEntry]::new($functionName, $definition)
        $initialState.Commands.Add($entry)
    }

    $script:UsageRunspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace($initialState)
    $script:UsageRunspace.ApartmentState = [System.Threading.ApartmentState]::MTA
    $script:UsageRunspace.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::ReuseThread
    $script:UsageRunspace.Open()
    $script:UsagePowerShell = [System.Management.Automation.PowerShell]::Create()
    $script:UsagePowerShell.Runspace = $script:UsageRunspace
}

function Start-UsageRefresh {
    if ($null -eq $script:UsagePowerShell -or $null -ne $script:UsageAsyncResult) { return $false }

    try {
        $script:CodexDataDirectory = Resolve-CodexDataDirectory `
            $script:WidgetPreferences.CodexDataDirectory $env:CODEX_HOME $env:USERPROFILE
        $script:UsagePowerShell.Commands.Clear()
        $script:UsagePowerShell.Streams.Error.Clear()
        [void]$script:UsagePowerShell.AddCommand('Get-CodexUsageSnapshot')
        [void]$script:UsagePowerShell.AddParameter('DataDirectory', $script:CodexDataDirectory)
        $script:UsageAsyncResult = $script:UsagePowerShell.BeginInvoke()
        return $true
    }
    catch {
        $script:UsageAsyncResult = $null
        return $false
    }
}

function Complete-UsageRefresh {
    if ($null -eq $script:UsageAsyncResult -or -not $script:UsageAsyncResult.IsCompleted) { return }

    $completed = $script:UsageAsyncResult
    $script:UsageAsyncResult = $null
    $snapshot = $null
    $errorCount = 0
    try {
        $results = $script:UsagePowerShell.EndInvoke($completed)
        if ($null -ne $results -and $results.Count -gt 0) { $snapshot = $results[$results.Count - 1] }
    }
    catch { $errorCount = 1 }
    $errorCount += $script:UsagePowerShell.Streams.Error.Count
    $refreshResult = Resolve-UsageRefreshResult -Snapshot $snapshot -ErrorCount $errorCount

    $script:LastUsageDiagnostic = $refreshResult.Diagnostic
    $script:PendingUsageState = $refreshResult.State
    try {
        [void]$script:WidgetWindow.Dispatcher.BeginInvoke([System.Action]{
            $nextState = $script:PendingUsageState
            $script:PendingUsageState = $null
            Set-WidgetState -State $nextState
        })
    }
    catch {
        $script:PendingUsageState = $null
    }
}

function Stop-UsageWorker {
    if ($null -ne $script:UsagePowerShell) {
        if ($null -ne $script:UsageAsyncResult) {
            try { $script:UsagePowerShell.Stop() } catch { }
            try { $script:UsagePowerShell.EndInvoke($script:UsageAsyncResult) | Out-Null } catch { }
            $script:UsageAsyncResult = $null
        }
        try { $script:UsagePowerShell.Dispose() } catch { }
        $script:UsagePowerShell = $null
    }
    if ($null -ne $script:UsageRunspace) {
        try { $script:UsageRunspace.Close() } catch { }
        try { $script:UsageRunspace.Dispose() } catch { }
        $script:UsageRunspace = $null
    }
    $script:PendingUsageState = $null
}

function Stop-WidgetResources {
    foreach ($timerName in 'PercentAnimationTimer', 'HoverShowTimer', 'HoverHideTimer', 'TaskDetailHideTimer') {
        $timer = Get-Variable -Name $timerName -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $timer) {
            try { $timer.Stop() } catch { }
            Set-Variable -Name $timerName -Scope Script -Value $null
        }
    }
    try {
        $script:RingValue.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $script:ShimmerRotation.BeginAnimation([System.Windows.Media.RotateTransform]::AngleProperty, $null)
        Clear-WidgetPositionAnimation
        $script:DetailCard.BeginAnimation([System.Windows.UIElement]::OpacityProperty, $null)
        $script:DetailCardTranslate.BeginAnimation([System.Windows.Media.TranslateTransform]::XProperty, $null)
        $script:DetailPopup.IsOpen = $false
    }
    catch { }
    if ($null -ne $script:WidgetTimer) {
        $script:WidgetTimer.Stop()
        $script:WidgetTimer = $null
    }
    Stop-UsageWorker
    if ($null -ne $script:TrayMenu) {
        try { $script:TrayMenu.Dispose() } catch { }
        $script:TrayMenu = $null
    }
    if ($null -ne $script:NotifyIcon) {
        try {
            $script:NotifyIcon.Visible = $false
            $script:NotifyIcon.Dispose()
        }
        catch { }
        $script:NotifyIcon = $null
    }
    Stop-InstanceMutex
}

$script:HoverShowTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:HoverShowTimer.Interval = [TimeSpan]::FromMilliseconds(250)
$script:HoverShowTimer.Add_Tick({
    $script:HoverShowTimer.Stop()
    if ($script:CircleHost.IsMouseOver -or $script:DetailCard.IsMouseOver) { Show-DetailPopup -FromHover }
})
$script:HoverHideTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:HoverHideTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:HoverHideTimer.Add_Tick({
    $script:HoverHideTimer.Stop()
    if (-not $script:CircleHost.IsMouseOver -and -not $script:DetailCard.IsMouseOver) { Hide-DetailPopup }
})
$script:TaskDetailHideTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:TaskDetailHideTimer.Interval = [TimeSpan]::FromMilliseconds(150)
$script:TaskDetailHideTimer.Add_Tick({
    $script:TaskDetailHideTimer.Stop()
    if (-not $script:TaskDetailsPanel.IsMouseOver -and
        ($null -eq $script:ActiveTaskRow -or -not $script:ActiveTaskRow.IsMouseOver) -and
        -not $script:TaskDetailsPanel.IsKeyboardFocusWithin) {
        Hide-ActiveTaskDetails
    }
})
$script:TaskDetailsPanel.Add_MouseEnter({ $script:TaskDetailHideTimer.Stop() })
$script:TaskDetailsPanel.Add_MouseLeave({
    $script:TaskDetailHideTimer.Stop()
    $script:TaskDetailHideTimer.Start()
})

$script:WidgetContextMenu = [System.Windows.Controls.ContextMenu]::new()
$script:DetailMenuItem = [System.Windows.Controls.MenuItem]::new()
$script:DetailMenuItem.Header = Get-WidgetText 'menu.showDetails'
$script:DetailMenuItem.Add_Click({ Toggle-DetailPopup })
[void]$script:WidgetContextMenu.Items.Add($script:DetailMenuItem)
$script:LanguageMenuItem = [System.Windows.Controls.MenuItem]::new()
$script:LanguageMenuItem.Header = Get-WidgetText 'menu.language'
foreach ($code in Get-WidgetLanguageCodes) {
    $languageItem = [System.Windows.Controls.MenuItem]::new()
    $languageItem.Header = Get-WidgetText ('language.' + $code)
    $languageItem.Tag = $code
    $languageItem.IsCheckable = $true
    $languageItem.Add_Click({
        param($sender, $eventArgs)
        [void](Set-WidgetLanguage -Code ([string]$sender.Tag) -Persist)
    })
    $script:LanguageMenuItems += $languageItem
    [void]$script:LanguageMenuItem.Items.Add($languageItem)
}
[void]$script:WidgetContextMenu.Items.Add($script:LanguageMenuItem)
[void]$script:WidgetContextMenu.Items.Add([System.Windows.Controls.Separator]::new())
$themeIndex = 0
foreach ($theme in @(Get-WidgetThemes)) {
    $themeItem = [System.Windows.Controls.MenuItem]::new()
    $themeItem.Header = Get-WidgetText $theme.NameKey
    $themeItem.Tag = $themeIndex
    $themeItem.IsCheckable = $true
    $themeItem.Add_Click({
        param($sender, $eventArgs)
        Set-WidgetTheme -Theme ([int]$sender.Tag)
    })
    $script:ThemeMenuItems += $themeItem
    [void]$script:WidgetContextMenu.Items.Add($themeItem)
    $themeIndex++
}
[void]$script:WidgetContextMenu.Items.Add([System.Windows.Controls.Separator]::new())
$script:ExitMenuItem = [System.Windows.Controls.MenuItem]::new()
$script:ExitMenuItem.Header = Get-WidgetText 'menu.exit'
$script:ExitMenuItem.Add_Click({ $script:WidgetWindow.Close() })
[void]$script:WidgetContextMenu.Items.Add($script:ExitMenuItem)
$script:WidgetContextMenu.Add_Opened({
    $script:DetailMenuItem.Header = Get-WidgetText $(if ($script:DetailPopup.IsOpen) { 'menu.hideDetails' } else { 'menu.showDetails' })
    foreach ($item in $script:LanguageMenuItems) { $item.IsChecked = ([string]$item.Tag -ceq $script:CurrentLanguageCode) }
    foreach ($item in $script:ThemeMenuItems) { $item.IsChecked = ([int]$item.Tag -eq $script:WidgetPreferences.Theme) }
})
$script:CircleHost.ContextMenu = $script:WidgetContextMenu
Apply-WidgetLanguage

$script:CircleHost.Add_MouseEnter({
    Cancel-DetailPopupHide
    $script:HoverShowTimer.Stop()
    $script:HoverShowTimer.Start()
})
$script:CircleHost.Add_MouseLeave({
    $script:HoverShowTimer.Stop()
    $script:HoverHideTimer.Stop()
    $script:HoverHideTimer.Start()
})
$script:DetailCard.Add_MouseEnter({
    Cancel-DetailPopupHide
})
$script:DetailCard.Add_MouseLeave({
    $script:HoverHideTimer.Stop()
    $script:HoverHideTimer.Start()
})
$script:CircleHost.Add_GotKeyboardFocus({ $script:FocusRing.Opacity = 1 })
$script:CircleHost.Add_LostKeyboardFocus({ $script:FocusRing.Opacity = 0 })
$script:CircleHost.Add_MouseLeftButtonDown({
    param($sender, $eventArgs)
    if ($eventArgs.ChangedButton -eq [System.Windows.Input.MouseButton]::Left) {
        $script:HoverShowTimer.Stop()
        $script:HoverHideTimer.Stop()
        Hide-DetailPopup -Immediate
        [void]$script:CircleHost.Focus()
        Clear-WidgetPositionAnimation
        $eventArgs.Handled = $true
        try {
            $script:WidgetWindow.DragMove()
            Snap-And-SaveWidgetPosition
        }
        catch { }
    }
})
$script:CircleHost.Add_KeyDown({
    param($sender, $eventArgs)
    if ($eventArgs.Key -in [System.Windows.Input.Key]::Enter, [System.Windows.Input.Key]::Space) {
        Toggle-DetailPopup
        $eventArgs.Handled = $true
    }
    elseif ($eventArgs.Key -eq [System.Windows.Input.Key]::Escape) {
        Hide-DetailPopup
        $eventArgs.Handled = $true
    }
    elseif (($eventArgs.Key -eq [System.Windows.Input.Key]::System -and $eventArgs.SystemKey -eq [System.Windows.Input.Key]::F10) -and
        ([System.Windows.Input.Keyboard]::Modifiers -band [System.Windows.Input.ModifierKeys]::Shift)) {
        $script:WidgetContextMenu.PlacementTarget = $script:CircleHost
        $script:WidgetContextMenu.IsOpen = $true
        $eventArgs.Handled = $true
    }
})

$script:WidgetWindow.Add_Loaded({
    Set-WidgetTheme -Theme $script:WidgetPreferences.Theme
    Restore-WidgetPosition
})
$script:WidgetWindow.Add_Closed({
    Stop-WidgetResources
})

$script:CodexDataDirectory = Resolve-CodexDataDirectory `
    $script:WidgetPreferences.CodexDataDirectory $env:CODEX_HOME $env:USERPROFILE
if ($null -eq $script:CodexDataDirectory) {
    $selectedCodexDataDirectory = Show-CodexDataDirectoryPicker
    if ($null -ne $selectedCodexDataDirectory) {
        $script:CodexDataDirectory = $selectedCodexDataDirectory
        $script:WidgetPreferences.CodexDataDirectory = $selectedCodexDataDirectory
    }
}

Set-WidgetState -State $null
try {
    Initialize-UsageWorker
    if (-not (Start-UsageRefresh)) { throw 'The usage worker did not start.' }
}
catch {
    Stop-WidgetResources
    Show-WidgetFatalError (Get-WidgetText 'fatal.startProblem') (Get-WidgetText 'fatal.workerCause') (Get-WidgetText 'fatal.restoreFix')
    return
}
$script:WidgetTimer = [System.Windows.Threading.DispatcherTimer]::new()
$script:WidgetTimer.Interval = [TimeSpan]::FromSeconds(1)
$script:WidgetTimer.Add_Tick({
    Complete-UsageRefresh
    Update-WidgetCountdown
    $script:RefreshTicks++
    if ($script:RefreshTicks -ge 15) {
        if (Start-UsageRefresh) { $script:RefreshTicks = 0 }
    }
})
$script:WidgetTimer.Start()
try {
    [void]$script:WidgetWindow.ShowDialog()
}
finally {
    Stop-WidgetResources
}
