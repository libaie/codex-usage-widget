param([Parameter(Mandatory)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

function Assert-Bootstrap([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "Bootstrap assertion failed: $Message" }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$source = Join-Path $package 'windows\Bootstrap\Program.cs'
$build = Join-Path $package 'scripts\Build-Windows.ps1'
Assert-Bootstrap ([IO.File]::Exists($source)) 'missing windows/Bootstrap/Program.cs.'
Assert-Bootstrap ([IO.File]::Exists($build)) 'missing scripts/Build-Windows.ps1.'

$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('CodexUsageWidget-bootstrap-' + [guid]::NewGuid().ToString('N'))
try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build -OutputDirectory $testRoot
    Assert-Bootstrap ($LASTEXITCODE -eq 0) 'the Windows build entry failed.'

    $exe = Join-Path $testRoot 'CodexUsageWidget-v1.1.0-windows.exe'
    $zip = Join-Path $testRoot 'CodexUsageWidget-v1.1.0-windows.zip'
    $exeChecksum = $exe + '.sha256'
    $zipChecksum = $zip + '.sha256'
    foreach ($path in $exe, $zip, $exeChecksum, $zipChecksum) {
        Assert-Bootstrap ([IO.File]::Exists($path) -and ([IO.FileInfo]$path).Length -gt 0) "missing build output: $([IO.Path]::GetFileName($path))."
    }

    foreach ($pair in @(@($exe, $exeChecksum), @($zip, $zipChecksum))) {
        $hash = (Get-FileHash -LiteralPath $pair[0] -Algorithm SHA256).Hash.ToLowerInvariant()
        $expectedChecksum = $hash + '  ' + [IO.Path]::GetFileName($pair[0]) + "`r`n"
        Assert-Bootstrap ([IO.File]::ReadAllText($pair[1], [Text.Encoding]::ASCII) -ceq $expectedChecksum) `
            "invalid checksum file: $([IO.Path]::GetFileName($pair[1]))."
    }

    $assembly = [Reflection.Assembly]::Load([IO.File]::ReadAllBytes($exe))
    $payloadStream = $assembly.GetManifestResourceStream('CodexUsageWidget.PayloadZip')
    Assert-Bootstrap ($null -ne $payloadStream -and $payloadStream.Length -le [int]::MaxValue) 'missing embedded payload.'
    try {
        $embeddedPayload = [byte[]]::new([int]$payloadStream.Length)
        $offset = 0
        while ($offset -lt $embeddedPayload.Length) {
            $read = $payloadStream.Read($embeddedPayload, $offset, $embeddedPayload.Length - $offset)
            Assert-Bootstrap ($read -gt 0) 'the embedded payload was truncated.'
            $offset += $read
        }
    }
    finally { $payloadStream.Dispose() }
    $publicPayload = [IO.File]::ReadAllBytes($zip)
    Assert-Bootstrap ([Collections.StructuralComparisons]::StructuralEqualityComparer.Equals($embeddedPayload, $publicPayload)) `
        'the embedded payload differs from the public ZIP.'

    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    $runtimeRoot = Join-Path $testRoot 'runtime'
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $runtimeRoot)
    $releaseOutput = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $package 'fixtures\Test-ReleasePackage.ps1') `
        -PackageRoot (Join-Path $runtimeRoot 'CodexUsageWidget') -RuntimeArchive 2>&1
    Assert-Bootstrap ($LASTEXITCODE -eq 0) 'the public ZIP failed the runtime release-package check.'

    $stateRoot = Join-Path $testRoot 'state'
    [void][IO.Directory]::CreateDirectory($stateRoot)
    $stateFiles = @('preferences.json', 'cache-token-ledger.json', 'reminders.json')
    $stateBytes = @{}
    foreach ($name in $stateFiles) {
        $statePath = Join-Path $stateRoot $name
        [IO.File]::WriteAllText($statePath, "sentinel-$name", [Text.UTF8Encoding]::new($false))
        $stateBytes[$name] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath))
    }

    $expectedOutput = -join @([char]0x5F15, [char]0x5BFC, [char]0x7A0B, [char]0x5E8F, [char]0x81EA, [char]0x68C0, [char]0x901A, [char]0x8FC7, [char]0x3002)
    $processes = [Collections.Generic.List[Diagnostics.Process]]::new()
    try {
        $savedLocalAppData = $env:LOCALAPPDATA
        try {
            $env:LOCALAPPDATA = $stateRoot
            foreach ($unused in 1..2) {
                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $exe
                $startInfo.Arguments = '--self-test'
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $processes.Add([Diagnostics.Process]::Start($startInfo))
            }
        }
        finally { $env:LOCALAPPDATA = $savedLocalAppData }
        Start-Sleep -Milliseconds 50
        $timer = [Diagnostics.Stopwatch]::StartNew()
        foreach ($process in $processes) {
            $process.Refresh()
            Assert-Bootstrap ($process.MainWindowHandle -eq 0) 'bootstrap self-test opened a visible window.'
            $remaining = [Math]::Max(1, 30000 - [int]$timer.ElapsedMilliseconds)
            $completed = $process.WaitForExit($remaining)
            Assert-Bootstrap $completed 'concurrent bootstrap self-tests exceeded 30 seconds.'
            $stdout = $process.StandardOutput.ReadToEnd().Trim()
            $stderr = $process.StandardError.ReadToEnd()
            Assert-Bootstrap ($process.ExitCode -eq 0 -and $stdout -ceq $expectedOutput -and $stderr.Length -eq 0) `
                'bootstrap self-test failed or emitted unsafe diagnostics.'
        }
    }
    finally {
        foreach ($process in $processes) {
            if (-not $process.HasExited) { try { $process.Kill(); $process.WaitForExit() } catch { } }
            $process.Dispose()
        }
    }
    foreach ($name in $stateFiles) {
        $statePath = Join-Path $stateRoot $name
        Assert-Bootstrap ([Convert]::ToBase64String([IO.File]::ReadAllBytes($statePath)) -ceq $stateBytes[$name]) `
            "bootstrap self-test changed user state: $name."
    }
}
finally {
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    Assert-Bootstrap ($resolved.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -cmatch '^CodexUsageWidget-bootstrap-[0-9a-f]{32}$') 'unsafe bootstrap cleanup target.'
    if ([IO.Directory]::Exists($resolved)) { [IO.Directory]::Delete($resolved, $true) }
}

Write-Output 'Bootstrap integration self-test passed.'
