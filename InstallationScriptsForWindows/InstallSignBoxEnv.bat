@echo off
chcp 65001 >nul
:: Отключаем delayed expansion, чтобы не выпадали восклицательные знаки (!) в путях
setlocal disabledelayedexpansion

:: Определяем рабочую директорию скрипта
set "WORK_DIR=%~dp0"
set "INI_FILE=%WORK_DIR%InstallSingBoxEnv.ini"

echo =======================================================
echo Шаг 1: Чтение конфигурации из InstallSingBoxEnv.ini...
echo =======================================================

if not exist "%INI_FILE%" (
    echo [ОШИБКА] Файл конфигурации не найден:
    echo %INI_FILE%
    echo Пожалуйста, создайте этот файл и укажите параметр ConfigUrl.
    echo =======================================================
    pause
    exit /b 1
)

set "CONFIG_URL="
for /f "usebackq tokens=1,* delims==" %%A in ("%INI_FILE%") do (
    if /i "%%A"=="ConfigUrl" set "CONFIG_URL=%%B"
)

if "%CONFIG_URL%"=="" (
    echo [ОШИБКА] Параметр ConfigUrl не найден или пуст в файле InstallSingBoxEnv.ini!
    echo =======================================================
    pause
    exit /b 1
)

echo URL конфига успешно загружен:
echo %CONFIG_URL%
echo.

echo =======================================================
echo Шаг 2: Установка ядра sing-box через winget...
echo =======================================================
winget install -e --id SagerNet.sing-box --accept-source-agreements --accept-package-agreements

echo.
echo =======================================================
echo Шаг 3: Создание управляющих скриптов...
echo =======================================================

:: Создание start.bat с проверкой прав администратора
echo Создание start.bat...
(
echo @echo off
echo net session ^>nul 2^>^&1
echo if %%errorLevel%% neq 0 ^(
echo     powershell -Command "Start-Process '%WORK_DIR%start.bat' -Verb RunAs"
echo     exit /b
echo ^)
echo cd /d "%%~dp0"
echo echo Загрузка актуальной конфигурации...
echo curl -sL -o config.json "%CONFIG_URL%"
echo echo Запуск sing-box с правами администратора...
echo sing-box run -c config.json
) > "%WORK_DIR%start.bat"

:: Создание stop.bat с проверкой прав администратора
echo Создание stop.bat...
(
echo @echo off
echo net session ^>nul 2^>^&1
echo if %%errorLevel%% neq 0 ^(
echo     powershell -Command "Start-Process '%WORK_DIR%stop.bat' -Verb RunAs"
echo     exit /b
echo ^)
echo echo Остановка sing-box...
echo taskkill /F /IM sing-box.exe /T
) > "%WORK_DIR%stop.bat"

:: Создание silent_run.vbs с вызовом UAC
echo Создание silent_run.vbs...
(
echo CreateObject^("Shell.Application"^).ShellExecute "cmd.exe", "/c start.bat", "%WORK_DIR%", "runas", 0
) > "%WORK_DIR%silent_run.vbs"

echo.
echo =======================================================
echo УСПЕШНО! Установка и настройка завершены.
echo =======================================================
echo Управляющие скрипты созданы в папке:
echo %WORK_DIR%
echo.
echo Для фонового запуска используйте: silent_run.vbs
echo Для остановки прокси используйте: stop.bat
echo =======================================================
pause