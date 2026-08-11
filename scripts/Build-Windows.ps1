param(
    [string]$PackageRoot,
    [string]$OutputDirectory
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

if ([string]::IsNullOrWhiteSpace($PackageRoot)) { $PackageRoot = Split-Path -Parent $PSScriptRoot }
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $PackageRoot 'dist\candidate' }

function Get-FileHashLower([string]$Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return -join @($sha.ComputeHash($stream) | ForEach-Object { $_.ToString('x2') }) }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$version = [IO.File]::ReadAllText((Join-Path $package 'VERSION')).Trim()
if ($version -cne '1.1.0') { throw 'VERSION must be 1.1.0.' }
$runtimePaths = @(
    'CodexUsageWidget.ps1', 'Start-CodexUsageWidget.cmd', 'Start-CodexUsageWidget.vbs', 'VERSION',
    'README.md', 'README.zh-CN.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'DESIGN.md',
    'docs\releasing.md', 'docs\releases\v1.1.0.md',
    'locales\en-US.json', 'locales\zh-CN.json', 'locales\zh-TW.json',
    'locales\ja-JP.json', 'locales\ko-KR.json',
    'assets\screenshots\widget-ring.png', 'assets\screenshots\widget-details.png',
    'assets\screenshots\widget-ring-macos.png', 'assets\screenshots\widget-details-macos.png',
    'fixtures\rate-limits.jsonl', 'fixtures\Test-Launcher.ps1', 'fixtures\Test-ReleasePackage.ps1'
)
foreach ($relative in $runtimePaths) {
    $path = Join-Path $package $relative
    if (-not [IO.File]::Exists($path) -or (([IO.FileInfo]$path).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Missing or unsafe runtime file: $relative"
    }
}

$output = [IO.Path]::GetFullPath($OutputDirectory)
[void][IO.Directory]::CreateDirectory($output)
$buildRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-windows-build-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($buildRoot)
    Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $zipName = "CodexUsageWidget-v$version-windows.zip"
    $exeName = "CodexUsageWidget-v$version-windows.exe"
    $tempZip = Join-Path $buildRoot $zipName
    $stream = [IO.File]::Open($tempZip, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
        try {
            foreach ($relative in $runtimePaths) {
                $entryName = 'CodexUsageWidget/' + $relative.Replace('\', '/')
                $entry = $archive.CreateEntry($entryName, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $input = [IO.File]::OpenRead((Join-Path $package $relative))
                $destination = $entry.Open()
                try { $input.CopyTo($destination) }
                finally { $destination.Dispose(); $input.Dispose() }
            }
        }
        finally { $archive.Dispose() }
    }
    finally { $stream.Dispose() }

    $manifestLines = [Collections.Generic.List[string]]::new()
    $manifestLines.Add("VERSION`t$version")
    $manifestLines.Add("ZIP`t$(([IO.FileInfo]$tempZip).Length)`t$(Get-FileHashLower $tempZip)")
    foreach ($relative in $runtimePaths) {
        $path = Join-Path $package $relative
        $entryName = 'CodexUsageWidget/' + $relative.Replace('\', '/')
        $manifestLines.Add("FILE`t$entryName`t$(([IO.FileInfo]$path).Length)`t$(Get-FileHashLower $path)")
    }
    $manifest = Join-Path $buildRoot 'payload-manifest.txt'
    [IO.File]::WriteAllText($manifest, (($manifestLines -join "`n") + "`n"), [Text.UTF8Encoding]::new($false))

    $csc = @(
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'),
        (Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe')
    ) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
    if ($null -eq $csc) { throw 'The .NET Framework C# compiler was not found.' }
    $tempExe = Join-Path $buildRoot $exeName
    $compilerArguments = @(
        '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+',
        ('/out:' + $tempExe),
        ('/resource:' + $tempZip + ',CodexUsageWidget.PayloadZip'),
        ('/resource:' + $manifest + ',CodexUsageWidget.PayloadManifest'),
        '/reference:System.dll', '/reference:System.Core.dll',
        '/reference:System.IO.Compression.dll', '/reference:System.IO.Compression.FileSystem.dll',
        '/reference:System.Windows.Forms.dll',
        (Join-Path $package 'windows\Bootstrap\Program.cs')
    )
    & $csc $compilerArguments
    if ($LASTEXITCODE -ne 0 -or -not [IO.File]::Exists($tempExe)) { throw 'The Windows bootstrap compiler failed.' }

    $finalZip = Join-Path $output $zipName
    $finalExe = Join-Path $output $exeName
    [IO.File]::Copy($tempZip, $finalZip, $true)
    [IO.File]::Copy($tempExe, $finalExe, $true)
    foreach ($path in $finalZip, $finalExe) {
        $checksum = (Get-FileHashLower $path) + '  ' + [IO.Path]::GetFileName($path) + "`r`n"
        [IO.File]::WriteAllText(($path + '.sha256'), $checksum, [Text.Encoding]::ASCII)
    }
}
finally {
    $resolvedBuild = [IO.Path]::GetFullPath($buildRoot)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (-not $resolvedBuild.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolvedBuild) -cnotmatch '^CodexUsageWidget-windows-build-[0-9a-f]{32}$') {
        throw 'Unsafe Windows build cleanup target.'
    }
    if ([IO.Directory]::Exists($resolvedBuild)) { [IO.Directory]::Delete($resolvedBuild, $true) }
}
