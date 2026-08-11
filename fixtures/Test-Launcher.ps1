param([Parameter(Mandatory)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)

trap {
    $message = $_.Exception.Message
    if (-not $message.StartsWith('[launcher/', [StringComparison]::Ordinal)) {
        $message = '[launcher/environment] Hidden-launch verification failed; retry in Windows PowerShell 5.1 with Windows Script Host enabled.'
    }
    [Console]::Error.WriteLine($message)
    exit 1
}

function Assert-Launcher([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$budget = [Diagnostics.Stopwatch]::StartNew()
$operationBudgetMilliseconds = 10000
$totalBudgetMilliseconds = 15000
function Get-RemainingMilliseconds([int]$Limit, [int]$Maximum) {
    $remaining = $Limit - [int]$budget.ElapsedMilliseconds
    if ($remaining -le 0) { throw '[launcher/timeout] Hidden-launch verification exceeded its fixed budget.' }
    return [Math]::Min($remaining, $Maximum)
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$separator = [IO.Path]::DirectorySeparatorChar
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($separator)
$testRoot = Join-Path $tempParent ('CodexUsageWidget-launcher-' + [guid]::NewGuid().ToString('N'))
$hostProcess = $null
$probeProcess = $null
$visibleConhostBefore = @(
    Get-Process conhost -ErrorAction SilentlyContinue |
        Where-Object MainWindowHandle -ne 0 |
        ForEach-Object Id
)

try {
    [void][IO.Directory]::CreateDirectory($testRoot)
    Copy-Item -LiteralPath (Join-Path $package 'Start-CodexUsageWidget.cmd') -Destination $testRoot
    Copy-Item -LiteralPath (Join-Path $package 'Start-CodexUsageWidget.vbs') -Destination $testRoot
    [IO.File]::WriteAllText(
        (Join-Path $testRoot 'CodexUsageWidget.ps1'),
        "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'probe.pid'), [string]`$PID)`r`nStart-Sleep -Seconds 30`r`n",
        [Text.Encoding]::ASCII)

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:SystemRoot 'System32\wscript.exe'
    $startInfo.Arguments = '//B //NoLogo "' + (Join-Path $testRoot 'Start-CodexUsageWidget.vbs') + '"'
    $startInfo.WorkingDirectory = $testRoot
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $hostProcess = [Diagnostics.Process]::Start($startInfo)
    Assert-Launcher ($null -ne $hostProcess) '[launcher/start] Windows Script Host could not be started.'
    $hostCompleted = $hostProcess.WaitForExit((Get-RemainingMilliseconds $operationBudgetMilliseconds 5000))
    if (-not $hostCompleted) { try { $hostProcess.Kill(); [void]$hostProcess.WaitForExit(500) } catch { } }
    Assert-Launcher $hostCompleted '[launcher/timeout] Windows Script Host did not exit within budget.'
    Assert-Launcher ($hostProcess.ExitCode -eq 0) '[launcher/start] Windows Script Host returned a failure exit code.'

    $pidFile = Join-Path $testRoot 'probe.pid'
    while (-not [IO.File]::Exists($pidFile)) {
        [void](Get-RemainingMilliseconds $operationBudgetMilliseconds 100)
        Start-Sleep -Milliseconds 100
    }
    $probePid = 0
    Assert-Launcher ([int]::TryParse([IO.File]::ReadAllText($pidFile), [ref]$probePid) -and $probePid -gt 0) `
        '[launcher/probe] The launched probe did not write a valid process id.'
    $probeProcess = Get-Process -Id $probePid -ErrorAction Stop
    $probeProcess.Refresh()
    Assert-Launcher ($probeProcess.ProcessName -ieq 'powershell' -and $probeProcess.MainWindowHandle -eq 0) `
        '[launcher/window] The launched widget has a visible PowerShell window.'

    $newVisibleConhost = @(
        Get-Process conhost -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowHandle -ne 0 -and $visibleConhostBefore -notcontains $_.Id }
    )
    Assert-Launcher ($newVisibleConhost.Count -eq 0) '[launcher/window] The launched widget has a visible console host.'
    Assert-Launcher $hostProcess.HasExited '[launcher/process] Windows Script Host is still running.'
}
finally {
    if ($null -ne $probeProcess) {
        if (-not $probeProcess.HasExited) { try { $probeProcess.Kill() } catch { } }
        try { [void]$probeProcess.WaitForExit((Get-RemainingMilliseconds $totalBudgetMilliseconds 2000)) } catch { }
        $probeProcess.Dispose()
    }
    if ($null -ne $hostProcess) {
        if (-not $hostProcess.HasExited) { try { $hostProcess.Kill() } catch { } }
        try { [void]$hostProcess.WaitForExit((Get-RemainingMilliseconds $totalBudgetMilliseconds 1000)) } catch { }
        $hostProcess.Dispose()
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    Assert-Launcher ($resolvedTestRoot.StartsWith($tempParent + $separator, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolvedTestRoot) -cmatch '^CodexUsageWidget-launcher-[0-9a-f]{32}$') `
        '[launcher/cleanup] Refusing to remove a directory outside the test temp root.'
    if ([IO.Directory]::Exists($resolvedTestRoot)) { [IO.Directory]::Delete($resolvedTestRoot, $true) }
}

'Launcher self-test passed.'
