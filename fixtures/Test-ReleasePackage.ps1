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
    'README.md', 'README.zh-CN.md', 'LICENSE', 'CHANGELOG.md',
    'locales\en-US.json', 'locales\zh-CN.json', 'locales\zh-TW.json',
    'locales\ja-JP.json', 'locales\ko-KR.json',
    'assets\screenshots\widget-ring.png', 'assets\screenshots\widget-details.png',
    'fixtures\rate-limits.jsonl', 'fixtures\Test-Launcher.ps1', 'fixtures\Test-ReleasePackage.ps1'
)

function Fail-ReleasePackage([string]$Message) { throw "Release package check failed: $Message" }

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
if (-not [IO.Directory]::Exists($package)) { Fail-ReleasePackage "package root is not a directory: $package" }

$requiredPaths = @($commonRuntimePaths)
if (-not $RuntimeArchive) {
    $requiredPaths += @('SECURITY.md', 'CONTRIBUTING.md', 'docs\press-kit.md', 'docs\releases\v1.0.0.md')
}

if ($RuntimeArchive) {
    $scanPaths = @([IO.Directory]::GetFiles($package, '*', [IO.SearchOption]::AllDirectories) | ForEach-Object {
        $_.Substring($package.TrimEnd('\').Length + 1)
    })
}
else {
    $scanPaths = @(& git -C $package -c core.quotepath=false ls-files --cached --others --exclude-standard --)
    if ($LASTEXITCODE -ne 0) { Fail-ReleasePackage "git could not enumerate repository candidates under $package" }
    $scanPaths = @($scanPaths | ForEach-Object { $_ -replace '/', '\' })
}

$missingPaths = @($requiredPaths | Where-Object {
    $scanPaths -notcontains $_ -or -not [IO.File]::Exists((Join-Path $package $_))
})
if ($missingPaths.Count -gt 0) { Fail-ReleasePackage ('missing required file(s): ' + ($missingPaths -join ', ')) }

$commonReadmeRequirements = @(
    'Start-CodexUsageWidget.vbs', 'zh-CN', 'zh-TW', 'en-US', 'ja-JP', 'ko-KR', 'LICENSE',
    'assets/screenshots/widget-ring.png', 'assets/screenshots/widget-details.png'
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

    $relativeTargets = @([regex]::Matches($readmeContent, '!?\[[^\]]*\]\((?<target>[^)\s]+)\)') | ForEach-Object {
        $_.Groups['target'].Value.Trim([char[]]'<>')
    })
    $relativeTargets += @([regex]::Matches($readmeContent, '<img\b[^>]*\bsrc\s*=\s*"(?<target>[^"]+)"', [Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object {
        $_.Groups['target'].Value
    })
    foreach ($target in $relativeTargets) {
        if ($target -match '^(?:[A-Za-z][A-Za-z0-9+.-]*:|//|#)') { continue }
        $targetPath = [Uri]::UnescapeDataString(($target -split '[?#]', 2)[0])
        if (-not [IO.File]::Exists((Join-Path (Split-Path $readmeFullPath) ($targetPath -replace '/', '\')))) {
            Fail-ReleasePackage "missing relative README target '$target' in file: $readmePath"
        }
    }
}

if ($RuntimeArchive) {
    $unexpectedPaths = @($scanPaths | Where-Object { $commonRuntimePaths -notcontains $_ })
    if ($unexpectedPaths.Count -gt 0) { Fail-ReleasePackage ('unexpected runtime file(s): ' + ($unexpectedPaths -join ', ')) }
}

foreach ($relativePath in $scanPaths) {
    if ($relativePath -match '(?i)(^|[\\/])(backups|dist|sessions)([\\/]|$)' -or
        $relativePath -match '(?i)(^|[\\/])(preferences\.json|cache-token-ledger\.json|reminders\.json)$') {
        Fail-ReleasePackage "forbidden path: $relativePath"
    }

    if ([IO.Path]::GetExtension($relativePath) -notin @('.ps1', '.vbs', '.cmd', '.md', '.json', '.jsonl', '.gitignore')) { continue }
    if ($relativePath -ieq 'fixtures\Test-ReleasePackage.ps1') { continue }

    $fullPath = Join-Path $package $relativePath
    $content = [IO.File]::ReadAllText($fullPath)
    if ($content -match $personalPathPattern) { Fail-ReleasePackage "personal Windows path in file: $relativePath" }
    if ($content -match $tempPathPattern) { Fail-ReleasePackage "temporary-directory path in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_])ghp_[A-Za-z0-9]{30,}') { Fail-ReleasePackage "GitHub token pattern in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_])github_pat_[A-Za-z0-9_]{20,}') { Fail-ReleasePackage "GitHub token pattern in file: $relativePath" }
    if ($content -match '(?i)(?<![A-Za-z0-9_-])sk-[A-Za-z0-9_-]{20,}') { Fail-ReleasePackage "API token pattern in file: $relativePath" }
    if ($content -match '(?i)-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----') { Fail-ReleasePackage "private-key header in file: $relativePath" }
    $extension = [IO.Path]::GetExtension($relativePath)
    if ($extension -in @('.json', '.jsonl')) {
        $jsonTexts = if ($extension -eq '.json') { @($content) } else { @($content -split '\r?\n' | Where-Object { $_.Trim().Length -gt 0 }) }
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
