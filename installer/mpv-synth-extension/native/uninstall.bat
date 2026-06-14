@echo off
echo.
echo  Removing mpv-synth native host registry keys ...

reg delete "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.mpvsynth.launcher"    /f >nul 2>&1
reg delete "HKCU\Software\Mozilla\NativeMessagingHosts\com.mpvsynth.launcher"           /f >nul 2>&1
reg delete "HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.mpvsynth.launcher"    /f >nul 2>&1

echo  Done. You can now delete this folder and remove the extension from your browser.
pause
