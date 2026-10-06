#Requires -Version 5.1
<#
    Installation of sing-box + automatic config loading + Start/Stop shortcuts
    with administrator rights, accessible for execution from standard-user account.
#>

# =========================================================================
# 1. REQUEST ADMINISTRATIVE RIGHTS (self-elevation)
# =========================================================================
function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $p  = New-Object Security.Principal.WindowsPrincipal($id)
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-Admin)) {
    $scriptPath = $MyInvocation.MyCommand.Path
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
        -Verb RunAs
    exit
}

$ErrorActionPreference = "Stop"
Write-Host "=== sing-box installation started with administrator rights ===" -ForegroundColor Cyan

# =========================================================================
# 2. READ ConfigUrl AND Version FROM InstallSingBoxEnv.ini
# =========================================================================
$IniPath = Join-Path $PSScriptRoot "InstallSingBoxEnv.ini"
if (-not (Test-Path $IniPath)) {
    throw "Configuration file not found: $IniPath"
}

$IniContent = Get-Content -Path $IniPath

$ConfigUrl = $null
$Version   = "latest"   # default value

foreach ($line in $IniContent) {
    if ($line -match '^\s*ConfigUrl\s*=\s*(.+?)\s*$') {
        $ConfigUrl = $matches[1].Trim('"', "'")
    }
    elseif ($line -match '^\s*Version\s*=\s*(.+?)\s*$') {
        $Version = $matches[1].Trim('"', "'")
    }
}

if ([string]::IsNullOrWhiteSpace($ConfigUrl)) {
    throw "ConfigUrl key not found in $IniPath"
}
if ([string]::IsNullOrWhiteSpace($Version)) {
    $Version = "latest"
}

Write-Host "ConfigUrl: $ConfigUrl" -ForegroundColor Green
Write-Host "Version:   $Version" -ForegroundColor Green

# =========================================================================
# 3. INSTALLATION / REINSTALLATION of sing-box
# =========================================================================
$InstallDir = Join-Path $env:ProgramFiles "sing-box"
$ExePath    = Join-Path $InstallDir "sing-box.exe"

# Stop running tasks and process before reinstallation
Get-Process -Name "sing-box" -ErrorAction SilentlyContinue | Stop-Process -Force

if (Test-Path $InstallDir) {
    Write-Host "Previous installation detected - removing..." -ForegroundColor Yellow
    Remove-Item -Path $InstallDir -Recurse -Force
}
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

Write-Host "Getting sing-box release information (Version=$Version)..." -ForegroundColor Cyan
$Headers = @{ "User-Agent" = "PowerShell-InstallScript" }

if ($Version -match '^(?i)latest$') {
    $ReleaseUri = "https://api.github.com/repos/SagerNet/sing-box/releases/latest"
}
else {
    # Normalize: GitHub tag always starts with "v"
    $Tag = $Version.Trim()
    if ($Tag -notmatch '^v') { $Tag = "v$Tag" }
    $ReleaseUri = "https://api.github.com/repos/SagerNet/sing-box/releases/tags/$Tag"
}

try {
    $Release = Invoke-RestMethod -Uri $ReleaseUri -Headers $Headers
}
catch {
    throw "Failed to get release '$Version' from $ReleaseUri. Check version correctness. Error: $_"
}

Write-Host "Version to install: $($Release.tag_name)" -ForegroundColor Green

$Arch  = if ([Environment]::Is64BitOperatingSystem) { "amd64" } else { "386" }
$Asset = $Release.assets | Where-Object { $_.name -match "windows-$Arch\.zip$" } | Select-Object -First 1
if (-not $Asset) { throw "Archive for windows-$Arch not found in release $($Release.tag_name)" }

$ZipPath     = Join-Path $InstallDir $Asset.name
$ExtractDir  = Join-Path $InstallDir "extract"

Write-Host "Downloading $($Asset.name)..." -ForegroundColor Cyan
Invoke-WebRequest -Uri $Asset.browser_download_url -OutFile $ZipPath -UseBasicParsing

if (Test-Path $ExtractDir) { Remove-Item $ExtractDir -Recurse -Force }
Expand-Archive -Path $ZipPath -DestinationPath $ExtractDir -Force

$FoundExe = Get-ChildItem -Path $ExtractDir -Filter "sing-box.exe" -Recurse | Select-Object -First 1
if (-not $FoundExe) { throw "sing-box.exe not found in downloaded archive" }

Copy-Item -Path $FoundExe.FullName -Destination $ExePath -Force
Remove-Item -Path $ZipPath -Force
Remove-Item -Path $ExtractDir -Recurse -Force

Write-Host "sing-box installed: $ExePath" -ForegroundColor Green

# =========================================================================
# 4. WRAPPER FILES: download config, start / stop sing-box, monitor window
# =========================================================================
$ConfigPath        = Join-Path $InstallDir "config.json"
$LogPath           = Join-Path $InstallDir "sing-box.log"
$StartScriptPath   = Join-Path $InstallDir "Start-SingBox.ps1"
$StopScriptPath    = Join-Path $InstallDir "Stop-SingBox.ps1"
$MonitorScriptPath = Join-Path $InstallDir "Monitor-SingBox.ps1"
$TaskStartName     = "SingBox-Start"
$TaskStopName      = "SingBox-Stop"

# --- Startup script (runs as SYSTEM) ---
$StartScriptContent = @"
`$ErrorActionPreference = 'Continue'
`$ConfigUrl  = '$ConfigUrl'
`$ConfigPath = '$ConfigPath'
`$ExePath    = '$ExePath'
`$LogPath    = '$LogPath'
`$Utf8 = New-Object System.Text.UTF8Encoding(`$false)   # UTF-8 без BOM

function Write-Log(`$msg) {
    [System.IO.File]::AppendAllText(`$LogPath, "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [launcher] `$msg`r`n", `$Utf8)
}

# Kill previous instance and wait until it has really exited
Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force
Wait-Process -Name 'sing-box' -Timeout 10 -ErrorAction SilentlyContinue
Start-Sleep -Seconds 1

# New session -> log starts from scratch
[System.IO.File]::WriteAllText(`$LogPath, '', `$Utf8)
Write-Log 'Session started'

try {
    Write-Log 'Downloading config...'
    Invoke-WebRequest -Uri `$ConfigUrl -OutFile `$ConfigPath -UseBasicParsing
    Write-Log 'Config downloaded'
} catch {
    Write-Log "FATAL: failed to download config: `$_"
    exit 1
}

# cmd.exe merges stdout+stderr into ONE file (append, after the launcher lines)
`$CmdArgs = '/c ""' + `$ExePath + '" run -c "' + `$ConfigPath + '" >> "' + `$LogPath + '" 2>&1"'
Write-Log 'Starting sing-box'
Start-Process -FilePath 'cmd.exe' -ArgumentList `$CmdArgs -WindowStyle Hidden
"@
Set-Content -Path $StartScriptPath -Value $StartScriptContent -Encoding UTF8 -Force

# --- Shutdown script ---
$StopScriptContent = @"
Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force
[System.IO.File]::AppendAllText('$LogPath', "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') [launcher] sing-box stopped by user request`r`n", (New-Object System.Text.UTF8Encoding(`$false)))
"@
Set-Content -Path $StopScriptPath -Value $StopScriptContent -Encoding UTF8 -Force

# --- Monitor window (runs as the normal user, shows status + live log) ---
$MonitorScriptContent = @'
$LogPath   = '__LOG__'
$StartTask = '__START_TASK__'
$StopTask  = '__STOP_TASK__'

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

# One window per user session
$mutex = New-Object System.Threading.Mutex($false, 'Local\SingBoxMonitor')
if (-not $mutex.WaitOne(0)) {
    Write-Host 'The sing-box window is already open.' -ForegroundColor Yellow
    Start-Sleep -Seconds 3
    exit
}

# Stop sing-box when the console window is closed
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
public static class CloseHook {
    public delegate bool HandlerRoutine(uint ctrlType);
    [DllImport("kernel32.dll")]
    static extern bool SetConsoleCtrlHandler(HandlerRoutine h, bool add);
    static HandlerRoutine _h;
    static string _task;
    public static void Install(string task) {
        _task = task;
        _h = new HandlerRoutine(OnCtrl);
        SetConsoleCtrlHandler(_h, true);
    }
    static bool OnCtrl(uint t) {
        if (t == 0 || t == 1 || t == 2) { // CTRL_CLOSE_EVENT: window closed OR CTRL+C OR CTRL+BREAK
            try {
                var psi = new ProcessStartInfo("schtasks.exe", "/Run /TN \"" + _task + "\"");
                psi.CreateNoWindow = true;
                psi.UseShellExecute = false;
                var p = Process.Start(psi);
                p.WaitForExit(3000);
            } catch { }
        }
        return false;
    }
}
"@
[CloseHook]::Install($StopTask)

$ui   = $Host.UI.RawUI
$spin = '|','/','-','\'
$tick = 0

function Get-Sing { Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue | Select-Object -First 1 }

function Invoke-Task([string]$Name) {
    schtasks.exe /Run /TN $Name *> $null
    return ($LASTEXITCODE -eq 0)
}

function Wait-Sing([int]$Seconds, [int]$OldId = 0) {
    $end = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $end) {
        $p = Get-Sing
        if ($p -and $p.Id -ne $OldId) { return $p }
        Start-Sleep -Milliseconds 300
    }
    return $null
}

function Write-Banner([string]$Text, [string]$Color) {
    Write-Host ('[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Text) -ForegroundColor $Color
}

Clear-Host
Write-Host '================ sing-box ================' -ForegroundColor Cyan
Write-Host ' [S] / [Q] stop and exit   [R] restart   (closing the window also stops sing-box)' -ForegroundColor DarkGray
Write-Host ''

$p = Get-Sing
if ($p) {
    Write-Banner "sing-box is already running (PID $($p.Id)) - showing session log" 'Yellow'
} else {
    $ui.WindowTitle = 'sing-box STARTING...'
    Write-Banner 'Starting sing-box...' 'Yellow'
    if (-not (Invoke-Task $StartTask)) {
        Write-Banner "Could not run scheduled task '$StartTask'" 'Red'
        Read-Host 'Press Enter to close'
        exit 1
    }
    if (-not (Wait-Sing 30)) { Write-Banner 'sing-box did not start within 30 s - see the log below' 'Red' }
}

$pos       = 0L
$partial   = ''
$lastState = ''
$since     = $null

while ($true) {
    # ---- live log ----
    if (Test-Path -LiteralPath $LogPath) {
        try {
            $fs = [System.IO.File]::Open($LogPath, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read, [System.IO.FileShare]'ReadWrite,Delete')
            try {
                if ($fs.Length -lt $pos) {
                    $pos = 0; $partial = ''
                    Write-Host '--- log restarted ---' -ForegroundColor DarkYellow
                }
                if ($fs.Length -gt $pos) {
                    $len = [int]($fs.Length - $pos)
                    $buf = New-Object byte[] $len
                    $fs.Position = $pos
                    $n = $fs.Read($buf, 0, $len)
                    $pos += $n
                    $text  = $partial + [System.Text.Encoding]::UTF8.GetString($buf, 0, $n)
                    $parts = $text -split '\r?\n'
                    $partial = $parts[-1]
                    for ($j = 0; $j -lt $parts.Count - 1; $j++) {
                        $line = ($parts[$j] -replace '\x1B\[[0-9;]*m', '').TrimStart([char]0xFEFF)
                        if     ($line -match 'FATAL|ERROR') { Write-Host $line -ForegroundColor Red }
                        elseif ($line -match 'WARN')        { Write-Host $line -ForegroundColor Yellow }
                        else                                { Write-Host $line }
                    }
                }
            } finally { $fs.Dispose() }
        } catch { }
    }

    # ---- status / window title ----
    $p = Get-Sing
    if ($p) {
        if ($lastState -ne 'run') {
            $lastState = 'run'
            try { $since = (Get-CimInstance Win32_Process -Filter "ProcessId=$($p.Id)").CreationDate } catch { }
            if (-not $since) { $since = Get-Date }
            Write-Banner "sing-box is RUNNING (PID $($p.Id))" 'Green'
        }
        $up = (Get-Date) - $since
        $ui.WindowTitle = '{0} sing-box RUNNING | PID {1} | uptime {2:00}:{3:00}:{4:00}' -f `
            $spin[$tick % 4], $p.Id, [math]::Floor($up.TotalHours), $up.Minutes, $up.Seconds
    } else {
        if ($lastState -ne 'stop') {
            $lastState = 'stop'
            Write-Banner 'sing-box is STOPPED  ([R] restart, [Q] close window)' 'Red'
        }
        $ui.WindowTitle = 'sing-box STOPPED'
    }
    $tick++

    # ---- keys ----
    while ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true).Key
        if ($key -eq 'S') {
            Write-Banner 'Stopping sing-box...' 'Yellow'
            Invoke-Task $StopTask | Out-Null
            for ($k = 0; $k -lt 30 -and (Get-Sing); $k++) { Start-Sleep -Milliseconds 300 }
            Write-Banner 'Stopped.' 'Red'
            Start-Sleep -Seconds 2
            exit
        }
        elseif ($key -eq 'R') {
            $old   = Get-Sing
            $oldId = if ($old) { $old.Id } else { 0 }
            Write-Banner 'Restarting sing-box...' 'Yellow'
            Invoke-Task $StartTask | Out-Null
            $null = Wait-Sing 30 $oldId
            $pos = 0; $partial = ''; $lastState = ''
        }
	elseif ($key -eq 'Q') {
	    Write-Banner 'Stopping sing-box...' 'Yellow'
	    Invoke-Task $StopTask | Out-Null
	    for ($k = 0; $k -lt 30 -and (Get-Sing); $k++) { Start-Sleep -Milliseconds 300 }
	    exit
	}
    }
    Start-Sleep -Milliseconds 300
}
'@
$MonitorScriptContent = $MonitorScriptContent.Replace('__LOG__', $LogPath).
    Replace('__START_TASK__', $TaskStartName).Replace('__STOP_TASK__', $TaskStopName)
Set-Content -Path $MonitorScriptPath -Value $MonitorScriptContent -Encoding UTF8 -Force

# --- Shortcut for all users (normal, NOT elevated) ---
$Shell = New-Object -ComObject WScript.Shell
$Lnk = $Shell.CreateShortcut((Join-Path $env:PUBLIC 'Desktop\sing-box.lnk'))
$Lnk.TargetPath       = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$Lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$MonitorScriptPath`""
$Lnk.WorkingDirectory = $InstallDir
$Lnk.IconLocation = "$env:WINDIR\System32\imageres.dll,170"
$Lnk.Save()

Write-Host "Startup/shutdown/monitor scripts created in $InstallDir" -ForegroundColor Green

# =========================================================================
# 5. SCHEDULED TASKS (run as SYSTEM, manually on demand)
# =========================================================================
function Register-SingBoxTask {
    param(
        [string]$TaskName,
        [string]$ScriptPath
    )

    $Action = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ScriptPath`""

    $Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

    $Settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -Hidden `
        -ExecutionTimeLimit ([TimeSpan]::Zero)   # no time limit

    Register-ScheduledTask -TaskName $TaskName -Action $Action `
        -Principal $Principal -Settings $Settings -Force | Out-Null

    Write-Host "Task '$TaskName' registered." -ForegroundColor Green
}

Register-SingBoxTask -TaskName $TaskStartName -ScriptPath $StartScriptPath
Register-SingBoxTask -TaskName $TaskStopName  -ScriptPath $StopScriptPath

# =========================================================================
# 6. GRANT STANDARD USERS PERMISSION TO RUN/STOP THESE TASKS
# =========================================================================
# ACE (A;;GRGX;;;BU) = Allow, Generic Read + Generic Execute, for
# Built-in Users (BU) group. This is sufficient for schtasks /Run to work
# from a standard user account.
$UsersAce = "(A;;GRGX;;;BU)"

$Scheduler = New-Object -ComObject "Schedule.Service"
$Scheduler.Connect()
$RootFolder = $Scheduler.GetFolder("\")

function Test-UserHasRunRights {
    param([string]$Sddl)

    $rsd = New-Object System.Security.AccessControl.RawSecurityDescriptor($Sddl)
    $usersSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinUsersSid, $null)

    foreach ($ace in $rsd.DiscretionaryAcl) {
        if ($ace.AceQualifier -eq 'AccessAllowed' -and $ace.SecurityIdentifier -eq $usersSid) {
            # 0x1200a9 =  already gives Read + Execute premission for the task object
            if (($ace.AccessMask -band 0x1200a9) -eq 0x1200a9) {
                return $true
            }
        }
    }
    return $false
}

function Grant-TaskRunPermission {
    param([string]$TaskName)

    $Task = $RootFolder.GetTask($TaskName)
    $Sddl = $Task.GetSecurityDescriptor(0xF)

    if (Test-UserHasRunRights -Sddl $Sddl) {
        Write-Host "'Users' already has permissions to run task '$TaskName'." -ForegroundColor Green
        return
    }

    $UsersAce = "(A;;GRGX;;;BU)"
    $NewSddl = $Sddl + $UsersAce
    try {
        $Task.SetSecurityDescriptor($NewSddl, 0)
    } catch {
        throw "Failed to update SDDL for task '$TaskName': $_"
    }

    $CheckSddl = $Task.GetSecurityDescriptor(0xF)
    if (Test-UserHasRunRights -Sddl $CheckSddl) {
        Write-Host "Permissions on task '$TaskName' are confirmed." -ForegroundColor Green
    } else {
        Write-Host "WARNING: Failed to confirm permissions on task '$TaskName'." -ForegroundColor Red
    }
}

Grant-TaskRunPermission -TaskName $TaskStartName
Grant-TaskRunPermission -TaskName $TaskStopName
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($RootFolder) | Out-Null
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($Scheduler)  | Out-Null

Write-Host ""
Write-Host "=== Installation completed successfully ===" -ForegroundColor Cyan
Write-Host "Use the desktop shortcuts to enable/disable VPN."
Read-Host "Press Enter to continue"
