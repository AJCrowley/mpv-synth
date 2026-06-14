@echo off
:: mpv-synth Native Messaging Host wrapper
:: The native host manifest points to this file.
:: It launches the Python script using whatever Python 3 is on PATH.

:: Keep the script directory so Python can find the .py file
set "SCRIPT_DIR=%~dp0"

:: Try py launcher first (standard on Windows), then fall back to python
where py >nul 2>&1
if %errorlevel%==0 (
    py "%SCRIPT_DIR%mpv_synth_host.py"
) else (
    python "%SCRIPT_DIR%mpv_synth_host.py"
)
