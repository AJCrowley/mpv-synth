@echo off
setlocal
echo Running full mpv-synth installation...

:: Run updater (downloads mpv, VapourSynth, SVPflow, ffmpeg, yt-dlp)
call "%~dp0updater.bat" /u

:: Install (sets PATH, ACLs, etc.)
call "%~dp0installer\mpv-install.bat" /u

:: Pause until everything done for safe self-deletion
echo mpv-synth install complete
pause
:: Self-delete
(goto) 2>nul & del "%~f0"