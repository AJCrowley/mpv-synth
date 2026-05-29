@echo OFF
:: -----------------------------------------------------------------------
:: updater.bat -- launcher for updater.ps1
:: If not running as administrator, re-launches itself elevated so that
:: installs directly into Program Files work without the user needing to
:: manually right-click "Run as administrator".
:: -----------------------------------------------------------------------
set unattended=no
if "%1"=="/u" set unattended=yes
if "%2"=="/i" set install=yes
pushd %~dp0

:: -----------------------------------------------------------------------
:: Admin check -- net session is a reliable proxy for elevation status
:: -----------------------------------------------------------------------
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    :: Re-launch this exact batch file elevated, then exit the unelevated copy
    powershell -NoProfile -NoLogo -Command ^
        "Start-Process -FilePath cmd.exe -ArgumentList '/c pushd ""%~dp0"" && ""%~f0""' -Verb RunAs -Wait"
    exit /b
)

:: -----------------------------------------------------------------------
:: Locate updater.ps1 (prefer installer\ subfolder, fall back to root)
:: -----------------------------------------------------------------------
if exist "%~dp0installer\updater.ps1" (
    set updater_script="%~dp0installer\updater.ps1"
) else (
    set updater_script="%~dp0updater.ps1"
)

set "unattended_flag="
if [%unattended%] == [yes] set "unattended_flag= -Unattended"
set "installing_flag="
if [%install%] == [yes] set "install_flag= -Installing"
:: -----------------------------------------------------------------------
:: Run the script -- prefer pwsh (PS 7+), fall back to Windows PowerShell 5
:: -----------------------------------------------------------------------
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%%unattended_flag%%install_flag%
) else (
    powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%%unattended_flag%%install_flag%
)

:: -----------------------------------------------------------------------
:: Clean up root-level copy of updater.ps1 if the canonical one is in
:: installer\ (prevents a stale root copy from being run by mistake)
:: -----------------------------------------------------------------------
set unattended=no
if "%1"=="/u" set unattended=yes
if exist "%~dp0installer\updater.ps1" if exist "%~dp0updater.ps1" (
    del "%~dp0updater.ps1"
)
if [%unattended%] == [yes] exit /b 0
timeout 5
