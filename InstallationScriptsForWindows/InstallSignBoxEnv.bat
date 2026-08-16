@echo off
setlocal disabledelayedexpansion

:: Определяем рабочую директорию скрипта
set "WORK_DIR=%~dp0"
set "INI_FILE=%WORK_DIR%InstallSingBoxEnv.ini"

echo =======================================================
echo Step 1: Reading config from InstallSingBoxEnv.ini...
echo =======================================================

if not exist "%INI_FILE%" (
    echo [ERROR] Configuration file not found:
    echo %INI_FILE%
    echo Please create this file and set ConfigUrl parameter.
    echo =======================================================
    pause
    exit /b 1
)

set "CONFIG_URL="
for /f "usebackq tokens=1,* delims==" %%A in ("%INI_FILE%") do (
    if /i "%%A"=="ConfigUrl" set "CONFIG_URL=%%B"
)

if "%CONFIG_URL%"=="" (
    echo [ERROR] ConfigUrl parameter is empty or missing in InstallSingBoxEnv.ini!
    echo =======================================================
    pause
    exit /b 1
)

echo Config URL loaded successfully:
echo %CONFIG_URL%
echo.

echo =======================================================
echo Step 2: Installing sing-box core via winget...
echo =======================================================
winget install -e --id SagerNet.sing-box --accept-source-agreements --accept-package-agreements

echo.
echo =======================================================
echo Step 3: Creating control scripts in the current folder...
echo =======================================================

:: Создание start.bat с запросом прав администратора
echo Creating start.bat...
(
echo @echo off
echo net session ^>nul 2^>^&1
echo if %%errorLevel%% neq 0 ^(
echo     powershell -Command "Start-Process '%WORK_DIR%start.bat' -Verb RunAs"
echo     exit /b
echo ^)
echo cd /d "%%~dp0"
echo echo Downloading fresh config...
echo curl -sL -o config.json "%CONFIG_URL%"
echo echo Starting sing-box...
echo sing-box run -c config.json
) > "%WORK_DIR%start.bat"

:: Создание stop.bat с запросом прав администратора
echo Creating stop.bat...
(
echo @echo off
echo net session ^>nul 2^>^&1
echo if %%errorLevel%% neq 0 ^(
echo     powershell -Command "Start-Process '%WORK_DIR%stop.bat' -Verb RunAs"
echo     exit /b
echo ^)
echo echo Stopping sing-box...
echo taskkill /F /IM sing-box.exe /T
) > "%WORK_DIR%stop.bat"

:: Создание silent_run.vbs
echo Creating silent_run.vbs...
(
echo CreateObject^("Shell.Application"^).ShellExecute "cmd.exe", "/c start.bat", "%WORK_DIR%", "runas", 0
) > "%WORK_DIR%silent_run.vbs"

echo.
echo =======================================================
echo DONE! Installation and setup complete.
echo =======================================================
echo Your scripts have been successfully created in:
echo %WORK_DIR%
echo.
echo For hidden launch, use: silent_run.vbs
echo To stop the proxy, use: stop.bat
echo =======================================================
pause
