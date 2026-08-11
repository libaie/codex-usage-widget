param(
    [Parameter(Mandatory)][string]$PackageRoot,
    [switch]$RuntimeArchive
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
$personalPathPattern = '(?i)C:[\\/]+Users[\\/]+'
$tempPathPattern = '(?i)AppData[\\/]+Local[\\/]+Temp'

$commonRuntimePaths = @(
    'CodexUsageWidget.ps1', 'Start-CodexUsageWidget.cmd', 'Start-CodexUsageWidget.vbs',
    'VERSION', 'README.md', 'README.zh-CN.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'DESIGN.md',
    'docs\releasing.md', 'docs\releases\v1.1.0.md',
    'locales\en-US.json', 'locales\zh-CN.json', 'locales\zh-TW.json',
    'locales\ja-JP.json', 'locales\ko-KR.json',
    'assets\screenshots\widget-ring.png', 'assets\screenshots\widget-details.png',
    'assets\screenshots\widget-ring-macos.png', 'assets\screenshots\widget-details-macos.png',
    'fixtures\rate-limits.jsonl', 'fixtures\Test-Launcher.ps1', 'fixtures\Test-ReleasePackage.ps1'
)

function Fail-ReleasePackage([string]$Message) {
    [Console]::Error.WriteLine("Release package check failed: $Message")
    exit 1
}

$secretJsonKeys = @('password', 'token', 'api_key', 'secret')
function Find-ForbiddenJsonContent([AllowNull()][object]$Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) {
        if ($Value -match $personalPathPattern) { return 'personal Windows path' }
        if ($Value -match $tempPathPattern) { return 'temporary-directory path' }
        return $null
    }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($key in $Value.Keys) {
            if ($secretJsonKeys -icontains [string]$key) { return 'secret-like JSON property' }
            $reason = Find-ForbiddenJsonContent $Value[$key]
            if ($null -ne $reason) { return $reason }
        }
        return $null
    }
    if ($Value -is [array]) {
        foreach ($item in $Value) {
            $reason = Find-ForbiddenJsonContent $item
            if ($null -ne $reason) { return $reason }
        }
        return $null
    }
    foreach ($property in @($Value.PSObject.Properties | Where-Object MemberType -eq 'NoteProperty')) {
        if ($secretJsonKeys -icontains $property.Name) { return 'secret-like JSON property' }
        $reason = Find-ForbiddenJsonContent $property.Value
        if ($null -ne $reason) { return $reason }
    }
    return $null
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
if (-not [IO.Directory]::Exists($package)) { Fail-ReleasePackage 'package root is not a directory' }

$requiredPaths = @($commonRuntimePaths)
if (-not $RuntimeArchive) {
    $requiredPaths += @(
        'SECURITY.md', 'docs\press-kit.md', 'docs\qa-v1.1.0.md', 'docs\releases\v1.0.0.md',
        'assets\social-preview.png', 'fixtures\Test-Contract.ps1', 'fixtures\Test-WindowsDataBoundary.ps1',
        'fixtures\Test-WorkerStability.ps1', 'fixtures\Test-Bootstrap.ps1',
        'fixtures\contract\v1\schema.md', 'fixtures\contract\v1\expected-state.json',
        'fixtures\contract\v1\theme-catalog.json',
        'fixtures\contract\v1\inputs\all-malformed.jsonl', 'fixtures\contract\v1\inputs\cache-order.jsonl',
        'fixtures\contract\v1\inputs\demo.jsonl', 'fixtures\contract\v1\inputs\empty.jsonl',
        'fixtures\contract\v1\inputs\overflow.jsonl', 'fixtures\contract\v1\inputs\partial.jsonl',
        'fixtures\contract\v1\inputs\precision-and-tightest-window.jsonl',
        'fixtures\contract\v1\inputs\reset-boundary.jsonl', 'fixtures\contract\v1\inputs\unsupported.jsonl',
        'scripts\Build-Windows.ps1', 'windows\Bootstrap\Program.cs',
        'macos\CodexUsageWidget.xcodeproj\project.pbxproj',
        'macos\CodexUsageWidget.xcodeproj\xcshareddata\xcschemes\CodexUsageWidget.xcscheme',
        'macos\CodexUsageWidget\Info.plist', 'macos\CodexUsageWidget\App\main.swift',
        'macos\CodexUsageWidget\Core\UsageCore.swift', 'macos\CodexUsageWidget\UI\WidgetUI.swift',
        'macos\CodexUsageWidgetTests\CoreTests.swift', 'macos\CodexUsageWidgetTests\UIContractTests.swift',
        'macos\CodexUsageWidgetUITests\WidgetUITests.swift',
        '.github\workflows\ci.yml'
    )
}

$trackedPaths = @()
if ($RuntimeArchive) {
    $scanPaths = @([IO.Directory]::GetFiles($package, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object {
        $_.Substring($package.TrimEnd('\').Length + 1)
    })
}
else {
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $scanPaths = @(& git -C $package -c core.quotepath=false ls-files --cached --others --exclude-standard -- 2>$null)
        $candidateExitCode = $LASTEXITCODE
        $trackedPaths = @(& git -C $package -c core.quotepath=false ls-files --cached -- 2>$null)
        $trackedExitCode = $LASTEXITCODE
    }
    finally { $ErrorActionPreference = $savedErrorActionPreference }
    if ($candidateExitCode -ne 0) { Fail-ReleasePackage 'git could not enumerate repository candidates' }
    if ($trackedExitCode -ne 0) { Fail-ReleasePackage 'git could not enumerate tracked repository files' }
    $scanPaths = @($scanPaths | ForEach-Object { $_ -replace '/', '\' })
    $trackedPaths = @($trackedPaths | ForEach-Object { $_ -replace '/', '\' })
}

$missingPaths = @($requiredPaths | Where-Object {
    ($RuntimeArchive -and $scanPaths -cnotcontains $_) -or
    (-not $RuntimeArchive -and $trackedPaths -cnotcontains $_) -or
    -not [IO.File]::Exists((Join-Path $package $_))
})
if ($missingPaths.Count -gt 0) { Fail-ReleasePackage ('missing required file(s): ' + ($missingPaths -join ', ')) }

if (-not $RuntimeArchive) {
    $socialPreviewPath = 'assets\social-preview.png'
    try {
        Add-Type -AssemblyName System.Drawing -ErrorAction Stop
        $socialPreview = [Drawing.Image]::FromFile((Join-Path $package $socialPreviewPath))
    }
    catch { Fail-ReleasePackage "invalid image file: $socialPreviewPath" }
    try {
        $socialPreviewWidth = $socialPreview.Width
        $socialPreviewHeight = $socialPreview.Height
    }
    finally { $socialPreview.Dispose() }
    if ($socialPreviewWidth -lt 640 -or $socialPreviewHeight -lt 320 -or
        $socialPreviewWidth -ne 2 * $socialPreviewHeight) {
        Fail-ReleasePackage "invalid image dimensions: $socialPreviewPath"
    }
    if ([IO.FileInfo]::new((Join-Path $package $socialPreviewPath)).Length -ge 1048576) {
        Fail-ReleasePackage "image file is too large: $socialPreviewPath"
    }
}

$commonReadmeRequirements = @(
    'Start-CodexUsageWidget.vbs', 'zh-CN', 'zh-TW', 'en-US', 'ja-JP', 'ko-KR', 'LICENSE',
    'assets/screenshots/widget-ring.png', 'assets/screenshots/widget-details.png',
    'assets/screenshots/widget-ring-macos.png', 'assets/screenshots/widget-details-macos.png',
    'CodexUsageWidget-v1.1.0-windows.exe', 'CodexUsageWidget-v1.1.0-windows.zip',
    'CodexUsageWidget-v1.1.0-macos.dmg', 'CONTRIBUTING.md', 'DESIGN.md', 'docs/releasing.md',
    'docs/releases/v1.1.0.md', '-Demo', '--demo', 'Developer ID'
)
$zhIndependentProject = ([char[]](0x72EC, 0x7ACB, 0x793E, 0x533A, 0x9879, 0x76EE) -join '')
$zhUnofficialProject = ([char[]](0x4E0D, 0x662F) -join '') + ' OpenAI ' + [char]0x6216 + ' Codex ' +
    ([char[]](0x5B98, 0x65B9, 0x9879, 0x76EE) -join '')
$zhLocalSessionObservations = ([char[]](0x672C, 0x673A, 0x4F1A, 0x8BDD, 0x89C2, 0x6D4B) -join '')
$zhNotOfficialBillingOrAccountData = ([char[]](
    0x4E0D, 0x662F, 0x5B98, 0x65B9, 0x8D26, 0x5355, 0x6216, 0x8D26, 0x6237, 0x6570, 0x636E
) -join '')
$readmeRequirements = @{
    'README.md' = @(
        'README.zh-CN.md', 'independent community project', 'not an official OpenAI or Codex project',
        'local session observations', 'not official billing or account data'
    )
    'README.zh-CN.md' = @(
        'README.md', $zhIndependentProject, $zhUnofficialProject,
        $zhLocalSessionObservations, $zhNotOfficialBillingOrAccountData
    )
}
foreach ($readmePath in $readmeRequirements.Keys) {
    $readmeFullPath = Join-Path $package $readmePath
    $readmeContent = [IO.File]::ReadAllText($readmeFullPath)
    foreach ($requiredText in @($commonReadmeRequirements + $readmeRequirements[$readmePath])) {
        if ($readmeContent.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
            Fail-ReleasePackage "missing '$requiredText' in file: $readmePath"
        }
    }
    if ([regex]::Matches($readmeContent, 'reminders\.json', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -lt 2) {
        Fail-ReleasePackage "missing reminders.json documentation from data-location or privacy details in file: $readmePath"
    }

    $relativeTargets = @([regex]::Matches($readmeContent, '!?\[[^\]]*\]\((?<target>[^)\s]+)\)') | ForEach-Object {
        $_.Groups['target'].Value.Trim([char[]]'<>')
    })
    $relativeTargets += @([regex]::Matches($readmeContent, '<img\b[^>]*\bsrc\s*=\s*"(?<target>[^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object {
        $_.Groups['target'].Value
    })
    foreach ($target in $relativeTargets) {
        if ($target -match '^(?:[A-Za-z][A-Za-z0-9+.-]*:|//|#)') { continue }
        $targetPath = [Uri]::UnescapeDataString(($target -split '[?#]', 2)[0])
        try {
            $targetFullPath = [IO.Path]::GetFullPath((Join-Path (Split-Path $readmeFullPath) ($targetPath -replace '/', '\')))
        }
        catch { Fail-ReleasePackage "invalid relative README target '$target' in file: $readmePath" }
        $packagePrefix = $package.TrimEnd('\') + '\'
        if (-not $targetFullPath.StartsWith($packagePrefix, [StringComparison]::OrdinalIgnoreCase)) {
            Fail-ReleasePackage "relative README target escapes package: '$target' in file: $readmePath"
        }
        $packageTarget = $targetFullPath.Substring($packagePrefix.Length)
        if (-not [IO.File]::Exists($targetFullPath)) {
            Fail-ReleasePackage "missing relative README target '$target' in file: $readmePath"
        }
        if (($RuntimeArchive -and $scanPaths -cnotcontains $packageTarget) -or
            (-not $RuntimeArchive -and $trackedPaths -cnotcontains $packageTarget)) {
            Fail-ReleasePackage "relative README target is not packaged: '$target' in file: $readmePath"
        }
    }
}

if (-not $RuntimeArchive) {
    $releaseNotesContent = [IO.File]::ReadAllText((Join-Path $package 'docs\releases\v1.0.0.md'))
    if ([regex]::Matches($releaseNotesContent, 'reminders\.json', [Text.RegularExpressions.RegexOptions]::IgnoreCase).Count -lt 2) {
        Fail-ReleasePackage 'missing English or Chinese reminders.json privacy details in file: docs\releases\v1.0.0.md'
    }
    $zhFiveLanguages = ([char[]](0x4E94, 0x79CD, 0x8BED, 0x8A00) -join '')
    $documentationRequirements = @{
        'CONTRIBUTING.md' = @('Test-Contract.ps1', 'Build-Windows.ps1', 'xcodebuild', '-Demo', '--demo', 'CODE_SIGNING_ALLOWED=NO')
        'DESIGN.md' = @('local-session-observation', '-ScanWorker', '--scan-worker', 'cache-token-ledger.json')
        'docs\releasing.md' = @('Developer ID Application', 'notar', 'Gatekeeper', 'manifest', 'CodexUsageWidget-v1.1.0-macos.dmg')
        'docs\releases\v1.1.0.md' = @('Windows', 'macOS', 'CodexUsageWidget-v1.1.0-windows.exe', 'CodexUsageWidget-v1.1.0-macos.dmg', 'Developer ID')
        'docs\press-kit.md' = @('Windows', 'macOS', 'five languages', $zhFiveLanguages)
        'docs\qa-v1.1.0.md' = @('32/32', 'P9 E2E', 'Test-WorkerStability.ps1', '-Demo', '--demo')
        'CHANGELOG.md' = @('## 1.1.0', 'macOS', '-Demo', '--demo')
        '.github\workflows\ci.yml' = @('workflow_dispatch', 'candidate_sha', 'candidate-manifest.json', 'actions/download-artifact@v4', 'artifact-id', 'artifact-digest')
    }
    foreach ($documentationPath in $documentationRequirements.Keys) {
        $documentationContent = [IO.File]::ReadAllText((Join-Path $package $documentationPath))
        foreach ($requiredText in $documentationRequirements[$documentationPath]) {
            if ($documentationContent.IndexOf($requiredText, [StringComparison]::OrdinalIgnoreCase) -lt 0) {
                Fail-ReleasePackage "missing '$requiredText' in file: $documentationPath"
            }
        }
    }
}

if ($RuntimeArchive) {
    $unexpectedPaths = @($scanPaths | Where-Object { $commonRuntimePaths -cnotcontains $_ })
    if ($unexpectedPaths.Count -gt 0) { Fail-ReleasePackage ('unexpected runtime file(s): ' + ($unexpectedPaths -join ', ')) }
}

foreach ($relativePath in $scanPaths) {
    if ($relativePath -match '(?i)(^|[\\/])(backups|dist|sessions)([\\/]|$)' -or
        $relativePath -match '(?i)(^|[\\/])(preferences\.json|cache-token-ledger\.json|reminders\.json)$') {
        Fail-ReleasePackage "forbidden path: $relativePath"
    }

    if ([IO.Path]::GetExtension($relativePath) -ieq '.png') { continue }

    $fullPath = Join-Path $package $relativePath
    $content = [IO.File]::ReadAllText($fullPath)
    if ($content -match $personalPathPattern) { Fail-ReleasePackage "personal Windows path in file: $relativePath" }
    if ($content -match $tempPathPattern) { Fail-ReleasePackage "temporary-directory path in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{30,}') { Fail-ReleasePackage "GitHub token pattern in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}') { Fail-ReleasePackage "GitHub token pattern in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}') { Fail-ReleasePackage "API token pattern in file: $relativePath" }
    if ($content -match '(?i)-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----') { Fail-ReleasePackage "private-key header in file: $relativePath" }
    $extension = [IO.Path]::GetExtension($relativePath)
    if ($extension -iin @('.json', '.jsonl')) {
        $jsonTexts = if ($extension -ieq '.json') { @($content) } else { @($content -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 }) }
        foreach ($jsonText in $jsonTexts) {
            try { $jsonValue = $jsonText | ConvertFrom-Json }
            catch {
                $propertyPattern = '(?<name>"(?:\\["\\/bfnrt]|\\u[0-9A-Fa-f]{4}|[^"\\\x00-\x1F])*")\s*:'
                foreach ($propertyMatch in [regex]::Matches($jsonText, $propertyPattern)) {
                    try {
                        $propertyObject = '{' + $propertyMatch.Groups['name'].Value + ':null}' | ConvertFrom-Json
                        $propertyName = @($propertyObject.PSObject.Properties)[0].Name
                    }
                    catch { continue }
                    if ($secretJsonKeys -icontains $propertyName) {
                        Fail-ReleasePackage "secret-like JSON property in file: $relativePath"
                    }
                }
                continue
            }
            $reason = Find-ForbiddenJsonContent $jsonValue
            if ($null -ne $reason) { Fail-ReleasePackage "$reason in file: $relativePath" }
        }
    }
}

([char[]](0x5F00, 0x6E90, 0x5305, 0x68C0, 0x67E5, 0x901A, 0x8FC7, 0x3002) -join '')
