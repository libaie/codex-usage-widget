param([Parameter(Mandatory)][string]$PackageRoot)

$ErrorActionPreference = 'Stop'
function Assert-Launcher([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

$package = (Resolve-Path -LiteralPath $PackageRoot).Path
$separator = [IO.Path]::DirectorySeparatorChar
$tempParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd($separator)
$testRoot = Join-Path $tempParent ('CodexUsageWidget-launcher-' + [guid]::NewGuid().ToString('N'))
$probePid = $null
try {
    [IO.Directory]::CreateDirectory($testRoot) | Out-Null
    Copy-Item -LiteralPath (Join-Path $package 'Start-CodexUsageWidget.cmd') -Destination $testRoot
    $vbs = Join-Path $package 'Start-CodexUsageWidget.vbs'
    if (Test-Path -LiteralPath $vbs) { Copy-Item -LiteralPath $vbs -Destination $testRoot }
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\where.exe') -Destination (Join-Path $testRoot 'wscript.exe')
    [IO.File]::WriteAllText(
        (Join-Path $testRoot 'CodexUsageWidget.ps1'),
        "[IO.File]::WriteAllText((Join-Path `$PSScriptRoot 'probe.pid'), [string]`$PID)`r`nStart-Sleep -Seconds 30`r`n",
        [Text.Encoding]::ASCII)

    $savedPolicy = $env:PSExecutionPolicyPreference
    try {
        $env:PSExecutionPolicyPreference = 'Bypass'
        Push-Location -LiteralPath $testRoot
        try { & $env:ComSpec /d /s /c ('""{0}""' -f (Join-Path $testRoot 'Start-CodexUsageWidget.cmd')) }
        finally { Pop-Location }
        Assert-Launcher ($LASTEXITCODE -eq 0) 'The launcher wrapper returned a failure exit code.'
    }
    finally { $env:PSExecutionPolicyPreference = $savedPolicy }

    $pidFile = Join-Path $testRoot 'probe.pid'
    $deadline = [datetime]::UtcNow.AddSeconds(5)
    while (-not [IO.File]::Exists($pidFile) -and [datetime]::UtcNow -lt $deadline) {
        Start-Sleep -Milliseconds 100
    }
    Assert-Launcher ([IO.File]::Exists($pidFile)) 'The launcher did not start the PowerShell target.'
    $probePid = [int][IO.File]::ReadAllText($pidFile)

    $probeProcess = Get-Process -Id $probePid -ErrorAction Stop
    Assert-Launcher ($probeProcess.MainWindowHandle -eq 0) 'The launched widget has a visible console window.'
    $children = @(Get-CimInstance Win32_Process | Where-Object ParentProcessId -eq $probePid)
    $visibleConsoleChildren = @($children | Where-Object Name -eq 'conhost.exe' | Where-Object {
        (Get-Process -Id $_.ProcessId -ErrorAction Stop).MainWindowHandle -ne 0
    })
    Assert-Launcher ($visibleConsoleChildren.Count -eq 0) 'The launched widget has a visible console host.'
    $lingeringCmd = @(Get-CimInstance Win32_Process | Where-Object {
        $_.Name -eq 'cmd.exe' -and $_.CommandLine -like ('*' + $testRoot + '*')
    })
    Assert-Launcher ($lingeringCmd.Count -eq 0) 'The launcher left a cmd.exe process running.'
    'Launcher self-test passed.'
}
finally {
    if ($null -ne $probePid) {
        Stop-Process -Id $probePid -ErrorAction SilentlyContinue
        Wait-Process -Id $probePid -Timeout 3 -ErrorAction SilentlyContinue
    }
    $resolvedTestRoot = [IO.Path]::GetFullPath($testRoot)
    Assert-Launcher ($resolvedTestRoot.StartsWith($tempParent + $separator, [StringComparison]::OrdinalIgnoreCase)) `
        'Refusing to remove a launcher test directory outside the temporary directory.'
    if ([IO.Directory]::Exists($resolvedTestRoot)) { [IO.Directory]::Delete($resolvedTestRoot, $true) }
}
