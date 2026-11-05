@echo OFF
:: -----------------------------------------------------------------------
:: updater.bat -- launcher for updater.ps1
:: If not running as administrator, re-launches itself elevated so that
:: installs directly into Program Files work without the user needing to
:: manually right-click "Run as administrator".
::
:: BOOTSTRAP: before running, checks whether a NEWER updater.ps1 exists in
:: the latest mpv-synth GitHub release and, if so, installs it into
:: installer\ first. This guarantees the migration code that executes is
:: always the newest published version, so an update completes in ONE
:: run instead of requiring two (upgrade the updater, then migrate).
:: -----------------------------------------------------------------------
set unattended=no
if "%1"=="/u" set unattended=yes
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
:: BOOTSTRAP -- verify installer\updater.ps1 is the newest published one.
::  - installed version comes from the registry (1.0.0 when absent)
::  - the local script's own pinned UpdaterVersion counts too (0.0.0 when
::    absent or unparsable, so a clobbered or ancient script is refreshed)
::  - the latest release replaces the local script only when the release is
::    newer than BOTH, so a current updater is never downgraded mid-test
:: -----------------------------------------------------------------------
set "BOOTSTRAP_OK=yes"
powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -Command "$ProgressPreference='SilentlyContinue'; $ErrorActionPreference='Stop'; $root = '%~dp0'; $root = $root.TrimEnd('\\'); $installed = [version]'1.0.0'; try { $installed = [version](Get-ItemPropertyValue 'HKLM:\SOFTWARE\mpv-synth' -Name 'LastUpdateVersion' -ErrorAction Stop) } catch {}; $local = [version]'0.0.0'; try { $m = Select-String -Path ($root + '\installer\updater.ps1') -Pattern 'UpdaterVersion = \[version\]\"+([0-9.]+)\"+' | Select-Object -First 1; $local = [version]$m.Matches[0].Groups[1].Value } catch {}; $rel = Invoke-RestMethod -Uri 'https://api.github.com/repos/AJCrowley/mpv-synth/releases/latest' -UserAgent 'mpv-win-updater'; $latest = [version]$rel.tag_name; if ($latest -le $installed -or $latest -le $local) { exit 0 }; Write-Host ('Bootstrap: release ' + $latest + ' is newer than this updater - fetching it...') -ForegroundColor Cyan; $zip = Join-Path $env:TEMP 'mpv-synth-bootstrap.zip'; $tmp = Join-Path $env:TEMP 'mpv-synth-bootstrap'; Invoke-WebRequest -Uri 'https://github.com/AJCrowley/mpv-synth/releases/latest/download/mpv-synth.zip' -OutFile $zip -UserAgent 'mpv-win-updater'; if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }; Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force; $newps = Get-ChildItem $tmp -Recurse -Filter 'updater.ps1' | Select-Object -First 1; if (-not $newps) { throw 'updater.ps1 not found inside the release archive' }; if ((Get-Item $newps.FullName).Length -lt 50000) { throw 'release updater.ps1 looks too small - refusing the bootstrap' }; Copy-Item $newps.FullName (Join-Path $root 'installer\updater.ps1') -Force; $newbat = Get-ChildItem $tmp -Recurse -Filter 'updater.bat' | Select-Object -First 1; if ($newbat) { Copy-Item $newbat.FullName (Join-Path $root 'updater.bat') -Force }; Remove-Item $zip -Force; Remove-Item $tmp -Recurse -Force; Write-Host 'Bootstrap: updater refreshed from the latest release.' -ForegroundColor Green"
if %errorlevel% neq 0 (
    echo Bootstrap: could not check or fetch the latest updater - continuing with the local copy.
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
:: -----------------------------------------------------------------------
:: Run the script -- prefer pwsh (PS 7+), fall back to Windows PowerShell 5
:: -----------------------------------------------------------------------
where pwsh >nul 2>nul
if %errorlevel% equ 0 (
    pwsh -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%%unattended_flag%
) else (
    powershell -NoProfile -NoLogo -ExecutionPolicy Bypass -File %updater_script%%unattended_flag%
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
