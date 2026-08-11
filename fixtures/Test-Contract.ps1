param(
    [Parameter(Mandatory)][string]$PackageRoot
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false

function Assert-Contract([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Contract assertion failed: $Message" }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$contractRoot = Join-Path $package 'fixtures\contract\v1'
$requiredPaths = @(
    'VERSION',
    'fixtures\contract\v1\schema.md',
    'fixtures\contract\v1\theme-catalog.json',
    'fixtures\contract\v1\expected-state.json',
    'fixtures\contract\v1\inputs\precision-and-tightest-window.jsonl',
    'fixtures\contract\v1\inputs\demo.jsonl',
    'fixtures\contract\v1\inputs\partial.jsonl',
    'fixtures\contract\v1\inputs\unsupported.jsonl',
    'fixtures\contract\v1\inputs\all-malformed.jsonl',
    'fixtures\contract\v1\inputs\empty.jsonl',
    'fixtures\contract\v1\inputs\reset-boundary.jsonl',
    'fixtures\contract\v1\inputs\overflow.jsonl',
    'fixtures\contract\v1\inputs\cache-order.jsonl'
)
foreach ($relativePath in $requiredPaths) {
    Assert-Contract ([IO.File]::Exists((Join-Path $package $relativePath))) "missing required contract file: $relativePath"
}

$version = [IO.File]::ReadAllText((Join-Path $package 'VERSION')).Trim()
Assert-Contract ($version -ceq '1.1.0') 'VERSION must be exactly 1.1.0.'

$expected = [IO.File]::ReadAllText((Join-Path $contractRoot 'expected-state.json')) | ConvertFrom-Json -ErrorAction Stop
Assert-Contract ($expected.schemaVersion -eq 1) 'expected-state schemaVersion must be 1.'
Assert-Contract ($expected.sourceKind -ceq 'local-session-observation') 'sourceKind must be local-session-observation.'
Assert-Contract (@($expected.cases).Count -eq 9) 'the v1 contract must contain nine reviewed cases.'

foreach ($case in @($expected.cases)) {
    $inputPath = Join-Path $contractRoot $case.input
    Assert-Contract ([IO.File]::Exists($inputPath)) "missing case input: $($case.input)"
    $validLines = 0
    $malformedLines = 0
    foreach ($line in @(Get-Content -LiteralPath $inputPath | Where-Object { $_.Trim().Length -gt 0 })) {
        try { $null = $line | ConvertFrom-Json -ErrorAction Stop; $validLines++ }
        catch { $malformedLines++ }
    }
    Assert-Contract ($validLines -eq [int]$case.fixtureStats.validJsonLines) "valid JSON line count changed for $($case.id)."
    Assert-Contract ($malformedLines -eq [int]$case.fixtureStats.malformedJsonLines) "malformed JSON line count changed for $($case.id)."
}

. (Join-Path $package 'CodexUsageWidget.ps1') -SelfTest | Out-Null

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

$precisionCase = @($expected.cases | Where-Object id -eq 'precision-and-tightest-window')[0]
$precisionEvents = @(
    Get-Content -LiteralPath (Join-Path $contractRoot $precisionCase.input) |
        Where-Object { $_.Trim().Length -gt 0 } |
        ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop }
)
$state = Get-NewestUsageState -Events $precisionEvents
Assert-Contract ($null -ne $state) 'precision fixture must produce a usage state.'
$current = Get-CurrentLimitState -State $state -Now ([datetime]::Parse($precisionCase.nowUtc, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind))
Assert-Contract ($current.Name -ceq $precisionCase.expected.selectedWindow) 'the tightest unexpired window must be selected.'
$remaining = [decimal]$current.RemainingPercent
Assert-Contract ($remaining.ToString('F1', [Globalization.CultureInfo]::InvariantCulture) -ceq $precisionCase.expected.remainingPercent) 'remaining percentage changed.'
$details = $state.TokenDetails
foreach ($propertyName in 'CumulativeTokens', 'CacheHitTokens', 'CacheMissTokens', 'ContextTokens', 'ContextLimit') {
    $expectedName = $propertyName.Substring(0, 1).ToLowerInvariant() + $propertyName.Substring(1)
    Assert-Contract ([string]$details.$propertyName -ceq [string]$precisionCase.expected.$expectedName) "$propertyName lost integer precision."
}
foreach ($propertyName in 'ContextPercent', 'InputPercent', 'OutputPercent', 'ReasoningOutputPercent') {
    $expectedName = $propertyName.Substring(0, 1).ToLowerInvariant() + $propertyName.Substring(1)
    $actual = ([decimal]$details.$propertyName).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
    Assert-Contract ($actual -ceq [string]$precisionCase.expected.$expectedName) "$propertyName changed."
}

Write-Output 'Contract self-test passed.'
