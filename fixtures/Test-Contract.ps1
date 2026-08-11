param(
    [Parameter(Mandatory)][string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Contract assertion failed: $Message" }
}

function ConvertTo-CanonicalContractState {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][datetime]$Now,
        [Parameter(Mandatory)][int]$CandidateFileCount
    )

    $state = $Snapshot.State
    $current = if ($null -ne $state) { Get-CurrentLimitState -State $state -Now $Now } else { $null }
    $details = if ($null -ne $state -and $null -ne $state.PSObject.Properties['TokenDetails']) { $state.TokenDetails } else { $null }
    $observedAt = if ($null -ne $state -and $state.PSObject.Properties['ObservedAt'].Value -is [datetime]) {
        [DateTimeOffset]::new(([datetime]$state.ObservedAt).ToUniversalTime()).ToUnixTimeMilliseconds()
    } else { $null }
    $tasks = @(
        if ($null -ne $state -and $null -ne $state.PSObject.Properties['ActiveTasks']) {
            foreach ($task in @($state.ActiveTasks)) {
                $taskDetails = $task.TokenDetails
                [ordered]@{
                    id = [string]$task.Id
                    name = [string]$task.Name
                    observedAt = [DateTimeOffset]::new(([datetime]$task.UpdatedAt).ToUniversalTime()).ToUnixTimeMilliseconds()
                    cumulativeTokens = if ($null -ne $taskDetails.CumulativeTokens) { [string]$taskDetails.CumulativeTokens } else { $null }
                    cacheHitTokens = if ($null -ne $taskDetails.CacheHitTokens) { [string]$taskDetails.CacheHitTokens } else { $null }
                    cacheMissTokens = if ($null -ne $taskDetails.CacheMissTokens) { [string]$taskDetails.CacheMissTokens } else { $null }
                    contextTokens = if ($null -ne $taskDetails.ContextTokens) { [string]$taskDetails.ContextTokens } else { $null }
                    contextLimit = if ($null -ne $taskDetails.ContextLimit) { [string]$taskDetails.ContextLimit } else { $null }
                    contextPercent = if ($null -ne $taskDetails.ContextPercent) { ([decimal]$taskDetails.ContextPercent).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
                    inputPercent = if ($null -ne $taskDetails.InputPercent) { ([decimal]$taskDetails.InputPercent).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
                    outputPercent = if ($null -ne $taskDetails.OutputPercent) { ([decimal]$taskDetails.OutputPercent).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
                    reasoningOutputPercent = if ($null -ne $taskDetails.ReasoningOutputPercent) { ([decimal]$taskDetails.ReasoningOutputPercent).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
                }
            }
        }
    )
    $stringValue = {
        param([string]$Name)
        if ($null -ne $details -and $null -ne $details.PSObject.Properties[$Name] -and $null -ne $details.$Name) { return [string]$details.$Name }
        return $null
    }
    $percentValue = {
        param([string]$Name)
        if ($null -ne $details -and $null -ne $details.PSObject.Properties[$Name] -and $null -ne $details.$Name) {
            return ([decimal]$details.$Name).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
        }
        return $null
    }

    return [ordered]@{
        schemaVersion = 1
        sourceKind = 'local-session-observation'
        classification = [string]$Snapshot.Classification
        freshness = 'current'
        selectedWindow = if ($null -ne $current) { [string]$current.Name } else { $null }
        remainingPercent = if ($null -ne $current) { ([decimal]$current.RemainingPercent).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) } else { $null }
        cumulativeTokens = & $stringValue 'CumulativeTokens'
        cacheHitTokens = & $stringValue 'CacheHitTokens'
        cacheMissTokens = & $stringValue 'CacheMissTokens'
        contextTokens = & $stringValue 'ContextTokens'
        contextLimit = & $stringValue 'ContextLimit'
        contextPercent = & $percentValue 'ContextPercent'
        inputPercent = & $percentValue 'InputPercent'
        outputPercent = & $percentValue 'OutputPercent'
        reasoningOutputPercent = & $percentValue 'ReasoningOutputPercent'
        observedAt = $observedAt
        tasks = [object[]]$tasks
        taskNamesAvailable = if ($null -ne $state -and $null -ne $state.PSObject.Properties['TaskNamesAvailable']) { [bool]$state.TaskNamesAvailable } else { $false }
        metrics = [ordered]@{
            validEventCount = [int]$Snapshot.Metrics.UsageEventCount
            malformedLineCount = [int]$Snapshot.Metrics.MalformedLineCount
            unknownEventCount = [int]$Snapshot.Metrics.UnknownEventCount
            readFailureCount = [int]$Snapshot.Metrics.ReadFailureCount
            candidateFileCount = $CandidateFileCount
            limitWindowCount = if ($null -ne $state) { @($state.LimitWindows).Count } else { 0 }
        }
    }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$contractRoot = Join-Path $package 'fixtures\contract\v1'
$expectedPath = Join-Path $contractRoot 'expected-state.json'
foreach ($relativePath in 'VERSION', 'fixtures\contract\v1\schema.md', 'fixtures\contract\v1\theme-catalog.json', 'fixtures\contract\v1\expected-state.json') {
    Assert-Contract ([IO.File]::Exists((Join-Path $package $relativePath))) "missing required contract file: $relativePath"
}

$version = [IO.File]::ReadAllText((Join-Path $package 'VERSION')).Trim()
Assert-Contract ($version -ceq '1.1.0') 'VERSION must be exactly 1.1.0.'

$expected = [IO.File]::ReadAllText($expectedPath) | ConvertFrom-Json -ErrorAction Stop
Assert-Contract ($expected.schemaVersion -eq 1) 'expected-state schemaVersion must be 1.'
Assert-Contract ($expected.sourceKind -ceq 'local-session-observation') 'sourceKind must be local-session-observation.'
Assert-Contract (@($expected.cases).Count -eq 14) 'the v1 contract must contain fourteen reviewed cases.'

. (Join-Path $package 'CodexUsageWidget.ps1') -SelfTest | Out-Null
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-contract-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    foreach ($case in @($expected.cases)) {
        $caseRoot = Join-Path $testRoot $case.id
        $sessions = Join-Path $caseRoot 'sessions'
        [void][IO.Directory]::CreateDirectory($sessions)
        $locked = $null
        try {
            $candidatePath = Join-Path $sessions 'contract.jsonl'
            if ([string]$case.scenario -ceq 'read-failure') {
                [IO.File]::WriteAllText($candidatePath, '{}')
                $locked = [IO.File]::Open($candidatePath, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            }
            else {
                $inputPath = Join-Path $contractRoot ([string]$case.input)
                Assert-Contract ([IO.File]::Exists($inputPath)) "missing case input: $($case.input)"
                [IO.File]::Copy($inputPath, $candidatePath)
                $validLines = 0
                $malformedLines = 0
                foreach ($line in @(Get-Content -LiteralPath $inputPath | Where-Object { $_.Trim().Length -gt 0 })) {
                    try { $null = $line | ConvertFrom-Json -ErrorAction Stop; $validLines++ }
                    catch { $malformedLines++ }
                }
                Assert-Contract ($validLines -eq [int]$case.fixtureStats.validJsonLines) "valid JSON line count changed for $($case.id)."
                Assert-Contract ($malformedLines -eq [int]$case.fixtureStats.malformedJsonLines) "malformed JSON line count changed for $($case.id)."
            }
            $snapshot = Get-CodexUsageSnapshot -DataDirectory $caseRoot -ReadOnly
            $now = [datetime]::Parse($case.nowUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
            $actual = ConvertTo-CanonicalContractState -Snapshot $snapshot -Now $now -CandidateFileCount 1
            $actualJson = $actual | ConvertTo-Json -Depth 20 -Compress
            $expectedJson = $case.expected | ConvertTo-Json -Depth 20 -Compress
            Assert-Contract ($actualJson -ceq $expectedJson) "full canonical snapshot changed for $($case.id).`nexpected: $expectedJson`nactual:   $actualJson"
        }
        finally {
            if ($null -ne $locked) { $locked.Dispose() }
        }
    }
}
finally {
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}

$themeCatalog = [IO.File]::ReadAllText((Join-Path $contractRoot 'theme-catalog.json')) | ConvertFrom-Json -ErrorAction Stop
$actualThemes = @(Get-WidgetThemes)
Assert-Contract (@($themeCatalog.themes).Count -eq 8 -and $actualThemes.Count -eq 8) 'both theme catalogs must contain eight themes.'
for ($index = 0; $index -lt 8; $index++) {
    $want = $themeCatalog.themes[$index]
    $got = $actualThemes[$index]
    Assert-Contract ($want.id -ceq $got.NameKey.Substring('theme.'.Length)) "theme id mismatch at index $index."
    Assert-Contract ($want.nameKey -ceq $got.NameKey -and $want.start -ceq $got.Start -and $want.end -ceq $got.End) "theme values mismatch at index $index."
    foreach ($languageCode in 'en-US', 'zh-CN', 'zh-TW', 'ja-JP', 'ko-KR') {
        $languagePack = [IO.File]::ReadAllText((Join-Path $package "locales\$languageCode.json")) | ConvertFrom-Json -ErrorAction Stop
        Assert-Contract ($null -ne $languagePack.strings.PSObject.Properties[$want.nameKey]) "missing $($want.nameKey) in $languageCode."
    }
}

Write-Output 'Contract self-test passed.'
