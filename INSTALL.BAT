@echo off
setlocal
echo Running full mpv-synth installation...

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

:: Run updater (downloads mpv, VapourSynth, SVPflow, ffmpeg, yt-dlp)
call "%~dp0updater.bat" /u

:: Install (sets PATH, ACLs, etc.)
call "%~dp0installer\mpv-install.bat" /u

:: Pause until everything done for safe self-deletion
echo mpv-synth install complete
pause
:: Self-delete
(goto) 2>nul & del "%~f0"