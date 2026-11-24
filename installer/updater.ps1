param(
    [switch]$Unattended,
    [switch]$Installing
)

# ---------------------------------------------------------------------------
# Root directory. Everything (mpv.exe, portable_config, settings.xml, ...) is
# resolved against ONE root so the script behaves the same no matter which
# directory it was started from. updater.bat does pushd to the install root,
# but we do not rely on that: if the current directory does not look like an
# install, try the script's own folder and its parent (installer\..).
# ---------------------------------------------------------------------------
function Resolve-RootDir {
    $candidates = @((Get-Location).Path)
    if ($PSScriptRoot) {
        $candidates += $PSScriptRoot
        $candidates += (Split-Path -Parent $PSScriptRoot)
    }
    foreach ($c in $candidates) {
        if ($c -and ((Test-Path (Join-Path $c "mpv.exe")) -or (Test-Path (Join-Path $c "portable_config")))) {
            return $c
        }
    }
    return (Get-Location).Path
}
$script:Root = Resolve-RootDir
Set-Location -LiteralPath $script:Root
# Native tools (7z, yt-dlp, mpv, ffmpeg) use the PROCESS directory, which
# Set-Location does not change. Keep both in sync.
[Environment]::CurrentDirectory = $script:Root

$UpdaterVersion = [version]"1.2.1"
$fallback7z     = Join-Path $script:Root "7z\7zr.exe"
$useragent      = "mpv-win-updater"
$RegistryRoot   = "HKLM:\SOFTWARE\mpv-synth"
$script:ReleaseDownloaded = $false
$script:ReleaseRoot       = $null
$script:temp_zip          = Join-Path $env:TEMP "mpv-synth.zip"
$script:extract_dir       = Join-Path $env:TEMP "mpv_synth_extract"
# Used only when the GitHub API cannot be reached.
$script:FallbackVapourSynthTag = "R82"

# ===========================================================================
# TEST SWITCH -- run the 1.2.0 migration directly, ignoring the version
# registry entirely:
#   $true  = the next run executes ONLY the 1.2.0 migration code (it keeps
#            the files already in the tree, replaces the VapourSynth runtime
#            with the latest stable release the official way, refreshes the
#            svpflow DLLs and re-asserts VSSCRIPT_PATH).
#   $false = normal behaviour (migrations decided by the registry version).
# Flip to $true to test, flip back to $false before committing/pushing!
# ===========================================================================
$script:ForceMigrationsOnNextRun = $false

# Files inside portable_config\VapourSynth that must survive any wipe-reinstall.
# Everything else in the folder is runtime data that the recipe recreates.
$script:UsersVapourSynthArtifacts = @(
    "vapoursynth.vpy",
    "vapoursynth_fps.txt",
    "vapoursynth_current_path.txt",
    "vapoursynth_params.json",
    "svpflow1_vs.dll",
    "svpflow2_vs.dll",
    "svpflow_version.txt",
    "vapoursynth_runtime.txt"
)

# ---------------------------------------------------------------------------
# Registry helpers
# Failures here MUST be loud (-ErrorAction Stop): a silently unwritable
# version key makes every migration re-run on every launch.
# ---------------------------------------------------------------------------

function Get-InstalledVersion {
    try {
        $v = Get-ItemPropertyValue -Path $RegistryRoot -Name "LastUpdateVersion" -ErrorAction Stop
        return [version]$v
    }
    catch {
        return [version]"1.0.0"
    }
}

function Set-InstalledVersion([version]$Version) {
    if (-not (Test-Path $RegistryRoot)) {
        New-Item -Path $RegistryRoot -Force -ErrorAction Stop | Out-Null
    }
    Set-ItemProperty -Path $RegistryRoot `
                     -Name "LastUpdateVersion" `
                     -Value $Version.ToString() `
                     -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# Release copy helpers (shared by every file-copying migration)
# ---------------------------------------------------------------------------

# If the user's copy differs from the release copy, keep theirs as <name>.bak
# before it is overwritten.
function Backup-IfDifferent([string]$Source, [string]$Target) {
    if (-not (Test-Path -LiteralPath $Target)) { return }
    try {
        $a = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        $b = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
        if ($a -ne $b) {
            Copy-Item -LiteralPath $Target -Destination "$Target.bak" -Force
            Write-Host "Your existing $(Split-Path $Target -Leaf) was backed up as $(Split-Path $Target -Leaf).bak" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Could not back up $Target : $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# Copy specific files from the downloaded release into the install. *.conf
# files are user-editable, so they are backed up first. Any problem throws,
# so a failed migration is NOT recorded as done.
function Copy-ReleaseFiles {
    param([string[]]$Files)

    if (-not $script:ReleaseDownloaded) { Download-Latest-Release }
    $root = $script:ReleaseRoot.FullName

    foreach ($file in $Files) {
        $source = Join-Path $root $file
        $target = Join-Path $script:Root $file

        if (-not (Test-Path -LiteralPath $source)) {
            throw "$file not found in release at $source"
        }

        $targetDir = Split-Path $target -Parent
        if (-not (Test-Path $targetDir)) {
            New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
        }

        if ((Split-Path $file -Leaf) -like "*.conf") {
            Backup-IfDifferent $source $target
        }

        Copy-Item -LiteralPath $source -Destination $target -Force
        Write-Host "Updated $file" -ForegroundColor Green
    }
}

# Copy the whole release over the install (old 1.1.0 / 1.1.3 behaviour),
# backing up any *.conf the user changed.
function Copy-ReleaseTree {
    if (-not $script:ReleaseDownloaded) { Download-Latest-Release }
    $root = $script:ReleaseRoot.FullName

    Get-ChildItem -LiteralPath $root -Recurse -File -Filter "*.conf" -ErrorAction SilentlyContinue | ForEach-Object {
        $rel = $_.FullName.Substring($root.Length).TrimStart('\')
        Backup-IfDifferent $_.FullName (Join-Path $script:Root $rel)
    }

    Write-Host "Copying files..." -ForegroundColor Green
    Copy-Item -Path (Join-Path $root '*') -Destination $script:Root -Recurse -Force
}

# ---------------------------------------------------------------------------
# Migration helpers
# ---------------------------------------------------------------------------
$migrations = @(
    @{
        Version = [version]"1.1.0"
        Script = {
            Ensure-Green-Light @"
Due to significant changes, your config files will have to be updated to allow new features to work. Press 'y' to proceed, or press 'n' and back up your existing config files so you don't lose your custom settings and can integrate your personalised settings into the new config before proceeding with update...
"@
            Upgrade-mpv-Files-110
            Ensure-PythonInstalled
            # subliminal lives in the portable runtime; on a legacy tree the
            # runtime does not exist yet and this is picked up after 1.2.0.
            Install-Subliminal-Portable
            Final-Message @"
Upgrade complete.

Go into your portable_config folder and update mpv.conf with your language preferences.

Go into script-opts and update:
 - auto-subs.conf: Set match to equal your criteria for auto enabling subs, e.g. "En,Forced", as in the example, will automatically activate subtitles when both "en" and "forced" are found in the subtitle track, which usually means in English shows the non-English speaking parts would be automatically subtitled, but you can set it for whatever language(s) you want to auto active, it will only activate if every string of characters in the comma separated list match the track, or completely disable it.
 
 ---
 
 - opensubs.conf: Everything is set up here for English. To change change osub(param)1 and 2 to match your primary and secondary language choices (see https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes for comprehensive reference), e.g.:
   osubname1="English"
   osubcode1a="en"
   osubcode1b="eng"
   osubname2="Espanol"
   osubcode2a="es"
   osubcode2b="es-419"

  Would default the first subtitle search to English (in order full name, 2 char code, 3 or more alternate char code), and the secondary fallback to Spanish. There is also space to add your login info for the popular OpenSubs websites, though this is completely voluntary, and the plugin works fine without it.

  If you haven't already, now is the perfect time to open up portable_config/mpv.conf and edit your language settings in there (no, really, because of a major change to the update system, the default mpv.conf will have possibly changed, and you may need to edit your preference in.

mpv-synth now supports:
 - smart subtitle selection
 - forced subtitle detection
 - OpenSubtitles integration
 - automatic subtitle matching

Either find the OpenSubs controls under the subtitles menu, or:
Press Shift+s to choose subtitles.
Press Alt+t to auto-download the best match.

Future updates are now versioned and any specific changes that need to be made to bring an older version up to date are handled automatically by the updater.

Your previous config files were kept next to the new ones with a .bak extension where they differed.

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.1.1"
        Script = {
            Final-Message @"
Upgrade complete.

If you have something better than stereo sound, go into your portable_config folder and update mpv.conf to match your sound system.

If you are running better than stereo sound setup (e.g. 5.1, 7.1, Dolby Atmos, recommend downloading Dolby Access from Windows Store and enabling Dolby Atmos for home theater on the products page, make sure to click the speakers, as the headphones version is not a free product), you can uncomment the three bottom lines ([correct-speakers]) by removing the # symbol to make sure that mpv is always outputting the right number of channels for your setup, upmixing and downmixing as necessary. The number 6 in the condition is for 5.1, change it to 8 for 7.1 setups. If you're not running a 5.1 or 7.1 setup you don't need to worry about uncommenting this block.

If Windows isn't correctly decoding any surround format, you can set it to bypass Windows Sound Manager and send the digital signal directly to your sound system, just uncomment the 4 lines in the AUDIO SETTINGS portion of the mpv.conf file. audio-spdif and audio-exclusive will lock the sound and send the raw signal to your sound system to decode, note that this will bypass Windows volume control.

Finally, VapourSynth now has an option to automatically set a framerate. Open the file portable_config\script-opts\vapoursynth.conf and set auto-apply to yes if you want it to do it. The defaults are 60fps for 1080p and lower, but you can customize these values to your preference, e.g. change the number to 1280 for only 720p, or up it to 3840 for 4K video if your system can handle it.

I hope to build a better UI for updating and managing configurations for people who aren't comfortable editing text files in the coming months, but the priority will be determined by the number of people who actually use mpv-synth, and it's hard to get a good reading on that as I don't collect telemetry from people (feel free to go to https://buymeacoffee.com/AJCrowley if you want to support the project, that's the best way to let me know that people are using this software and are enthusiastic about it!).

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.1.3"
        Script = {
            Upgrade-mpv-Files-113
            Final-Message @"
Upgrade complete.

OSC skin as supplement to UOSC has been removed and replaced with osc-simplified.

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.1.4"
        Script = {
            Upgrade-mpv-Files-114
            Final-Message @"
Upgrade complete.

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.1.5"
        Script = {
            Upgrade-mpv-Files-115
        }
    }
    @{
        Version = [version]"1.1.6"
        Script = {
            Upgrade-mpv-Files-116
            Final-Message @"
Upgrade complete.

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.2.0"
        Script = {
            Upgrade-mpv-Files-120
            Final-Message @"
Upgrade complete.

SVPflow now uses the open-svpflow DLLs (svpflow1_vs.dll and svpflow2_vs.dll), and vapoursynth.vpy, vapoursynth.lua and vapoursynth.conf have been updated.

The VapourSynth runtime itself was also upgraded to the latest stable release (the officially supported pip layout), and the open-svpflow plugins were installed into it via pip. The svpflow DLLs were kept, and your previous vapoursynth.conf was saved as vapoursynth.conf.bak if it differed from the new one, so you can copy your frame-rate preferences across.

Interpolation behaviour is now controlled from portable_config\script-opts\vapoursynth.conf: every knob (algorithm, motion search quality, masks, scene-change limits, the open-svpflow extras like dedup and the still-text mask, even CPU vs GPU rendering) is documented there and takes effect on the next file you play - no restart needed.

Thanks for using mpv-synth!
"@
        }
    }
    @{
        Version = [version]"1.2.1"
        Script = {
            Upgrade-mpv-Files-121
            Final-Message @"
Upgrade complete.

Playback speed scripts were added and input.conf was updated. If you had customised input.conf, your previous copy was saved as input.conf.bak.

Thanks for using mpv-synth!
"@
        }
    }
)

# ---
# Version update specific functions
# ---

function Upgrade-mpv-Files-110 {
    Write-Host "Updating mpv-synth..." -ForegroundColor Green
    Copy-ReleaseTree
    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-113 {
    Write-Host "Updating mpv-synth..." -ForegroundColor Green
    if (-not $script:ReleaseDownloaded) { Download-Latest-Release }

    Remove-Item -Path (Join-Path $script:Root "portable_config\scripts\osc.lua") -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $script:Root "portable_config\script-opts\osc.conf") -Force -ErrorAction SilentlyContinue

    Copy-ReleaseTree
    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-114 {
    Write-Host "Updating thumbfast.lua..." -ForegroundColor Green
    Copy-ReleaseFiles @("portable_config\scripts\thumbfast.lua")
    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-115 {
    Write-Host "Updating OpenSubs..." -ForegroundColor Green
    # (The old `yt-dlp --update-to nightly` call was removed: a bare name is not
    # resolved from the current directory, so it threw before any file was
    # copied, and Upgrade-Ytplugin already updates yt-dlp on every run.)
    Copy-ReleaseFiles @(
        "portable_config\scripts\opensubs.lua",
        "portable_config\script-opts\opensubs.conf",
        "portable_config\helpers\opensubs_helper.py",
        "portable_config\helpers\fix_opensubs.ps1",
        "portable_config\input.conf"
    )
    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-116 {
    Write-Host "Updating Browser extension, please manually uninstall and reinstall from your browser's extensions..." -ForegroundColor Green
    Copy-ReleaseFiles @(
        "installer\mpv-synth-extension.zip",
        "installer\updater.ps1",
        "portable_config\script-opts\vapoursynth.conf",
        "portable_config\scripts\vapoursynth.lua"
    )
    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-120 {

    Write-Host "Upgrading SVPflow + VapourSynth runtime, vapoursynth.vpy, vapoursynth.lua and vapoursynth.conf..." -ForegroundColor Green

    # TEST SWITCH: in force mode the release may be older than this updater
    # (the release is only rebuilt when Kris publishes), so the files already
    # in the tree are the freshest ones -- keep them and just fix the runtime.
    if ($script:ForceMigrationsOnNextRun) {
        Write-Host "Test-switch active: keeping the vapoursynth.vpy / .lua / .conf already in this tree (no release download)." -ForegroundColor Yellow
    }
    else {
        # Runtime support files from the latest release (vapoursynth.conf is
        # backed up first if the user changed it).
        Copy-ReleaseFiles @(
            "portable_config\VapourSynth\vapoursynth.vpy",
            "portable_config\scripts\vapoursynth.lua",
            "portable_config\script-opts\vapoursynth.conf",
            "portable_config\scripts\opensubs.lua",
            "portable_config\scripts\osc-simplified.lua"
        )
    }

    # Replace the VapourSynth runtime itself. Anything older than the R80+ pip
    # layout cannot run the new open-svpflow plugins, and a partial manual
    # wheel copy leaves a mixed tree. The old runtime is only wiped once the
    # new one has been built successfully (see Install-VapourSynth-Runtime).
    $vs_dir = Join-Path $script:Root "portable_config\VapourSynth"

    if (Test-VapourSynth-Healthy $vs_dir) {
        Write-Host "VapourSynth R80+ runtime already in place -- skipping reinstall." -ForegroundColor Green
    }
    else {
        $null = New-Item -ItemType Directory -Force $vs_dir
        Install-VapourSynth-Runtime $vs_dir -ResetFirst
    }

    # Always refresh the pointers, healthy tree or fresh install.
    Set-VSScriptPath

    # Make sure the SVPflow DLLs are current (open-svpflow releases).
    Get-VSDLLs

    # The runtime may have just been created: install subliminal if it is not there yet.
    Install-Subliminal-Portable -OnlyIfMissing

    # If the vpy still references the ancient DLL names, keep the old files.
    $vpy = Join-Path $vs_dir "vapoursynth.vpy"
    if (Test-Path $vpy) {
        if (Select-String -Path $vpy -Pattern "vs1-x64\.dll|vs2-x64\.dll" -Quiet) {
            Write-Host "Warning: vapoursynth.vpy still references vs1-x64.dll / vs2-x64.dll. Keeping the old DLLs so interpolation keeps working." -ForegroundColor Yellow
            return
        }

        # Remove the old renamed DLLs, but only once the new ones are confirmed present.
        $new1 = Join-Path $vs_dir "svpflow1_vs.dll"
        $new2 = Join-Path $vs_dir "svpflow2_vs.dll"

        if ((Test-Path $new1) -and (Test-Path $new2)) {
            foreach ($old in @("vs1-x64.dll", "vs2-x64.dll")) {
                $oldPath = Join-Path $vs_dir $old
                if (Test-Path $oldPath) {
                    Remove-Item -Path $oldPath -Force -ErrorAction Stop
                    Write-Host "Removed old $old" -ForegroundColor Green
                }
            }
        }
        else {
            Write-Host "Warning: new svpflow DLLs not found in $vs_dir -- keeping old vs1-x64.dll / vs2-x64.dll." -ForegroundColor Yellow
        }
    }

    Write-Host "Update complete." -ForegroundColor Green
}

function Upgrade-mpv-Files-121 {

    Write-Host "Adding playback speed scripts and updating input.conf..." -ForegroundColor Green

    if ($script:ForceMigrationsOnNextRun) {
        Write-Host "Test-switch active: keeping the input.conf / playback-speed files already in this tree (no release download)." -ForegroundColor Yellow
    }
    else {
        Copy-ReleaseFiles @(
            "portable_config\input.conf",
            "portable_config\scripts\playback-speed.lua",
            "portable_config\script-opts\playback-speed.conf"
        )
    }

    Write-Host "Update complete." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Python helpers
# ---------------------------------------------------------------------------

# True only for a genuine Python 3 interpreter (rejects the Microsoft Store
# "python.exe" stub, which exists on PATH but just opens the Store).
function Test-RealPython([string]$Cmd) {
    try {
        $out = (& $Cmd --version 2>&1 | Out-String).Trim()
        return (($LASTEXITCODE -eq 0) -and ($out -match "^Python 3\."))
    }
    catch {
        return $false
    }
}

function Get-PythonCommand {

    # portable_config\VapourSynth\python.exe is a stripped-down "embeddable"
    # Python installed purely for VapourSynth/mpv's own use. It must never be
    # picked as the general-purpose interpreter, however it resolves on PATH.
    $vsPythonDir = Join-Path $script:Root "portable_config\VapourSynth"

    function Test-IsVsPython($path) {
        if (-not $path) { return $false }
        return $path.StartsWith($vsPythonDir, [System.StringComparison]::OrdinalIgnoreCase)
    }

    foreach ($name in @("python", "py")) {
        foreach ($cmd in @(Get-Command $name -All -CommandType Application -ErrorAction SilentlyContinue)) {
            if ($cmd.Source -like "*\WindowsApps\*") { continue }   # Store stub
            if (Test-IsVsPython $cmd.Source) { continue }
            if (Test-RealPython $cmd.Source) { return $cmd.Source }
        }
    }

    # PATH may not have refreshed in this session yet (just after a silent
    # install): check the well-known install locations directly.
    $candidates = @(
        (Get-ChildItem "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue),
        (Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe" -ErrorAction SilentlyContinue)
    ) | Where-Object { $_ -and -not (Test-IsVsPython $_.FullName) } | Sort-Object FullName -Descending

    foreach ($c in $candidates) {
        if (Test-RealPython $c.FullName) { return $c.FullName }
    }

    return $null
}

# Newest python.org release that actually has a Windows installer. Reads the
# FTP directory index (one request) and then probes only the newest few,
# instead of hundreds of blind HEAD requests.
function Get-LatestPythonInstaller {
    $index = Invoke-WebRequestWithRetry -Uri "https://www.python.org/ftp/python/"
    $versions = [regex]::Matches([string]$index.Content, 'href="(3)\.(\d+)\.(\d+)/"') |
        ForEach-Object { [version]("{0}.{1}.{2}" -f $_.Groups[1].Value, $_.Groups[2].Value, $_.Groups[3].Value) } |
        Sort-Object -Descending -Unique |
        Select-Object -First 25

    foreach ($v in $versions) {
        $version = $v.ToString()
        $url = "https://www.python.org/ftp/python/$version/python-$version-amd64.exe"
        try {
            Invoke-WebRequest -Uri $url -Method Head -UseBasicParsing -UserAgent $useragent | Out-Null
            return $url, $version
        }
        catch {
            # Directory exists but has no final installer (pre-release); try the next one.
        }
    }

    throw "Unable to determine the latest Python release."
}

function Install-PythonDirect {
    $url, $version = Get-LatestPythonInstaller
    $installer = Join-Path $env:TEMP "python-$version-amd64.exe"

    Write-Host "Downloading Python $version installer..." -ForegroundColor Green
    Invoke-WebRequest -Uri $url -OutFile $installer -UserAgent $useragent

    Write-Host "Installing Python $version silently (this can take a minute)..." -ForegroundColor Green
    $proc = Start-Process -FilePath $installer -ArgumentList @(
        "/quiet",
        "InstallAllUsers=1",
        "PrependPath=1",
        "Include_launcher=1",
        "Include_test=0"
    ) -Wait -PassThru

    Remove-Item $installer -Force -ErrorAction SilentlyContinue

    if ($proc.ExitCode -ne 0) {
        throw "Python installer exited with code $($proc.ExitCode)"
    }
}

function Refresh-EnvironmentPath {
    $machinePath = [Environment]::GetEnvironmentVariable("Path", "Machine")
    $userPath    = [Environment]::GetEnvironmentVariable("Path", "User")
    $env:Path = "$machinePath;$userPath"
}

# Installs a system Python only if none is present. (winget was dropped:
# `--id Python.Python.3` is ambiguous and always failed, and winget is
# unreliable in elevated sessions. The official installer is deterministic.)
function Ensure-PythonInstalled {

    Write-Host ""
    Write-Host "Checking for Python 3..."

    $pycmd = Get-PythonCommand
    if ($pycmd) {
        Write-Host "$((& $pycmd --version 2>&1 | Out-String).Trim()) already installed."
        return
    }

    Write-Host "Python not found -- installing from python.org..." -ForegroundColor Yellow
    Install-PythonDirect
    Refresh-EnvironmentPath

    $pycmd = Get-PythonCommand
    if (-not $pycmd) {
        throw "Python installation completed but python.exe is still unavailable."
    }
    Write-Host "$((& $pycmd --version 2>&1 | Out-String).Trim()) installed successfully."
}

# Subliminal runs from the mpv-synth portable runtime (embedded python), never
# a machine-wide install: a system interpreter newer than the dependency
# wheels (pyyaml on 3.15) needs a C++ toolchain, and an elevated pip poisons
# the shared cache. Non-fatal: it only powers subtitle downloading.
function Install-Subliminal-Portable {
    param([switch]$OnlyIfMissing)

    $vs_dir = Join-Path $script:Root "portable_config\VapourSynth"
    $py     = Join-Path $vs_dir "python.exe"

    if (-not (Test-Path $py)) {
        Write-Host "Portable runtime not present yet - subliminal will install once VapourSynth is set up." -ForegroundColor Yellow
        return
    }

    if ($OnlyIfMissing) {
        $null = & $py -m pip show subliminal 2>&1
        if ($LASTEXITCODE -eq 0) { return }
    }

    Write-Host "Installing subliminal into the mpv-synth runtime..." -ForegroundColor Green

    # srt (a subliminal dependency) is sdist-only on PyPI, so pip must build
    # it. Give the embedded interpreter the build backend first, then use
    # --no-build-isolation (the isolated env fails to bootstrap setuptools on
    # embedded pythons). --no-cache-dir: an elevated pip cache poisons later
    # non-elevated runs with [Errno 13].
    & $py -m pip install --no-cache-dir setuptools wheel
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Could not install the python build tools - subliminal cannot install this pass; will retry next run." -ForegroundColor Yellow
        return
    }
    & $py -m pip install --no-cache-dir --no-build-isolation --upgrade subliminal
    if ($LASTEXITCODE -ne 0) {
        Write-Host "Subliminal install failed this pass - subtitle downloading may not work; will retry next run." -ForegroundColor Yellow
    }
}

# Replaces the old Upgrade-Python. Nothing in mpv-synth uses the system Python
# for packages any more, so it is only ensured to exist (never upgraded), and
# any machine-wide subliminal left by older versions is removed.
function Update-PythonEnvironment {

    Write-Host ""
    try { Ensure-PythonInstalled }
    catch { Write-Host "System Python step failed: $($_.Exception.Message)" -ForegroundColor Yellow }

    try {
        $pycmd = Get-PythonCommand
        if ($pycmd) {
            $null = & $pycmd -m pip show subliminal 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-Host "Removing the machine-wide subliminal (it now lives in the mpv-synth runtime)..."
                & $pycmd -m pip uninstall -y subliminal | Out-Null
            }
        }
    }
    catch { }

    Install-Subliminal-Portable
    Write-Host "Python environment updated." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# Release download
# ---------------------------------------------------------------------------

function Download-Latest-Release {
    Write-Host "Downloading mpv-synth latest release..." -ForegroundColor Green

    $zip_url = "https://github.com/AJCrowley/mpv-synth/releases/latest/download/mpv-synth.zip"

    Invoke-WebRequestWithRetry -Uri $zip_url -OutFile $script:temp_zip

    if (Test-Path $script:extract_dir) {
        Remove-Item $script:extract_dir -Recurse -Force
    }
    Expand-Archive -LiteralPath $script:temp_zip -DestinationPath $script:extract_dir -Force

    # The zip normally has one wrapper folder, but accept a flat layout too.
    $flat = (Test-Path (Join-Path $script:extract_dir "portable_config")) -or
            (Test-Path (Join-Path $script:extract_dir "installer"))
    if ($flat) {
        $script:ReleaseRoot = Get-Item $script:extract_dir
    }
    else {
        $script:ReleaseRoot = Get-ChildItem $script:extract_dir -Directory | Select-Object -First 1
    }

    if (-not $script:ReleaseRoot) {
        throw "The downloaded release archive was empty or had an unexpected layout."
    }
    $script:ReleaseDownloaded = $true
}

function Clean-Downloaded {
    if ($script:ReleaseDownloaded) {
        if ($script:temp_zip -and (Test-Path $script:temp_zip)) {
            Remove-Item $script:temp_zip -Force -ErrorAction SilentlyContinue
        }
        if ($script:extract_dir -and (Test-Path $script:extract_dir)) {
            Remove-Item $script:extract_dir -Recurse -Force -ErrorAction SilentlyContinue
        }
        $script:ReleaseDownloaded = $false
    }
}

function Complete-SelfUpdate {
    $dst_installer = Join-Path $script:Root "installer"
    $temp_installer = "$dst_installer.new"

    $dst_updater = $PSCommandPath
    $temp_updater = "$dst_updater.new"

    if (-not (Test-Path $temp_installer) -and -not (Test-Path $temp_updater)) {
        return
    }

    Write-Host "Finalising updater replacement after exit..." -ForegroundColor Green

    # Single quotes inside paths must be doubled inside a '...' literal.
    function Q([string]$s) { return $s.Replace("'", "''") }

    $commands = @()
    $commands += 'Start-Sleep -Seconds 2'

    if (Test-Path $temp_installer) {
        $commands += "if (Test-Path '$(Q $dst_installer)') { Remove-Item '$(Q $dst_installer)' -Recurse -Force }"
        $commands += "Move-Item '$(Q $temp_installer)' '$(Q $dst_installer)' -Force"
    }

    if (Test-Path $temp_updater) {
        $commands += "Move-Item '$(Q $temp_updater)' '$(Q $dst_updater)' -Force"
    }

    $commandString = $commands -join '; '

    Start-Process powershell -WindowStyle Hidden -ArgumentList @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-Command',
        $commandString
    )
}

function Ensure-Green-Light {

    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Unattended) {
        Write-Host "Unattended mode: continuing without confirmation. Changed config files are saved as *.bak." -ForegroundColor Yellow
        return
    }

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host "IMPORTANT UPDATE NOTICE" -ForegroundColor Yellow
    Write-Host "============================================================" -ForegroundColor Yellow
    Write-Host ""
    Write-Host $Message -ForegroundColor White
    Write-Host ""
    Write-Host "It is strongly recommended that you back up your existing" -ForegroundColor DarkYellow
    Write-Host "installation before continuing." -ForegroundColor DarkYellow
    Write-Host ""

    while ($true) {

        $response = Read-Host "Continue? (Y/N)"

        switch ($response.Trim().ToUpper()) {

            "Y" {
                Write-Host ""
                Write-Host "Continuing update..." -ForegroundColor Green
                Write-Host ""
                return
            }

            "N" {
                Write-Host ""
                Write-Host "Update cancelled by user." -ForegroundColor Red
                exit 1
            }

            default {
                Write-Host "Please enter Y or N." -ForegroundColor Yellow
            }
        }
    }
}

function Final-Message {

    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host "UPDATE COMPLETE" -ForegroundColor Green
    Write-Host "============================================================" -ForegroundColor Green
    Write-Host ""

    Write-Host $Message -ForegroundColor White

    Write-Host ""
}

function Invoke-Migrations {

    $installed = Get-InstalledVersion

    Write-Host "Installed version: $installed"
    Write-Host "Updater version:   $UpdaterVersion"

    # TEST SWITCH: run only the 1.2.0 migration straight away, ignoring the
    # registry and every other migration block.
    if ($script:ForceMigrationsOnNextRun) {
        Write-Host ""
        Write-Host "*** TEST SWITCH ACTIVE -- forcing the 1.2.0 migration directly ***" -ForegroundColor Magenta
        Write-Host "" -ForegroundColor Magenta

        $forced = $migrations | Where-Object { $_.Version -eq [version]"1.2.0" }
        if (-not $forced) {
            throw "The 1.2.0 migration block was not found in updater.ps1."
        }

        Write-Host "Running migration 1.2.0 (forced)" -ForegroundColor Cyan
        try {
            & $forced.Script
            # Never LOWER the recorded version (it may already be 1.2.1+).
            if ($forced.Version -gt $installed) {
                Set-InstalledVersion $forced.Version
            }
            else {
                Write-Host "Registry version is already $installed -- not lowering it." -ForegroundColor Yellow
            }
            Write-Host "Migration completed." -ForegroundColor Green
        }
        catch {
            Write-Host "Migration failed." -ForegroundColor Red
            throw
        }
        return
    }

    foreach ($migration in ($migrations | Sort-Object { $_.Version })) {

        if ($migration.Version -gt $installed) {

            Write-Host ""
            Write-Host "Running migration $($migration.Version)" -ForegroundColor Cyan

            try {
                & $migration.Script

                # Only reached when the migration did not throw, so a failed
                # migration is retried on the next run instead of being skipped.
                Set-InstalledVersion $migration.Version

                Write-Host "Migration completed." -ForegroundColor Green
            }
            catch {
                Write-Host "Migration $($migration.Version) failed: $($_.Exception.Message)" -ForegroundColor Red
                Write-Host "It will be retried the next time the updater runs." -ForegroundColor Yellow
                throw
            }
        }
    }
}

# ---------------------------------------------------------------------------
# 7-Zip helpers
# ---------------------------------------------------------------------------

function Get-7z {
    $cmd = Get-Command -CommandType Application -ErrorAction Ignore 7z.exe |
           Select-Object -Last 1
    if ($cmd) { return $cmd.Source }

    $dir = Get-ItemPropertyValue -ErrorAction Ignore `
               "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\7-Zip" `
               "InstallLocation"
    if ($dir -and (Test-Path (Join-Path $dir "7z.exe"))) {
        return Join-Path $dir "7z.exe"
    }

    if (Test-Path $fallback7z) { return $fallback7z }
    return $null
}

# NOTE: the fallback 7zr.exe can only handle .7z archives. Zip files
# (Deno) are extracted with Expand-Archive instead.
function Check-7z {
    if (-not (Get-7z)) {
        $null = New-Item -ItemType Directory -Force (Split-Path $fallback7z)
        Write-Host "Downloading 7zr.exe" -ForegroundColor Green
        Invoke-WebRequestWithRetry -Uri "https://www.7-zip.org/a/7zr.exe" -OutFile $fallback7z
    }
    else {
        Write-Host "7z already exists. Skipped download." -ForegroundColor Green
    }
}

function Extract-Archive {
    param(
        [string]   $Archive,
        [string[]] $Exclude = @()
    )
    $7z = Get-7z
    Write-Host "Extracting $Archive" -ForegroundColor Green

    $excludeArgs = $Exclude | ForEach-Object { "-xr!$_" }
    & $7z x -y $Archive @excludeArgs
    if ($LASTEXITCODE -ne 0) {
        throw "7-Zip failed to extract $Archive (exit code $LASTEXITCODE)"
    }
}

# $digest is optional and uses GitHub's "sha256:<hex>" asset-digest format.
function Download-Archive ($filename, $link, $digest) {
    Write-Host "Downloading $filename" -ForegroundColor Green
    Invoke-WebRequestWithRetry -Uri $link -OutFile $filename

    if ($digest -and ($digest -match '^sha256:([0-9a-fA-F]{64})$')) {
        $expected = $Matches[1]
        $actual = (Get-FileHash -LiteralPath $filename -Algorithm SHA256).Hash
        if ($actual -ine $expected) {
            Remove-Item -LiteralPath $filename -Force -ErrorAction SilentlyContinue
            throw "Checksum mismatch for $filename (expected $expected, got $actual)"
        }
        Write-Host "SHA256 verified." -ForegroundColor Green
    }
}

function Check-PowershellVersion {
    $version = $PSVersionTable.PSVersion.Major
    Write-Host "Checking Windows PowerShell version -- $version" -ForegroundColor Green
    # Expand-Archive and Get-ItemPropertyValue need PowerShell 5.0+.
    if ($version -lt 5) {
        Write-Host "PowerShell $version is unsupported (5.0 or newer required). Please upgrade." -ForegroundColor Red
        throw "PowerShell $version is unsupported."
    }
}

# Full path of a yt-dlp / youtube-dl exe in the install folder, or $null.
function Check-Ytplugin {
    $found = @(Get-ChildItem -LiteralPath $script:Root -Filter "yt-dlp*.exe" -File -ErrorAction Ignore | Sort-Object Name)
    if ($found.Count -gt 0) { return $found[0].FullName }

    $yd = Join-Path $script:Root "youtube-dl.exe"
    if (Test-Path $yd) { return $yd }
    return $null
}

function Check-Ytplugin-In-System {
    $ytp = Get-Command -CommandType Application -ErrorAction Ignore yt-dlp.exe |
           Select-Object -Last 1
    if (-not $ytp) {
        $ytp = Get-Command -CommandType Application -ErrorAction Ignore youtube-dl.exe |
               Select-Object -Last 1
    }
    if (-not $ytp) { return $false }
    $dir = (Split-Path $ytp.Source).TrimEnd('\')
    return ($dir -ine $script:Root.TrimEnd('\'))
}

function Get-Latest-Ytplugin ($plugin) {
    switch -wildcard ($plugin) {
        "yt-dlp*" {
            # Kris (19:14): the nightly channel is permanent; the
            # stable/master choice was removed along with Check-Ytdlp-Channel.
            $repo = "https://github.com/yt-dlp/yt-dlp-nightly-builds"
            Write-Host "Fetching RSS feed for yt-dlp nightly" -ForegroundColor Green
            $resp    = [xml](Invoke-WebRequest "$repo/releases.atom" `
                            -MaximumRedirection 0 -ErrorAction Ignore -UseBasicParsing).Content
            $version = $resp.feed.entry[0].link.href.split("/")[-1]
            return $version
        }
        "youtube-dl" {
            Write-Host "Fetching RSS feed for youtube-dl" -ForegroundColor Green
            $resp    = Invoke-WebRequest "https://yt-dl.org/downloads/latest/youtube-dl.exe" `
                           -MaximumRedirection 0 -ErrorAction Ignore -UseBasicParsing
            $version = $resp.Headers.Location.split("/")[4]
            return $version
        }
    }
}

function Download-Ytplugin ($plugin, $version) {
    switch -wildcard ($plugin) {
        "yt-dlp*" {
            Write-Host "Downloading $plugin ($version)" -ForegroundColor Green
            $suffix = if (Test-Path (Join-Path $env:windir "SysWow64")) { "" } else { "_x86" }
            # nightly channel is permanent (see Get-Latest-Ytplugin)
            $repo = "https://github.com/yt-dlp/yt-dlp-nightly-builds"
            $exe  = "$plugin$suffix.exe"
            $link = "$repo/releases/download/$version/$exe"
            Invoke-WebRequestWithRetry -Uri $link -OutFile (Join-Path $script:Root $exe)
        }
        "youtube-dl" {
            Write-Host "Downloading $plugin ($version)" -ForegroundColor Green
            $link = "https://yt-dl.org/downloads/$version/youtube-dl.exe"
            Invoke-WebRequestWithRetry -Uri $link -OutFile (Join-Path $script:Root "youtube-dl.exe")
        }
    }
}

# Unauthenticated GitHub API calls are limited to 60/hour per IP. Set a
# GITHUB_TOKEN environment variable to lift that. Returns $null on failure.
function Get-LatestGithubRelease ($repo) {
    $api = "https://api.github.com/repos/$repo/releases/latest"
    try {
        $params = @{
            Uri             = $api
            UseBasicParsing = $true
            UserAgent       = $useragent
            ErrorAction     = "Stop"
        }
        if ($env:GITHUB_TOKEN) {
            $params.Headers = @{ Authorization = "Bearer $($env:GITHUB_TOKEN)" }
        }
        return (Invoke-WebRequest @params).Content | ConvertFrom-Json
    }
    catch {
        Write-Host "GitHub API request for $repo failed: $($_.Exception.Message)" -ForegroundColor Yellow
        return $null
    }
}

function Get-Latest-Mpv ($Arch) {
    $json = Get-LatestGithubRelease "shinchiro/mpv-winbuild-cmake"
    if (-not $json -or -not $json.assets) {
        throw "Could not query GitHub for the latest mpv build (network problem or API rate limit)."
    }
    $asset = $json.assets | Where-Object { $_.name -match "^mpv-$Arch-[0-9]{8}" } |
             Select-Object -First 1
    if (-not $asset) {
        throw "No mpv build for '$Arch' was found in the latest release."
    }
    return $asset.name, $asset.browser_download_url, $asset.digest
}

function Get-Arch {
    $FilePath = Join-Path $script:Root 'mpv.exe'
    [byte[]]$data   = New-Object System.Byte[] 4096
    $stream = New-Object System.IO.FileStream($FilePath, 'Open', 'Read')
    $stream.Read($data, 0, 4096) | Out-Null
    $stream.Close()

    $peAddr  = [System.BitConverter]::ToInt32($data, 60)
    $machine = [System.BitConverter]::ToUInt16($data, $peAddr + 4)

    $result = "" | Select-Object FilePath, FileType
    $result.FilePath = $FilePath
    $result.FileType = switch ($machine) {
        0      { 'Native'  }
        0x014c { 'i686'    }
        0x0200 { 'Itanium' }
        0x8664 { 'x86_64'  }
    }
    return $result
}

function ExtractGitFromFile {
    $mpv = Join-Path $script:Root "mpv.exe"
    # --version prints the banner and exits (no window / no waiting for input).
    $stripped = (& $mpv --version 2>&1) | Select-String "mpv" | Select-Object -First 1
    # Length range, not an exact 7: shinchiro hashes are 10 chars
    # (e.g. -g3138fc8eea) so an exact {7} silently missed.
    if ($stripped -and ($stripped.ToString() -match "-g([0-9a-f]{7,12})")) { return $matches[1] }
    return $null
}

function ExtractGitFromURL ($filename) {
    if ($filename -match "-git-([a-z0-9]{7,12})") { return $matches[1] }
    return $null
}

# Short and long git hashes of the same commit differ only in length, so
# compare by prefix (the old `-match` failed whenever the local hash was the
# shorter one).
function Test-GitMatch($a, $b) {
    if (-not $a -or -not $b) { return $false }
    return ($a.StartsWith($b, [System.StringComparison]::OrdinalIgnoreCase) -or
            $b.StartsWith($a, [System.StringComparison]::OrdinalIgnoreCase))
}

function ExtractDateFromFile {
    $date = (Get-Item (Join-Path $script:Root "mpv.exe")).LastWriteTimeUtc
    return "$($date.Year.ToString('0000'))$($date.Month.ToString('00'))$($date.Day.ToString('00'))"
}

function ExtractDateFromURL ($filename) {
    if ($filename -match "mpv-[xi864_].*-([0-9]{8})-git-([a-z0-9-]{7,12})") { return $matches[1] }
    return $null
}

function Ensure-Deno ([string]$Context = "update") {
    $deno_exe = Join-Path $script:Root "deno.exe"

    if (Test-Path $deno_exe) {
        $remote_name = ([string](Invoke-WebRequestWithRetry -Uri "https://dl.deno.land/release-latest.txt").Content).Trim()
        try {
            $current = (& $deno_exe --version | Select-String "deno" | Select-Object -First 1).ToString()
            if ([Regex]::Match($current, "deno\s+(?<ver>[0-9a-zA-Z\.-]+)").Groups['ver'].Value `
                    -eq $remote_name.TrimStart('v')) {
                Write-Host "You are already using latest Deno -- $remote_name" -ForegroundColor Green
                return
            }
            Write-Host "Newer Deno build available" -ForegroundColor Green
        }
        catch {
            Write-Host "Error checking current Deno version: $($_.Exception.Message)" -ForegroundColor Yellow
        }
        if ((Read-KeyOrTimeout "Upgrade local Deno to latest stable now? [Y/n] (default=y)" "Y") -eq 'Y') {
            & $deno_exe upgrade
        }
        Write-Host ""
        return
    }

    if ($Context -ne 'install') { return }

    if (-not (Test-Path (Join-Path $env:windir "SysWow64"))) {
        Write-Host "Deno isn't available for 32-bit Windows. Skipping." -ForegroundColor Yellow
        return
    }

    Write-Host "Deno is optional, but recommended for yt-dlp." -ForegroundColor Yellow
    Write-Host "yt-dlp uses external JS runtimes (EJS) to solve YouTube challenges; Deno is the default." -ForegroundColor Yellow
    Write-Host "You may skip this and configure Node, Bun, or QuickJS later (see: https://github.com/yt-dlp/yt-dlp/wiki/EJS)." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "Deno not found. " -ForegroundColor Green -NoNewline
    if ((Read-KeyOrTimeout "Proceed with downloading Deno now? [Y/n] (default=y)" "Y") -ne 'Y') { return }
    Write-Host ""

    $remote_name   = ([string](Invoke-WebRequestWithRetry -Uri "https://dl.deno.land/release-latest.txt").Content).Trim()
    $archive       = "deno-x86_64-pc-windows-msvc.zip"
    $download_link = "https://dl.deno.land/release/$remote_name/$archive"
    $archive_path  = Join-Path $script:Root $archive
    Write-Host "Downloading Deno (stable) $remote_name" -ForegroundColor Green
    Download-Archive $archive_path $download_link
    # .zip: Expand-Archive, NOT 7z (the fallback 7zr.exe cannot read zips).
    Expand-Archive -LiteralPath $archive_path -DestinationPath $script:Root -Force
    Check-Autodelete $archive_path
}

function Stop-Mpv {
    # Close any running mpv so nothing it has loaded (mpv.exe, VapourSynth/SVPflow DLLs,
    # scripts) is locked while files are overwritten or deleted.
    if (-not (Get-Process -Name mpv -ErrorAction SilentlyContinue)) { return }

    Write-Host "Closing running mpv instance(s)..." -ForegroundColor Yellow
    & taskkill /F /IM mpv.exe 2>&1 | Out-Null

    # Wait (up to ~10s) for the process to actually exit and release its file handles.
    for ($i = 0; $i -lt 20; $i++) {
        if (-not (Get-Process -Name mpv -ErrorAction SilentlyContinue)) { break }
        Start-Sleep -Milliseconds 500
    }
    if (Get-Process -Name mpv -ErrorAction SilentlyContinue) {
        Write-Host "Warning: mpv is still running; some files may be locked." -ForegroundColor Red
    }
    else {
        Start-Sleep -Seconds 1
    }
}

function Test-Admin {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

function Create-XML {
@"
<settings>
  <arch>unset</arch>
  <autodelete>unset</autodelete>
  <getffmpeg>unset</getffmpeg>
  <getffprobe>unset</getffprobe>
  <getytdl>unset</getytdl>
  <ytdlpchannel>unset</ytdlpchannel>
</settings>
"@ | Set-Content (Join-Path $script:Root "settings.xml") -Encoding UTF8
}

function Get-SettingsDoc {
    $file = Join-Path $script:Root "settings.xml"
    if (-not (Test-Path $file)) { Create-XML }
    return [xml](Get-Content $file -Raw), $file
}

function Check-Arch ($arch) {
    $doc, $file = Get-SettingsDoc
    if ($doc.settings.arch -eq "unset") {
        $get_arch = if ($arch -eq "i686") {
            "i686"
        }
        else {
            $result = Read-KeyOrTimeout `
                "Choose variant: x86_64-v3 (AVX2) or x86_64 [1=x86_64-v3 / 2=x86_64 (default=1)]" "D1"
            Write-Host ""
            switch ($result) {
                'D1' { "x86_64-v3" }
                'D2' { "x86_64" }
                default { Write-Host "Invalid input -- using default: x86_64-v3" -ForegroundColor Yellow; "x86_64-v3" }
            }
        }
        $doc.settings.arch = $get_arch
        $doc.Save($file)
        return $get_arch
    }
    return $doc.settings.arch
}

function Check-Autodelete ($archive) {
    $doc, $file = Get-SettingsDoc
    if ($doc.settings.autodelete -eq "unset") {
        $result = Read-KeyOrTimeout "Delete archives after extract? [Y/n] (default=Y)" "Y"
        Write-Host ""
        $doc.settings.autodelete = switch ($result) {
            'Y' { "true" }
            'N' { "false" }
            default { Write-Host "Invalid input -- using default: Y" -ForegroundColor Yellow; "true" }
        }
        $doc.Save($file)
    }
    if ($doc.settings.autodelete -eq "true" -and (Test-Path $archive)) {
        Remove-Item -Force $archive
    }
}

function Check-GetFFmpeg {
    $doc, $file = Get-SettingsDoc
    $ffmpeg_missing  = -not (Test-Path (Join-Path $script:Root "ffmpeg.exe"))
    $ffprobe_missing = -not (Test-Path (Join-Path $script:Root "ffprobe.exe"))
    $either_missing  = $ffmpeg_missing -or $ffprobe_missing

    if ($doc.settings.getffmpeg -eq "unset" -or $either_missing) {
        $missing_list = @()
        if ($ffmpeg_missing)  { $missing_list += "ffmpeg.exe"  }
        if ($ffprobe_missing) { $missing_list += "ffprobe.exe" }
        $missing_str = $missing_list -join " and "
        Write-Host "$missing_str not found. " -ForegroundColor Green -NoNewline
        $result = Read-KeyOrTimeout "Proceed with downloading? [Y/n] (default=Y)" "Y"
        Write-Host ""
        $doc.settings.getffmpeg = switch ($result) {
            'Y' { "true" }
            'N' { "false" }
            default { Write-Host "Invalid input -- using default: Y" -ForegroundColor Yellow; "true" }
        }
        $doc.Save($file)
    }
    return $doc.settings.getffmpeg
}

function Check-GetYTDL {
    $doc, $file = Get-SettingsDoc

    if ($null -eq $doc.settings.getytdl) {
        $yt       = Check-Ytplugin
        $get_ytdl = if ($null -eq $yt) {
            "unset"
        }
        elseif ((Get-Item $yt).BaseName -like "yt-dlp*") {
            "ytdlp"
        }
        else {
            "youtubedl"
        }
        $node = $doc.CreateElement("getytdl")
        $node.AppendChild($doc.CreateTextNode($get_ytdl)) | Out-Null
        $doc.settings.AppendChild($node) | Out-Null
        $doc.Save($file)
    }

    $get_ytdl = $doc.settings.getytdl
    if ($get_ytdl -eq "unset") {
        $result   = Read-KeyOrTimeout "Download ytdlp or youtubedl? [1=ytdlp/2=youtubedl/N] (default=1)" "D1"
        Write-Host ""
        $get_ytdl = switch ($result) {
            'D1' { "ytdlp" }
            'D2' { "youtubedl" }
            'N'  { "false" }
            default { Write-Host "Invalid input -- using default: yt-dlp" -ForegroundColor Yellow; "ytdlp" }
        }
        $doc.settings.getytdl = $get_ytdl
        $doc.Save($file)
    }
    return $get_ytdl
}

function Check-Mpv {
    return Test-Path (Join-Path $script:Root "mpv.exe")
}

function Upgrade-Mpv {
    $need_download = $false
    $arch = ""
    $remoteName = ""
    $download_link = ""
    $digest = $null

    if (Check-Mpv) {
        $arch = Check-Arch (Get-Arch).FileType
        $remoteName, $download_link, $digest = Get-Latest-Mpv $arch
        $localgit   = ExtractGitFromFile
        $localdate  = ExtractDateFromFile
        $remotegit  = ExtractGitFromURL $remoteName
        $remotedate = ExtractDateFromURL $remoteName

        if ((Test-GitMatch $localgit $remotegit) -and $localdate -and ($localdate -eq $remotedate)) {
            Write-Host "You are already using latest mpv build -- $remoteName" -ForegroundColor Green
        }
        else {
            if (-not $localgit -or -not $localdate) {
                Write-Host "Could not read the current mpv build info from .\mpv.exe -- assuming a newer build is available." -ForegroundColor Yellow
            }
            Write-Host "Newer mpv build available" -ForegroundColor Green
            $need_download = $true
        }
    }
    else {
        Write-Host "mpv not found. " -ForegroundColor Green -NoNewline
        $result = Read-KeyOrTimeout "Proceed with downloading? [Y/n] (default=y)" "Y"
        Write-Host ""
        if ($result -eq 'Y') {
            $need_download   = $true
            $original_arch   = if (Test-Path (Join-Path $env:windir "SysWow64")) {
                Write-Host "Detected 64-bit system" -ForegroundColor Green; "x86_64"
            }
            else {
                Write-Host "Detected 32-bit system" -ForegroundColor Green; "i686"
            }
            $arch = Check-Arch $original_arch
            $remoteName, $download_link, $digest = Get-Latest-Mpv $arch
        }
        elseif ($result -ne 'N') {
            Write-Host "Invalid input -- skipping mpv download" -ForegroundColor Yellow
        }
    }

    if ($need_download) {
        $archive_path = Join-Path $script:Root $remoteName
        Download-Archive $archive_path $download_link $digest
        Check-7z
        Extract-Archive $archive_path -Exclude @("*.bat", "*.ps1", "doc", "installer")
    }
    if ($remoteName) { Check-Autodelete (Join-Path $script:Root $remoteName) }
}

function Upgrade-Ytplugin {
    if (Check-Ytplugin-In-System) {
        Write-Host "yt-dlp or youtube-dl already exists in system PATH, skipping update." -ForegroundColor Green
        return
    }

    $yt = Check-Ytplugin
    if ($yt) {
        if ((Get-Item $yt).BaseName -like "yt-dlp*") {
            # Kris (19:14): always update to the nightly channel; the
            # stable/master choice is gone. yt-dlp exits quickly when it
            # is already current, so running it every pass is cheap.
            Write-Host "Updating yt-dlp (nightly channel)..." -ForegroundColor Green
            & $yt --update-to nightly
            Ensure-Deno "update"
        }
        else {
            $latest = Get-Latest-Ytplugin((Get-Item $yt).BaseName)
            if ((& $yt --version) -match $latest) {
                Write-Host "You are already using latest $((Get-Item $yt).BaseName) -- $latest" -ForegroundColor Green
            }
            else {
                Write-Host "Newer $((Get-Item $yt).BaseName) build available" -ForegroundColor Green
                & $yt --update
            }
        }
    }
    else {
        Write-Host "yt-dlp / youtube-dl not found. " -ForegroundColor Green -NoNewline
        $ytdl = Check-GetYTDL
        switch ($ytdl) {
            'ytdlp' {
                Download-Ytplugin "yt-dlp" (Get-Latest-Ytplugin "yt-dlp")
                Ensure-Deno "install"
            }
            'youtubedl' {
                Download-Ytplugin "youtube-dl" (Get-Latest-Ytplugin "youtube-dl")
            }
            'false' { }
            default { Write-Host "Invalid input -- skipping yt-dlp download" -ForegroundColor Yellow }
        }
    }
}

# gyan.dev (and GitHub) occasionally 503 under load; a couple of retries with
# a pause turns that from a failed step into a successful pass most of the
# time (warn-and-continue still covers the rest).
function Invoke-WebRequestWithRetry {
    param(
        [string]$Uri,
        [string]$OutFile
    )
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            if ($OutFile) {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -UseBasicParsing -UserAgent $useragent
                return
            }
            else {
                return Invoke-WebRequest -Uri $Uri -UseBasicParsing -UserAgent $useragent
            }
        }
        catch {
            if ($attempt -ge 3) { throw }
            Write-Host "Request failed (attempt $attempt): $($_.Exception.Message) -- retrying in 5s..." -ForegroundColor Yellow
            Start-Sleep -Seconds 5
        }
    }
}

function Upgrade-FFmpeg {
    if ((Check-GetFFmpeg) -eq "false") { return }

    $ver_url      = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z.ver"
    $archive_url  = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z"
    $archive_name = "ffmpeg-git-essentials.7z"
    $archive_path = Join-Path $script:Root $archive_name

    $resp = Invoke-WebRequestWithRetry -Uri $ver_url
    # Content is byte[] or string depending on the server's content type / PS version.
    $content = $resp.Content
    $remote_ver = if ($content -is [byte[]]) { [System.Text.Encoding]::UTF8.GetString($content) } else { [string]$content }
    $remote_ver = $remote_ver.Trim()
    Write-Host "Latest ffmpeg/ffprobe build: $remote_ver" -ForegroundColor Green

    $ffmpeg_path  = Join-Path $script:Root "ffmpeg.exe"
    $ffprobe_path = Join-Path $script:Root "ffprobe.exe"
    $need_download = $false

    if (Test-Path $ffmpeg_path) {
        $local_ver = ((& $ffmpeg_path -version | Select-String "ffmpeg version" |
                       Select-Object -First 1).ToString()).Trim()
        # No end-of-string anchor: the .ver string usually continues after the
        # hash (e.g. "...-git-abc123-essentials_build-www.gyan.dev"). If no
        # hash can be parsed, fall back to comparing the whole string -- never
        # to an empty pattern, which matches everything and blocks updates.
        $commit = [Regex]::Match($remote_ver, "git-([a-z0-9]+)").Groups[1].Value
        $up_to_date = if ($commit) {
            $local_ver -match [Regex]::Escape($commit)
        }
        else {
            $local_ver.Contains($remote_ver)
        }
        if ($up_to_date) {
            Write-Host "ffmpeg is already up to date -- $remote_ver" -ForegroundColor Green
        }
        else {
            Write-Host "Newer ffmpeg build available -- $remote_ver" -ForegroundColor Green
            $need_download = $true
        }
    }
    else {
        $need_download = $true
    }

    if (-not (Test-Path $ffprobe_path)) {
        Write-Host "ffprobe.exe not found -- will download" -ForegroundColor Yellow
        $need_download = $true
    }

    if ($need_download) {
        Write-Host "Downloading $archive_name" -ForegroundColor Green
        Invoke-WebRequestWithRetry -Uri $archive_url -OutFile $archive_path
        Check-7z
        $7z = Get-7z
        & $7z e -y "-o$($script:Root)" $archive_path "ffmpeg.exe" "ffprobe.exe" -r
        if (Test-Path $ffmpeg_path)  { Write-Host "ffmpeg.exe  extracted OK" -ForegroundColor Green }
        else                         { Write-Host "ffmpeg.exe  NOT found after extraction" -ForegroundColor Red }
        if (Test-Path $ffprobe_path) { Write-Host "ffprobe.exe extracted OK" -ForegroundColor Green }
        else                         { Write-Host "ffprobe.exe NOT found after extraction" -ForegroundColor Red }
        Check-Autodelete $archive_path
    }
}

# Prompts with a timeout. In unattended mode (or when there is no usable
# console, e.g. a scheduled task) it never touches the console and simply
# returns the default.
function Read-KeyOrTimeout ($prompt, $key) {
    if ($Unattended -or [Console]::IsInputRedirected) {
        Write-Host "$prompt -> unattended, using default ($key)" -ForegroundColor DarkGray
        return $key.ToString()
    }

    try {
        $seconds   = 9
        $startTime = Get-Date
        $timeOut   = New-TimeSpan -Seconds $seconds

        Write-Host "$prompt " -ForegroundColor Green
        [Console]::CursorLeft = 0
        [Console]::Write("[")
        [Console]::CursorLeft = $seconds + 2
        [Console]::Write("]")
        [Console]::CursorLeft = 1

        while (-not [System.Console]::KeyAvailable) {
            Start-Sleep -s 1
            Write-Host "#" -ForegroundColor Green -NoNewline
            if ((Get-Date) -gt $startTime + $timeOut) { break }
        }

        $response = if ([System.Console]::KeyAvailable) {
            [System.Console]::ReadKey($true).Key
        }
        else {
            $key
        }
        return $response.ToString()
    }
    catch {
        # Console APIs unavailable: behave as unattended.
        return $key.ToString()
    }
}

# ---------------------------------------------------------------------------
# VapourSynth runtime
# ---------------------------------------------------------------------------

# A present-but-mixed tree (a manual wheel copy) can contain the script host
# without the embedded python or the pip-installed plugins, so vsscript.dll
# alone is NOT proof of a healthy R80+ runtime. The plugin check asks pip
# instead of assuming a folder layout.
function Test-VapourSynth-Healthy {
    param([string]$VSDir)

    $vsscript = Join-Path $VSDir "Lib\site-packages\vapoursynth\vsscript.dll"
    $py       = Join-Path $VSDir "python.exe"

    foreach ($check in @($vsscript, $py)) {
        if (-not (Test-Path $check)) {
            Write-Host "VapourSynth health check failed: missing $(Split-Path $check -Leaf) in $VSDir" -ForegroundColor Yellow
            return $false
        }
    }

    try {
        $null = & $py -m pip show open-svpflow 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "VapourSynth health check failed: open-svpflow is not installed in the portable runtime." -ForegroundColor Yellow
            return $false
        }
    }
    catch {
        Write-Host "VapourSynth health check failed: the portable python does not run." -ForegroundColor Yellow
        return $false
    }
    return $true
}

function Get-VapourSynth {
    $vs_dir       = Join-Path $script:Root "portable_config\VapourSynth"
    $old_sentinel = Join-Path $vs_dir "vapoursynth.dll"

    if (Test-VapourSynth-Healthy $vs_dir) {
        Write-Host "VapourSynth (R80+ pip layout) already installed -- skipping." -ForegroundColor Green
        return
    }

    # A legacy install on a not-yet-migrated tree is upgraded by the 1.2.0
    # migration. If the registry says that migration already ran, nothing
    # else would repair it, so do it here.
    $legacy = Test-Path $old_sentinel
    if ($legacy -and -not $Installing -and ((Get-InstalledVersion) -lt [version]"1.2.0")) {
        Write-Host "Legacy VapourSynth install detected -- the version migrations will upgrade it." -ForegroundColor Yellow
        return
    }

    if (Test-Path $vs_dir) {
        Write-Host "VapourSynth install is old or incomplete -- replacing with the latest runtime." -ForegroundColor Yellow
        Install-VapourSynth-Runtime $vs_dir -ResetFirst
    }
    else {
        Write-Host "VapourSynth not found -- installing." -ForegroundColor Green
        Install-VapourSynth-Runtime $vs_dir
    }
}

# Latest stable VapourSynth release tag (e.g. "R82"). /releases/latest never
# returns prereleases.
function Get-LatestVapourSynthTag {
    $tag = $null
    try { $tag = (Get-LatestGithubRelease "vapoursynth/vapoursynth").tag_name } catch { }
    if ($tag -match "^R\d+$") { return $tag }

    Write-Host "Could not query the VapourSynth release API -- falling back to $($script:FallbackVapourSynthTag)." -ForegroundColor Yellow
    return $script:FallbackVapourSynthTag
}

# The official R80+ portable recipe (mirrors vapoursynth's own
# Install-Portable-VapourSynth.ps1): embedded Python, site-packages appended to
# the ._pth, get-pip, then the wheel -- which IS the runtime now (core, script
# host, plugins and VSPipe all live inside it). open-svpflow is pip-installed
# so the interpolation plugins auto-load. Everything is built in a temp
# folder FIRST; with -ResetFirst the old runtime is only wiped once the new
# one is ready to copy, so a failed download leaves the old install intact.
# User files (see $script:UsersVapourSynthArtifacts) always survive.
function Install-VapourSynth-Runtime {
    param(
        [string]$TargetDir,
        [switch]$ResetFirst
    )

    $tag = Get-LatestVapourSynthTag
    $ver = $tag.Substring(1)
    Write-Host "Latest VapourSynth: $tag" -ForegroundColor Green

    # Newest embeddable 3.14.x; fall back to 3.13 if none is published.
    $py_major = 3; $py_minor = 14; $py_patch = -1
    for ($i = 0; $i -le 20; $i++) {
        $py_uri = "https://www.python.org/ftp/python/$py_major.$py_minor.$i/python-$py_major.$py_minor.$i-embed-amd64.zip"
        try {
            Invoke-WebRequest -Uri $py_uri -Method Head -UseBasicParsing -UserAgent $useragent | Out-Null
            $py_patch = $i
        } catch { break }
    }
    if ($py_patch -lt 0) {
        $py_minor = 13; $py_patch = 10
    }
    Write-Host "Using Python $py_major.$py_minor.$py_patch" -ForegroundColor Green

    $dl_dir      = Join-Path $env:TEMP "vs_install_temp"
    $py_zip      = Join-Path $dl_dir "python-$py_major.$py_minor.$py_patch-embed-amd64.zip"
    $vs_zip      = Join-Path $dl_dir "VapourSynth64-Portable-R$ver.zip"
    $pip_script  = Join-Path $dl_dir "get-pip.py"
    $py_tmp      = Join-Path $dl_dir "python_embed"
    $vs_tmp      = Join-Path $dl_dir "vs_portable"

    try {
        if (Test-Path $dl_dir) { Remove-Item -Recurse -Force $dl_dir }
        $null = New-Item -ItemType Directory -Force $dl_dir
        $null = New-Item -ItemType Directory -Force $py_tmp
        $null = New-Item -ItemType Directory -Force $vs_tmp

        Write-Host "Downloading Python embed..." -ForegroundColor Green
        Invoke-WebRequestWithRetry -Uri "https://www.python.org/ftp/python/$py_major.$py_minor.$py_patch/python-$py_major.$py_minor.$py_patch-embed-amd64.zip" `
                                   -OutFile $py_zip

        Write-Host "Downloading VapourSynth $tag portable..." -ForegroundColor Green
        Invoke-WebRequestWithRetry -Uri "https://github.com/vapoursynth/vapoursynth/releases/download/$tag/VapourSynth64-Portable-R$ver.zip" `
                                   -OutFile $vs_zip

        Write-Host "Downloading pip..." -ForegroundColor Green
        Invoke-WebRequestWithRetry -Uri "https://bootstrap.pypa.io/get-pip.py" -OutFile $pip_script

        Write-Host "Extracting Python..." -ForegroundColor Green
        Expand-Archive -LiteralPath $py_zip -DestinationPath $py_tmp -Force

        $pth_file = Get-ChildItem $py_tmp -Filter "python$py_major$py_minor._pth" | Select-Object -First 1
        if ($pth_file) {
            Add-Content -Path $pth_file.FullName -Encoding UTF8 -Value "Lib\site-packages"
        }

        Write-Host "Installing pip..." -ForegroundColor Green
        & "$py_tmp\python.exe" $pip_script "--no-warn-script-location"
        if ($LASTEXITCODE -ne 0) { throw "get-pip.py failed (exit code $LASTEXITCODE)" }

        Write-Host "Extracting VapourSynth portable..." -ForegroundColor Green
        Expand-Archive -LiteralPath $vs_zip -DestinationPath $vs_tmp -Force

        $wheel = Get-ChildItem "$vs_tmp\wheel" -Filter "VapourSynth-*.whl" -ErrorAction Ignore |
                 Select-Object -First 1
        if (-not $wheel) {
            throw "VapourSynth wheel not found in portable zip."
        }
        Write-Host "Installing VapourSynth wheel..." -ForegroundColor Green
        & "$py_tmp\python.exe" -m pip install $wheel.FullName "--no-warn-script-location"
        if ($LASTEXITCODE -ne 0) { throw "Installing the VapourSynth wheel failed (exit code $LASTEXITCODE)" }

        # The interpolation plugins, same environment: the pip package installs
        # them where R80+ cores auto-load them. The manual svpflow DLLs
        # (Get-VSDLLs) are fetched separately and take precedence when present.
        Write-Host "Installing open-svpflow (frame interpolation plugins)..." -ForegroundColor Green
        & "$py_tmp\python.exe" -m pip install "open-svpflow" "--no-warn-script-location"
        if ($LASTEXITCODE -ne 0) { throw "Installing open-svpflow failed (exit code $LASTEXITCODE)" }

        # pip console shims are not needed in the portable tree.
        Get-ChildItem "$py_tmp\Scripts" -Filter "*.exe" -ErrorAction Ignore | Remove-Item -Force -ErrorAction Ignore

        # Everything downloaded and built -- only now touch the live install.
        $null = New-Item -ItemType Directory -Force $TargetDir
        if ($ResetFirst) {
            Reset-VapourSynth-Folder $TargetDir
        }

        Write-Host "Copying files to $TargetDir..." -ForegroundColor Green

        Get-ChildItem $py_tmp -File | Copy-Item -Destination $TargetDir -Force
        $lib_src = Join-Path $py_tmp "Lib"
        if (Test-Path $lib_src) {
            $lib_dst = Join-Path $TargetDir "Lib"
            $null = New-Item -ItemType Directory -Force $lib_dst
            Copy-Item -Path (Join-Path $lib_src "*") -Destination $lib_dst -Recurse -Force
        }

        Get-ChildItem $vs_tmp -File | Copy-Item -Destination $TargetDir -Force

        # Register the FINAL location (not the temp folder, which is deleted
        # below) with Windows -- the official VSSCRIPT_PATH mechanism.
        Write-Host "Registering the portable VapourSynth runtime with Windows..." -ForegroundColor Green
        try {
            & (Join-Path $TargetDir "python.exe") -m vapoursynth register-install
            if ($LASTEXITCODE -ne 0) {
                Write-Host "register-install exited with code $LASTEXITCODE (VSSCRIPT_PATH is still set explicitly)." -ForegroundColor Yellow
            }
        }
        catch {
            Write-Host "register-install failed: $($_.Exception.Message) (VSSCRIPT_PATH is still set explicitly)." -ForegroundColor Yellow
        }

        Set-Content -Path (Join-Path $TargetDir "vapoursynth_runtime.txt") -Value $tag -Encoding ASCII

        Write-Host "VapourSynth $tag installed OK" -ForegroundColor Green
    }
    catch {
        Write-Host "VapourSynth install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "You can manually run install-portable-vapoursynth.ps1 into $TargetDir\" -ForegroundColor Yellow
        throw
    }
    finally {
        if (Test-Path $dl_dir) { Remove-Item -Recurse -Force $dl_dir -ErrorAction SilentlyContinue }
    }
}

function Reset-VapourSynth-Folder {
    param([string]$VSDir)

    Write-Host "Removing old VapourSynth runtime files from $VSDir (keeping your settings and DLLs)..." -ForegroundColor Yellow
    Get-ChildItem -LiteralPath $VSDir -Force -ErrorAction SilentlyContinue |
        Where-Object { $script:UsersVapourSynthArtifacts -notcontains $_.Name } |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
}

# Adds entries to the persistent PATH of a scope via the registry so the
# existing value type (REG_EXPAND_SZ, with %VARS% unexpanded) is preserved --
# [Environment]::SetEnvironmentVariable would flatten it. Entries are
# compared exactly (not with -like, where [ ] are wildcards and a parent
# folder matches its subfolders). Returns the entries that were added.
function Add-ToPersistentPath {
    param(
        [string]$Scope,
        [string[]]$Entries
    )

    if ($Scope -eq "Machine") {
        $hive    = [Microsoft.Win32.Registry]::LocalMachine
        $keyPath = "SYSTEM\CurrentControlSet\Control\Session Manager\Environment"
    }
    else {
        $hive    = [Microsoft.Win32.Registry]::CurrentUser
        $keyPath = "Environment"
    }

    $key = $hive.OpenSubKey($keyPath, $true)
    if (-not $key) { throw "Cannot open the $Scope environment registry key." }

    try {
        $kind    = [Microsoft.Win32.RegistryValueKind]::ExpandString
        $current = ""
        if ($key.GetValueNames() -contains "Path") {
            $current = [string]$key.GetValue("Path", "", [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            $kind    = $key.GetValueKind("Path")
        }

        $existing = @()
        foreach ($part in ($current -split ';')) {
            if ($part) { $existing += $part.Trim().TrimEnd('\') }
        }

        $toAdd = @()
        foreach ($entry in $Entries) {
            $norm  = $entry.TrimEnd('\')
            $found = $false
            foreach ($e in $existing) {
                if ($e -ieq $norm) { $found = $true; break }
            }
            if (-not $found) { $toAdd += $entry }
        }

        if ($toAdd.Count -gt 0) {
            $new = if ($current) { $current.TrimEnd(';') + ";" + ($toAdd -join ';') } else { $toAdd -join ';' }
            $key.SetValue("Path", $new, $kind)

            # Setting/removing a throwaway user variable makes Windows
            # broadcast the environment change to running programs.
            [Environment]::SetEnvironmentVariable("MPVSYNTH_ENV_REFRESH", "1", "User")
            [Environment]::SetEnvironmentVariable("MPVSYNTH_ENV_REFRESH", $null, "User")
        }
        return $toAdd
    }
    finally {
        $key.Close()
    }
}

function Set-VSScriptPath {
    $vs_dir = Join-Path $script:Root "portable_config\VapourSynth"
    # R80+ pip layout: the script host lives inside the vapoursynth package
    # under site-packages. A bare VSScript.dll at the folder root only exists
    # in manually-copied/legacy trees, so it is the fallback, not the target:
    # pointing VSSCRIPT_PATH into a mixed tree is what breaks script loading.
    $pip_path  = [System.IO.Path]::GetFullPath((Join-Path $vs_dir "Lib\site-packages\vapoursynth\vsscript.dll"))
    $root_path = [System.IO.Path]::GetFullPath((Join-Path $vs_dir "VSScript.dll"))

    if (Test-Path $pip_path) {
        $vsscript = $pip_path
    }
    elseif (Test-Path $root_path) {
        $vsscript = $root_path
        Write-Host "Warning: using legacy root VSScript.dll ($root_path) -- run the 1.2.0+ update to get the official R80+ layout." -ForegroundColor Yellow
    }
    else {
        Write-Host "Warning: vsscript.dll not found at $pip_path -- setting VSSCRIPT_PATH anyway." -ForegroundColor Yellow
        $vsscript = $pip_path
    }

    # The pip layout buries python314.dll (the embedded interpreter) in the
    # runtime root instead of next to mpv.exe. vsscript.dll boots the
    # interpreter dynamically, and mpv, when VSSCRIPT_PATH is empty, falls
    # back to LoadLibrary("VSScript.dll") over the standard search path.
    # Keeping the runtime root and the package directory on PATH makes BOTH
    # work from any launcher.
    $runtime_root = [System.IO.Path]::GetFullPath($vs_dir).TrimEnd('\')
    $package_dir  = Join-Path $runtime_root "Lib\site-packages\vapoursynth"
    $scope = if (Test-Admin) { "Machine" } else { "User" }

    try {
        $added = @(Add-ToPersistentPath -Scope $scope -Entries @($runtime_root, $package_dir))
        if ($added.Count -gt 0) {
            Write-Host "Added to the $scope PATH: $($added -join '; ')" -ForegroundColor Green
        }
    }
    catch {
        Write-Host "Could not update the $scope PATH: $($_.Exception.Message)" -ForegroundColor Yellow
    }
    foreach ($entry in @($runtime_root, $package_dir)) {
        $present = $false
        foreach ($p in ($env:Path -split ';')) {
            if ($p.TrimEnd('\') -ieq $entry) { $present = $true; break }
        }
        if (-not $present) { $env:Path = "$($env:Path);$entry" }
    }

    # Write BOTH scopes to the SAME value, always: mixed-scope pointers
    # deadlock (an elevated run writes Machine, the user checks User, or vice
    # versa). Identical values in both scopes end the fight.
    foreach ($envScope in @("Machine", "User")) {
        try {
            [Environment]::SetEnvironmentVariable("VSSCRIPT_PATH", $vsscript, $envScope)
            [Environment]::SetEnvironmentVariable("VSSCRIPT_DLL", $vsscript, $envScope)
        }
        catch {
            # Machine scope needs elevation; a non-elevated pass just skips it.
            Write-Host "Could not set VSSCRIPT vars at $envScope scope: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    $env:VSSCRIPT_PATH = $vsscript
    $env:VSSCRIPT_DLL  = $vsscript
    Write-Host "VSSCRIPT_PATH / VSSCRIPT_DLL (both scopes) = $vsscript" -ForegroundColor Green
}

function Get-VSDLLs {
    $vs_dir       = Join-Path $script:Root "portable_config\VapourSynth"
    $vs1_dst      = Join-Path $vs_dir "svpflow1_vs.dll"
    $vs2_dst      = Join-Path $vs_dir "svpflow2_vs.dll"
    $version_file = Join-Path $vs_dir "svpflow_version.txt"
    $repo         = "Z1xus/open-svpflow"
    $asset_name   = "x86_64-pc-windows-msvc.zip"

    $have_dlls = (Test-Path $vs1_dst) -and (Test-Path $vs2_dst)

    # Tag of the open-svpflow release currently installed (recorded after each successful install).
    $local_tag = $null
    if (Test-Path $version_file) {
        $local_tag = (Get-Content $version_file -Raw -ErrorAction Ignore)
        if ($local_tag) { $local_tag = $local_tag.Trim() }
    }

    # Tag of the latest published release.
    $remote_tag = $null
    try {
        $remote_tag = (Get-LatestGithubRelease $repo).tag_name
    }
    catch {
        $remote_tag = $null
    }

    if ($have_dlls) {
        if (-not $remote_tag) {
            Write-Host "Could not check for new SVPflow DLLs -- keeping installed version." -ForegroundColor Yellow
            return
        }
        if ($local_tag -eq $remote_tag) {
            Write-Host "You are already using latest SVPflow DLLs -- $remote_tag" -ForegroundColor Green
            return
        }
        $from = if ($local_tag) { $local_tag } else { "unknown version" }
        Write-Host "Newer SVPflow DLLs available -- $from -> $remote_tag" -ForegroundColor Green
    }
    else {
        Write-Host "SVPflow VapourSynth DLLs not found -- downloading." -ForegroundColor Green
    }

    # Prefer the exact tag we just looked up so the recorded version always matches what was
    # downloaded; fall back to the /latest/ redirect if the tag lookup failed.
    $archive_url = if ($remote_tag) {
        "https://github.com/$repo/releases/download/$([uri]::EscapeDataString($remote_tag))/$asset_name"
    }
    else {
        "https://github.com/$repo/releases/latest/download/$asset_name"
    }

    $archive_path = Join-Path $env:TEMP "open-svpflow-$asset_name"
    $extract_dir  = Join-Path $env:TEMP "svpflow_extract"
    try {
        Invoke-WebRequestWithRetry -Uri $archive_url -OutFile $archive_path
        if (Test-Path $extract_dir) { Remove-Item -Recurse -Force $extract_dir }
        $null = New-Item -ItemType Directory -Force $extract_dir
        Expand-Archive -LiteralPath $archive_path -DestinationPath $extract_dir -Force
        # Search recursively so this still works if the zip nests the DLLs in a subfolder.
        $src1 = Get-ChildItem -Path $extract_dir -Filter "svpflow1_vs.dll" -Recurse -File | Select-Object -First 1
        $src2 = Get-ChildItem -Path $extract_dir -Filter "svpflow2_vs.dll" -Recurse -File | Select-Object -First 1
        if (-not $src1 -or -not $src2) {
            Write-Host "SVPflow DLLs not found inside archive -- check the archive structure." -ForegroundColor Red
            return
        }
        $null = New-Item -ItemType Directory -Force $vs_dir
        Copy-Item $src1.FullName $vs1_dst -Force
        Copy-Item $src2.FullName $vs2_dst -Force
        if ($remote_tag) {
            Set-Content -Path $version_file -Value $remote_tag -Encoding ASCII
        }
        Write-Host "svpflow1_vs.dll installed OK" -ForegroundColor Green
        Write-Host "svpflow2_vs.dll installed OK" -ForegroundColor Green
    }
    catch {
        Write-Host "SVPflow DLL download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "You can manually download $archive_url, extract svpflow1_vs.dll and svpflow2_vs.dll and place them in portable_config\VapourSynth\." -ForegroundColor Yellow
    }
    finally {
        if (Test-Path $archive_path) { Remove-Item -Force $archive_path }
        if (Test-Path $extract_dir)  { Remove-Item -Recurse -Force $extract_dir }
    }
}

# ===========================================================================
# Main
# ===========================================================================

if (Test-Admin) {
    Write-Host "Running with administrator privileges" -ForegroundColor Yellow
}
else {
    Write-Host "Running without administrator privileges" -ForegroundColor Red
    Write-Host "Warning: the version registry (HKLM) and machine-wide PATH cannot be written; run updater.bat instead." -ForegroundColor Red
}

try {
    Check-PowershellVersion
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $global:progressPreference = 'silentlyContinue'

    $pc_dir = Join-Path $script:Root "portable_config"
    if (Test-Path $pc_dir) {
        # Probe before granting: an icacls reset with /T costs real time on a
        # tree holding an entire python embed, and it is only needed when
        # something is actually locked. A tiny write probe answers it cheaply.
        $probe = Join-Path $pc_dir ".acl-probe.tmp"
        $needs_acl = $false
        try {
            $null = New-Item -Path $probe -ItemType File -Force -ErrorAction Stop
            Remove-Item $probe -Force -ErrorAction SilentlyContinue
        }
        catch {
            $needs_acl = $true
        }
        if ($needs_acl) {
            Write-Host "Fixing ACL on: $pc_dir" -ForegroundColor Yellow
            & icacls $pc_dir /grant "${env:USERNAME}:(OI)(CI)F" /T | Out-Null
        }
        else {
            Write-Host "ACL on portable_config already allows writes - skipping icacls." -ForegroundColor Green
        }
    }
    Stop-Mpv

    # --- Support-tool steps --------------------------------------------------
    # The version migrations are the important part of an update. A failure in
    # any of these used to abort the run BEFORE the migrations executed, so
    # each one now fails with a warning and the run continues.
    try { Upgrade-Mpv }          catch { Write-Host "mpv step failed: $($_.Exception.Message)" -ForegroundColor Red }
    try { Get-VapourSynth }      catch { Write-Host "VapourSynth step failed: $($_.Exception.Message)" -ForegroundColor Red }
    # Always refresh the env pointers, every pass, install or migration:
    # a once-wrong VSSCRIPT_PATH/VSSCRIPT_DLL otherwise outlives every run.
    try { Set-VSScriptPath }     catch { Write-Host "VSSCRIPT_PATH step failed: $($_.Exception.Message)" -ForegroundColor Red }
    try { Get-VSDLLs }           catch { Write-Host "SVPflow DLL step failed: $($_.Exception.Message)" -ForegroundColor Red }
    try { Upgrade-Ytplugin }     catch { Write-Host "yt-dlp plugin step failed: $($_.Exception.Message)" -ForegroundColor Red }
    try { Upgrade-FFmpeg }       catch { Write-Host "ffmpeg step failed: $($_.Exception.Message)" -ForegroundColor Red }
    # Subliminal lives in the portable runtime; runs after Get-VapourSynth so
    # the embedded python it installs into exists.
    try { Update-PythonEnvironment } catch { Write-Host "Python step failed: $($_.Exception.Message)" -ForegroundColor Red }

    if ($Installing -and -not $script:ForceMigrationsOnNextRun) {
        Write-Host ""
        Write-Host "Fresh install detected -- skipping migration scripts." -ForegroundColor Green
        try {
            Set-InstalledVersion $UpdaterVersion
        }
        catch {
            Write-Host "Could not record the installed version in the registry: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
    else {
        Invoke-Migrations
        # A migration (1.2.0) may have just created the runtime.
        try { Install-Subliminal-Portable -OnlyIfMissing } catch { }
    }

    Clean-Downloaded

    try {
        Complete-SelfUpdate
    }
    catch {
        Write-Host "Self-update could not finish: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    if ($Unattended) {
        exit 0
    }

    Write-Host "Operation completed" -ForegroundColor Magenta
}
catch [System.Exception] {
    Clean-Downloaded

    # Rich diagnostics: a single generic message hid which step killed the
    # run and sent users looking at the wrong thing.
    Write-Host ""
    Write-Host "FATAL ERROR: $($_.Exception.GetType().Name): $($_.Exception.Message)" -ForegroundColor Red
    if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
        Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor Red
    }
    if ($_.Exception -is [System.Management.Automation.MethodInvocationException] -and $_.Exception.InnerException) {
        Write-Host "Cause: $($_.Exception.InnerException.Message)" -ForegroundColor Red
    }
    Write-Host "The update did not complete. Fix the cause and re-run updater.bat." -ForegroundColor Yellow
    exit 1
}