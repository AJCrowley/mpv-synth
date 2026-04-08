@echo off
setlocal enableextensions enabledelayedexpansion
path %SystemRoot%\System32;%SystemRoot%;%SystemRoot%\System32\Wbem

set unattended=no
if "%1"=="/u" set unattended=yes

call :ensure_admin

cd /D %~dp0\..

:: -------------------------------
:: Remove VapourSynth from PATH
:: -------------------------------
set "PathToRemove=%cd%\portable_config\VapourSynth"

for /f "tokens=2*" %%A in ('reg query HKCU\Environment /v Path 2^>nul') do set "CurrentPath=%%B"

echo !CurrentPath! | find /i "%PathToRemove%" >nul
if not errorlevel 1 (
    set "NewPath=!CurrentPath:%PathToRemove%;=!"
    if "!NewPath!" == "!CurrentPath!" set "NewPath=!CurrentPath:;%PathToRemove%=!"
    setx Path "!NewPath!" >nul
    echo Removed VapourSynth from PATH
)

:: -------------------------------
:: Remove App Paths
:: -------------------------------
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\mpv.exe" /f >nul 2>&1

:: -------------------------------
:: Remove Applications entry
:: -------------------------------
set classes_root_key=HKLM\SOFTWARE\Classes

reg delete "%classes_root_key%\Applications\mpv.exe\SupportedTypes" /f >nul 2>&1
reg delete "%classes_root_key%\Applications\mpv.exe" /f >nul 2>&1

:: -------------------------------
:: Remove OpenWith entries
:: -------------------------------
reg delete "%classes_root_key%\SystemFileAssociations\video\OpenWithList\mpv.exe" /f >nul 2>&1
reg delete "%classes_root_key%\SystemFileAssociations\audio\OpenWithList\mpv.exe" /f >nul 2>&1

:: -------------------------------
:: Remove AutoPlay handlers
:: -------------------------------
set autoplay_key=HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers

reg delete "%autoplay_key%\Handlers\MpvPlayDVDMovieOnArrival" /f >nul 2>&1
reg delete "%autoplay_key%\EventHandlers\PlayDVDMovieOnArrival" /v "MpvPlayDVDMovieOnArrival" /f >nul 2>&1

reg delete "%autoplay_key%\Handlers\MpvPlayBluRayOnArrival" /f >nul 2>&1
reg delete "%autoplay_key%\EventHandlers\PlayBluRayOnArrival" /v "MpvPlayBluRayOnArrival" /f >nul 2>&1

:: -------------------------------
:: Remove Default Programs registration
:: -------------------------------
reg delete "HKLM\SOFTWARE\RegisteredApplications" /v "mpv-synth" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\Clients\Media\mpv-synth" /f >nul 2>&1

:: -------------------------------
:: Remove mpv ProgIDs (dvd/bluray + file types)
:: -------------------------------
for %%k in (
    "%classes_root_key%\io.mpv.dvd"
    "%classes_root_key%\io.mpv.bluray"
) do (
    reg delete %%k /f >nul 2>&1
)

:: Remove ALL io.mpv.* ProgIDs
for /f "usebackq delims=" %%k in (`reg query "%classes_root_key%" /f "io.mpv." /k ^| findstr /i "io.mpv."`) do (
    reg delete "%%k" /f >nul 2>&1
)

:: -------------------------------
:: Remove OpenWithProgIds references
:: -------------------------------
for /f "usebackq delims=" %%k in (`reg query "%classes_root_key%" /f "io.mpv." /s /v ^| findstr /i "OpenWithProgIds"`) do (
    for /f "tokens=1" %%v in ('reg query "%%k" /f "io.mpv." /v ^| findstr /i "io.mpv."') do (
        reg delete "%%k" /v "%%v" /f >nul 2>&1
    )
)

:: -------------------------------
:: Remove Start Menu shortcut
:: -------------------------------
del "%ProgramData%\Microsoft\Windows\Start Menu\Programs\mpv-synth.lnk" >nul 2>&1

:: Optional: Desktop shortcut (if ever added manually)
del "%Public%\Desktop\mpv-synth.lnk" >nul 2>&1

echo Uninstalled successfully

if [%unattended%] == [yes] exit /b 0
pause
exit /b 0

:: -------------------------------
:: Helpers
:: -------------------------------
:ensure_admin
openfiles >nul 2>&1
if errorlevel 1 (
    echo This script requires administrator privileges.
    pause
    exit /b 1
)
goto :EOF