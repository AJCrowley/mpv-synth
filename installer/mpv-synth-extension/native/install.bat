@echo off
setlocal enabledelayedexpansion

:: ============================================================
::  mpv-synth Browser Extension — Native Host Installer
::  Run this script ONCE after extracting the download.
::  It registers the native messaging host for Chrome and Firefox.
:: ============================================================

echo.
echo  ======================================================
echo   mpv-synth Player — Native Host Installer
echo  ======================================================
echo.

:: ============================================================
::  run permissions.ps1 to give user control over extension
::  directory.
:: ============================================================

net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Requesting administrator privileges...
    :: Re-launch this exact batch file elevated, then exit the unelevated copy
    powershell -NoProfile -NoLogo -Command ^
        "Start-Process -FilePath cmd.exe -ArgumentList '/c pushd ""%~dp0"" && ""%~f0""' -Verb RunAs -Wait"
    exit /b
)

set updater_script="%~dp0permissions.ps1"

where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%
) else (
    powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%
)

:: ============================================================
::  permissions have now been set on extension's directories
:: ============================================================

:: ── Determine the directory this script lives in (the "native\" folder) ──────
set "NATIVE_DIR=%~dp0"
:: Remove trailing backslash
if "%NATIVE_DIR:~-1%"=="\" set "NATIVE_DIR=%NATIVE_DIR:~0,-1%"

set "BAT_PATH=%NATIVE_DIR%\mpv_synth_host.bat"
set "JSON_SRC=%NATIVE_DIR%\mpv_synth_host.json"
set "JSON_OUT=%NATIVE_DIR%\mpv_synth_host_installed.json"

echo  Script location : %NATIVE_DIR%
echo  Host wrapper    : %BAT_PATH%
echo.

:: ── Verify Python is available ───────────────────────────────────────────────
set "PYTHON_OK=0"
py --version >nul 2>&1
if not errorlevel 1 (
    echo  [OK] Python launcher found.
    set "PYTHON_OK=1"
    goto :python_done
)
python --version >nul 2>&1
if not errorlevel 1 (
    echo  [OK] Python found.
    set "PYTHON_OK=1"
    goto :python_done
)
echo  [WARNING] Python 3 was NOT found on PATH.
echo             The extension will not work until Python 3 is installed.
echo             Download from: https://www.python.org/downloads/
echo.

:python_done

:: ── Write the resolved host manifest with the real .bat path ─────────────────
:: PowerShell's .Replace() handles backslash doubling - no batch substitution needed.
powershell -NoProfile -Command "(Get-Content '%JSON_SRC%') -replace 'PLACEHOLDER_REPLACED_BY_INSTALL_BAT', ('%BAT_PATH%'.Replace('\',  '\\')) | Set-Content '%JSON_OUT%'"

if not exist "%JSON_OUT%" (
    echo  [ERROR] Failed to create the host manifest. Aborting.
    pause
    exit /b 1
)
echo  [OK] Host manifest written to: %JSON_OUT%

:: ── Register for Chrome ───────────────────────────────────────────────────────
echo.
echo  Registering native host for Google Chrome ...
reg add "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.mpvsynth.launcher" /ve /d "%JSON_OUT%" /f >nul 2>&1
if not errorlevel 1 goto :chrome_ok
echo  [WARNING] Could not write Chrome registry key [Chrome may not be installed].
goto :chrome_done
:chrome_ok
echo  [OK] Chrome registry key created.
:chrome_done

:: ── Register for Firefox ──────────────────────────────────────────────────────
echo  Registering native host for Mozilla Firefox ...
reg add "HKCU\Software\Mozilla\NativeMessagingHosts\com.mpvsynth.launcher" /ve /d "%JSON_OUT%" /f >nul 2>&1
if not errorlevel 1 goto :firefox_ok
echo  [WARNING] Could not write Firefox registry key [Firefox may not be installed].
goto :firefox_done
:firefox_ok
echo  [OK] Firefox registry key created.
:firefox_done

:: ── Register for Microsoft Edge ───────────────────────────────────────────────
echo  Registering native host for Microsoft Edge ...
reg add "HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.mpvsynth.launcher" /ve /d "%JSON_OUT%" /f >nul 2>&1
if not errorlevel 1 goto :edge_ok
echo  [WARNING] Could not write Edge registry key [Edge may not be installed].
goto :edge_done
:edge_ok
echo  [OK] Edge registry key created.
:edge_done

:: ── Done ─────────────────────────────────────────────────────────────────────
echo.
echo  ======================================================
echo   Installation complete!
echo  ======================================================
echo.
echo  Next steps:
echo   1. Load the extension into your browser (see README.md).
echo   2. Click the extension icon or right-click a link to open Settings.
echo   3. Set your mpv Location and Config Location paths.
echo.
if "%PYTHON_OK%"=="0" (
    echo  IMPORTANT: Install Python 3 from https://www.python.org before using.
    echo.
)
pause
