param(
    [switch]$Unattended
)
$fallback7z = Join-Path (Get-Location) "\7z\7zr.exe"
$useragent  = "mpv-win-updater"

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

function Check-7z {
    if (-not (Get-7z)) {
        $null = New-Item -ItemType Directory -Force (Split-Path $fallback7z)
        Write-Host "Downloading 7zr.exe" -ForegroundColor Green
        Invoke-WebRequest -Uri "https://www.7-zip.org/a/7zr.exe" `
                          -UserAgent $useragent -OutFile $fallback7z
    }
    else {
        Write-Host "7z already exists. Skipped download." -ForegroundColor Green
    }
}

# Extract an archive.
#   -Files  : when supplied, extract only those named files (flat, no paths).
#   -Exclude: shell-style patterns to skip (e.g. "*.bat").
# When neither flag is given the full archive is extracted preserving paths.
function Extract-Archive {
    param(
        [string]   $Archive,
        [string[]] $Files   = @(),
        [string[]] $Exclude = @()
    )
    $7z = Get-7z
    Write-Host "Extracting $Archive" -ForegroundColor Green

    if ($Files.Count -gt 0) {
        # 'e' = flat extract (no directory structure), good for pulling specific exes
        & $7z e -y $Archive @Files
    }
    else {
        # 'x' = extract with full paths; honour any exclusion patterns
        $excludeArgs = $Exclude | ForEach-Object { "-xr!$_" }
        & $7z x -y $Archive @excludeArgs
    }
}

# ---------------------------------------------------------------------------
# Download helper
# ---------------------------------------------------------------------------

function Download-Archive ($filename, $link) {
    Write-Host "Downloading $filename" -ForegroundColor Green
    Invoke-WebRequest -Uri $link -UserAgent $useragent -OutFile $filename
}

# ---------------------------------------------------------------------------
# PowerShell version check
# ---------------------------------------------------------------------------

function Check-PowershellVersion {
    $version = $PSVersionTable.PSVersion.Major
    Write-Host "Checking Windows PowerShell version -- $version" -ForegroundColor Green
    if ($version -le 2) {
        Write-Host "PowerShell $version is unsupported. Please upgrade." -ForegroundColor Red
        throw
    }
}

# ---------------------------------------------------------------------------
# yt-dlp / youtube-dl helpers
# ---------------------------------------------------------------------------

function Check-Ytplugin {
    $ytdlp     = Get-ChildItem "yt-dlp*.exe" -ErrorAction Ignore
    $youtubedl = Get-ChildItem "youtube-dl.exe" -ErrorAction Ignore
    if ($ytdlp)     { return $ytdlp.ToString() }
    if ($youtubedl) { return $youtubedl.ToString() }
    return $null
}

function Check-Ytplugin-In-System {
    $ytp = Get-Command -CommandType Application -ErrorAction Ignore yt-dlp.exe |
           Select-Object -Last 1
    if (-not $ytp) {
        $ytp = Get-Command -CommandType Application -ErrorAction Ignore youtube-dl.exe |
               Select-Object -Last 1
    }
    return [bool]($ytp -and ((Split-Path $ytp.Source) -ne (Get-Location)))
}

function Get-Latest-Ytplugin ($plugin) {
    switch -wildcard ($plugin) {
        "yt-dlp*" {
            $ytdlp_channel = Check-Ytdlp-Channel
            $repo = switch ($ytdlp_channel) {
                'stable'  { "https://github.com/yt-dlp/yt-dlp" }
                'nightly' { "https://github.com/yt-dlp/yt-dlp-nightly-builds" }
                'master'  { "https://github.com/yt-dlp/yt-dlp-master-builds" }
            }
            Write-Host "Fetching RSS feed for yt-dlp $ytdlp_channel" -ForegroundColor Green
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
            $ytdlp_channel = Check-Ytdlp-Channel
            $repo = switch ($ytdlp_channel) {
                'stable'  { "https://github.com/yt-dlp/yt-dlp" }
                'nightly' { "https://github.com/yt-dlp/yt-dlp-nightly-builds" }
                'master'  { "https://github.com/yt-dlp/yt-dlp-master-builds" }
            }
            $exe  = "$plugin$suffix.exe"
            $link = "$repo/releases/download/$version/$exe"
            Invoke-WebRequest -Uri $link -UserAgent $useragent -OutFile $exe
        }
        "youtube-dl" {
            Write-Host "Downloading $plugin ($version)" -ForegroundColor Green
            $link = "https://yt-dl.org/downloads/$version/youtube-dl.exe"
            Invoke-WebRequest -Uri $link -UserAgent $useragent -OutFile "youtube-dl.exe"
        }
    }
}

# ---------------------------------------------------------------------------
# GitHub release helpers
# ---------------------------------------------------------------------------

function Get-LatestGithubRelease ($repo) {
    $api  = "https://api.github.com/repos/$repo/releases/latest"
    return Invoke-WebRequest $api -MaximumRedirection 0 -ErrorAction Ignore `
               -UseBasicParsing -UserAgent $useragent | ConvertFrom-Json
}

function Get-Latest-Mpv ($Arch) {
    # shinchiro/mpv-winbuild-cmake is the upstream toolchain author whose builds
    # zhongfly forks. Using it directly avoids the installer/ folder that zhongfly
    # bundles in the archive, which was overwriting patched scripts on every update.
    $json  = Get-LatestGithubRelease "shinchiro/mpv-winbuild-cmake"
    $asset = $json.assets | Where-Object { $_.name -match "^mpv-$Arch-[0-9]{8}" } |
             Select-Object -First 1
    return $asset.name, $asset.browser_download_url
}

# ---------------------------------------------------------------------------
# Architecture helpers
# ---------------------------------------------------------------------------

function Get-Arch {
    $FilePath = Join-Path (Get-Location).Path 'mpv.exe'
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

# ---------------------------------------------------------------------------
# Version helpers
# ---------------------------------------------------------------------------

function ExtractGitFromFile {
    $stripped = .\mpv --no-config | Select-String "mpv" | Select-Object -First 1
    $stripped -match "-g([a-z0-9-]{7})" | Out-Null
    return $matches[1]
}

function ExtractGitFromURL ($filename) {
    $filename -match "-git-([a-z0-9-]{7})" | Out-Null
    return $matches[1]
}

function ExtractDateFromFile {
    $date = (Get-Item ./mpv.exe).LastWriteTimeUtc
    return "$($date.Year.ToString('0000'))$($date.Month.ToString('00'))$($date.Day.ToString('00'))"
}

function ExtractDateFromURL ($filename) {
    $filename -match "mpv-[xi864_].*-([0-9]{8})-git-([a-z0-9-]{7})" | Out-Null
    return $matches[1]
}

# ---------------------------------------------------------------------------
# Deno runtime helper
# ---------------------------------------------------------------------------

function Ensure-Deno ([string]$Context = "update") {
    $deno_exe = Join-Path (Get-Location) "deno.exe"

    if (Test-Path $deno_exe) {
        $remote_name = (Invoke-WebRequest "https://dl.deno.land/release-latest.txt" `
                            -UseBasicParsing -UserAgent $useragent).Content.Trim()
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

    # No local deno.exe present
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

    $remote_name  = (Invoke-WebRequest "https://dl.deno.land/release-latest.txt" `
                         -UseBasicParsing -UserAgent $useragent).Content.Trim()
    $archive      = "deno-x86_64-pc-windows-msvc.zip"
    $download_link = "https://dl.deno.land/release/$remote_name/$archive"
    Write-Host "Downloading Deno (stable) $remote_name" -ForegroundColor Green
    Download-Archive $archive $download_link
    Check-7z
    Extract-Archive $archive
    Check-Autodelete $archive
}

# ---------------------------------------------------------------------------
# Admin check
# ---------------------------------------------------------------------------

function Test-Admin {
    $user = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $user).IsInRole(
        [Security.Principal.WindowsBuiltinRole]::Administrator)
}

# ---------------------------------------------------------------------------
# settings.xml helpers
# ---------------------------------------------------------------------------

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
"@ | Set-Content "settings.xml" -Encoding UTF8
}

function Get-SettingsDoc {
    $file = "settings.xml"
    if (-not (Test-Path $file)) { Create-XML }
    return [xml](Get-Content $file), $file
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
    $ffmpeg_missing  = -not (Test-Path (Join-Path (Get-Location).Path "ffmpeg.exe"))
    $ffprobe_missing = -not (Test-Path (Join-Path (Get-Location).Path "ffprobe.exe"))
    $either_missing  = $ffmpeg_missing -or $ffprobe_missing

    # Re-ask if unset, or if either binary is missing regardless of saved preference.
    # This handles settings.xml being copied from another install that had ffmpeg,
    # or a previous run where the user declined but now ffmpeg/ffprobe aren't present.
    if ($doc.settings.getffmpeg -eq "unset" -or $either_missing) {
        $missing_list = @()
        if ($ffmpeg_missing)  { $missing_list += "ffmpeg.exe"  }
        if ($ffprobe_missing) { $missing_list += "ffprobe.exe" }
        $missing_str = $missing_list -join " and "
        Write-Host "$missing_str not found. " -ForegroundColor Green -NoNewline
        # Default to Y -- ffmpeg/ffprobe are required for colour detection and thumbnails
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
        elseif ((Get-Item $yt).BaseName -match "yt-dlp*") {
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

function Check-Ytdlp-Channel {
    $doc, $file = Get-SettingsDoc

    if ($null -eq $doc.settings.ytdlpchannel) {
        $node = $doc.CreateElement("ytdlpchannel")
        $node.AppendChild($doc.CreateTextNode("unset")) | Out-Null
        $doc.settings.AppendChild($node) | Out-Null
    }

    if ($doc.settings.ytdlpchannel -eq "unset") {
        $result = Read-KeyOrTimeout `
            "Which update channel for yt-dlp? [1=stable/2=nightly/3=master] (default=1)" "D1"
        Write-Host ""
        $channel = switch ($result) {
            'D1' { "stable" }
            'D2' { "nightly" }
            'D3' { "master" }
            default { Write-Host "Invalid input -- using default: stable" -ForegroundColor Yellow; "stable" }
        }
        $doc.settings.ytdlpchannel = $channel
        $doc.Save($file)
        return $channel
    }
    return $doc.settings.ytdlpchannel
}

# ---------------------------------------------------------------------------
# Upgrade functions
# ---------------------------------------------------------------------------

function Check-Mpv {
    return Test-Path (Join-Path (Get-Location).Path "mpv.exe")
}

function Upgrade-Mpv {
    $need_download = $false
    $arch = ""
    $remoteName = ""
    $download_link = ""

    if (Check-Mpv) {
        $arch       = Check-Arch (Get-Arch).FileType
        $remoteName, $download_link = Get-Latest-Mpv $arch
        $localgit   = ExtractGitFromFile
        $localdate  = ExtractDateFromFile
        $remotegit  = ExtractGitFromURL $remoteName
        $remotedate = ExtractDateFromURL $remoteName

        if ($localgit -match $remotegit -and $localdate -match $remotedate) {
            Write-Host "You are already using latest mpv build -- $remoteName" -ForegroundColor Green
        }
        else {
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
            $remoteName, $download_link = Get-Latest-Mpv $arch
        }
        elseif ($result -ne 'N') {
            Write-Host "Invalid input -- skipping mpv download" -ForegroundColor Yellow
        }
    }

    if ($need_download) {
        Download-Archive $remoteName $download_link
        Check-7z
        # Extract all files from the mpv archive except installer bat scripts,
        # which are bundled in the release but belong only in the installer folder.
        Extract-Archive $remoteName -Exclude @("*.bat", "*.ps1", "doc", "installer")
    }
    Check-Autodelete $remoteName
}

function Upgrade-Ytplugin {
    if (Check-Ytplugin-In-System) {
        Write-Host "yt-dlp or youtube-dl already exists in system PATH, skipping update." -ForegroundColor Green
        return
    }

    $yt = Check-Ytplugin
    if ($yt) {
        $latest = Get-Latest-Ytplugin((Get-Item $yt).BaseName)
        if ((& $yt --version) -match $latest) {
            Write-Host "You are already using latest $((Get-Item $yt).BaseName) -- $latest" -ForegroundColor Green
            if ((Get-Item $yt).BaseName -match "yt-dlp*") { Ensure-Deno "update" }
        }
        else {
            Write-Host "Newer $((Get-Item $yt).BaseName) build available" -ForegroundColor Green
            if ((Get-Item $yt).BaseName -match "yt-dlp*") {
                & $yt --update-to (Check-Ytdlp-Channel)
                Ensure-Deno "update"
            }
            else {
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
            'false' { <# user declined #> }
            default { Write-Host "Invalid input -- skipping yt-dlp download" -ForegroundColor Yellow }
        }
    }
}

function Upgrade-FFmpeg {
    if ((Check-GetFFmpeg) -eq "false") { return }

    # Both ffmpeg and ffprobe are sourced from gyan.dev (CODEX FFMPEG).
    # The essentials build contains ffmpeg.exe, ffprobe.exe and ffplay.exe.
    # Version is checked via a single-line API endpoint.
    $ver_url      = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z.ver"
    $archive_url  = "https://www.gyan.dev/ffmpeg/builds/ffmpeg-git-essentials.7z"
    $archive_name = "ffmpeg-git-essentials.7z"
    $archive_path = Join-Path (Get-Location).Path $archive_name

    $remote_ver = ([System.Text.Encoding]::UTF8.GetString((Invoke-WebRequest $ver_url -UseBasicParsing -UserAgent $useragent).Content)).Trim()
    Write-Host "Latest ffmpeg/ffprobe build: $remote_ver" -ForegroundColor Green

    $ffmpeg_path  = Join-Path (Get-Location).Path "ffmpeg.exe"
    $ffprobe_path = Join-Path (Get-Location).Path "ffprobe.exe"
    $need_download = $false

    # Check ffmpeg version
    if (Test-Path $ffmpeg_path) {
        $local_ver = (.\ffmpeg -version | Select-String "ffmpeg version" |
                      Select-Object -First 1).ToString().Trim()
        $commit = [Regex]::Match($remote_ver, "git-([a-z0-9]+)$").Groups[1].Value
        if ($local_ver -match [Regex]::Escape($commit)) {
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

    # Always re-download if ffprobe is missing, even if ffmpeg is current
    if (-not (Test-Path $ffprobe_path)) {
        Write-Host "ffprobe.exe not found -- will download" -ForegroundColor Yellow
        $need_download = $true
    }

    if ($need_download) {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add("User-Agent", $useragent)
        Write-Host "Downloading $archive_name" -ForegroundColor Green
        $wc.DownloadFile($archive_url, $archive_path)
        Check-7z
        $7z = Get-7z
        # Exes are nested inside a versioned subfolder -- use -r to extract flat
        $dest = (Get-Location).Path
        & $7z e -y "-o$dest" $archive_path "ffmpeg.exe" "ffprobe.exe" -r
        if (Test-Path $ffmpeg_path)  { Write-Host "ffmpeg.exe  extracted OK" -ForegroundColor Green }
        else                         { Write-Host "ffmpeg.exe  NOT found after extraction" -ForegroundColor Red }
        if (Test-Path $ffprobe_path) { Write-Host "ffprobe.exe extracted OK" -ForegroundColor Green }
        else                         { Write-Host "ffprobe.exe NOT found after extraction" -ForegroundColor Red }
        Check-Autodelete $archive_path
    }
}

function Read-KeyOrTimeout ($prompt, $key) {
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

function Get-VapourSynth {
    # Only runs on first install — skipped silently if already present.
    # Installs a self-contained portable VapourSynth into portable_config\VapourSynth.
    $vs_dir      = Join-Path (Get-Location).Path "portable_config\VapourSynth"
    $sentinel    = Join-Path $vs_dir "vapoursynth.dll"

    if (Test-Path $sentinel) {
        Write-Host "VapourSynth already installed -- skipping." -ForegroundColor Green
        return
    }

    Write-Host "VapourSynth not found -- installing." -ForegroundColor Green

    # Fetch latest stable release version from GitHub
    #$releases = Invoke-WebRequest -Uri "https://api.github.com/repos/vapoursynth/vapoursynth/releases" `
    #                -UseBasicParsing -UserAgent $useragent | ConvertFrom-Json
    $ver = 73
    #foreach ($r in $releases) {
    #    if (-not $r.prerelease) { $ver = $r.name.TrimStart("R"); break }
    #}
    #if (-not $ver) {
    #    Write-Host "Could not determine latest VapourSynth version -- skipping." -ForegroundColor Red
    #    return
    #}
    Write-Host "Latest VapourSynth: R$ver" -ForegroundColor Green

    # Determine latest Python 3.14 embed patch version
    $py_major = 3; $py_minor = 14; $py_patch = 0
    for ($i = 1; $i -le 20; $i++) {
        $py_uri = "https://www.python.org/ftp/python/$py_major.$py_minor.$i/python-$py_major.$py_minor.$i-embed-amd64.zip"
        try {
            Invoke-WebRequest -Uri $py_uri -Method Head -UseBasicParsing -UserAgent $useragent | Out-Null
            $py_patch = $i
        } catch { break }
    }
    if ($py_patch -eq 0) {
        # Fall back to 3.13 if 3.14 not yet available
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
        $null = New-Item -ItemType Directory -Force $dl_dir
        $null = New-Item -ItemType Directory -Force $py_tmp
        $null = New-Item -ItemType Directory -Force $vs_tmp
        $null = New-Item -ItemType Directory -Force $vs_dir

        Write-Host "Downloading Python embed..." -ForegroundColor Green
        Invoke-WebRequest -Uri "https://www.python.org/ftp/python/$py_major.$py_minor.$py_patch/python-$py_major.$py_minor.$py_patch-embed-amd64.zip" `
                          -OutFile $py_zip -UserAgent $useragent

        Write-Host "Downloading VapourSynth portable..." -ForegroundColor Green
        Invoke-WebRequest -Uri "https://github.com/vapoursynth/vapoursynth/releases/download/R$ver/VapourSynth64-Portable-R$ver.zip" `
                          -OutFile $vs_zip -UserAgent $useragent

        Write-Host "Downloading pip..." -ForegroundColor Green
        Invoke-WebRequest -Uri "https://bootstrap.pypa.io/get-pip.py" `
                          -OutFile $pip_script -UserAgent $useragent

        Write-Host "Extracting Python..." -ForegroundColor Green
        Expand-Archive -LiteralPath $py_zip -DestinationPath $py_tmp -Force

        # Enable site-packages so the VapourSynth wheel installs correctly
        $pth_file = Get-ChildItem $py_tmp -Filter "python$py_major$py_minor._pth" | Select-Object -First 1
        if ($pth_file) {
            Add-Content -Path $pth_file.FullName -Encoding UTF8 -Value "Lib\site-packages"
        }

        Write-Host "Installing pip..." -ForegroundColor Green
        & "$py_tmp\python.exe" $pip_script "--no-warn-script-location"

        Write-Host "Extracting VapourSynth portable..." -ForegroundColor Green
        Expand-Archive -LiteralPath $vs_zip -DestinationPath $vs_tmp -Force

        # Install the VapourSynth Python wheel using the embed Python
        $wheel = Get-ChildItem "$vs_tmp\wheel" -Filter "VapourSynth-*.whl" -ErrorAction Ignore |
                 Select-Object -First 1
        if ($wheel) {
            Write-Host "Installing VapourSynth wheel..." -ForegroundColor Green
            & "$py_tmp\python.exe" -m pip install $wheel.FullName "--no-warn-script-location"
        } else {
            Write-Host "VapourSynth wheel not found in portable zip." -ForegroundColor Red
            return
        }

        # Copy only the folders and files we need into portable_config\VapourSynth:
        #   Lib\           — Python standard library + site-packages (includes vapoursynth module)
        #   vs-coreplugins\ — built-in VS plugins
        #   vsgenstubs4\   — type stubs
        #   Root-level files from the VS zip (vapoursynth.dll, vsscript.dll etc.)
        #   Root-level files from the Python embed (python.exe, python3xx.dll etc.)
        Write-Host "Copying files to portable_config\VapourSynth..." -ForegroundColor Green

        # Python embed root files
        Get-ChildItem $py_tmp -File | Copy-Item -Destination $vs_dir -Force
        # Python Lib (includes site-packages with vapoursynth wheel)
        $lib_src = Join-Path $py_tmp "Lib"
        if (Test-Path $lib_src) {
            Copy-Item $lib_src $vs_dir -Recurse -Force
        }

        # VapourSynth root-level DLLs and files (not subdirectories)
        Get-ChildItem $vs_tmp -File | Copy-Item -Destination $vs_dir -Force

        # VapourSynth subdirectories we need
        foreach ($sub in @("vs-coreplugins", "vsgenstubs4")) {
            $src = Join-Path $vs_tmp $sub
            if (Test-Path $src) {
                Copy-Item $src $vs_dir -Recurse -Force
            } else {
                Write-Host "Warning: $sub not found in VapourSynth portable zip." -ForegroundColor Yellow
            }
        }

        Write-Host "VapourSynth installed OK" -ForegroundColor Green

    }
    catch {
        Write-Host "VapourSynth install failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "You can manually run install-portable-vapoursynth.ps1 into portable_config\VapourSynth\" -ForegroundColor Yellow
    }
    finally {
        if (Test-Path $dl_dir) { Remove-Item -Recurse -Force $dl_dir }
    }
}

function Get-VSDLLs {
    $vs_dir  = Join-Path (Get-Location).Path "portable_config\VapourSynth"
    $vs1_dst = Join-Path $vs_dir "vs1-x64.dll"
    $vs2_dst = Join-Path $vs_dir "vs2-x64.dll"
    if ((Test-Path $vs1_dst) -and (Test-Path $vs2_dst)) {
        Write-Host "VapourSynth interface DLLs already present -- skipping." -ForegroundColor Green
        return
    }
    Write-Host "VapourSynth interface DLLs not found -- downloading (first-install only)." -ForegroundColor Green
    $archive_url  = "https://raw.github.com/bjaan/smoothvideo/main/SVPflow_LastGoodVersions.7z"
    $archive_name = "SVPflow_LastGoodVersions.7z"
    $archive_path = Join-Path $env:TEMP $archive_name
    $extract_dir  = Join-Path $env:TEMP "svpflow_extract"
    try {
        Invoke-WebRequest -Uri $archive_url -UserAgent $useragent -OutFile $archive_path
        if (Test-Path $extract_dir) { Remove-Item -Recurse -Force $extract_dir }
        $null = New-Item -ItemType Directory -Force $extract_dir
        Check-7z
        $7z = Get-7z
        & $7z x -y "-o$extract_dir" $archive_path
        $src1 = Join-Path $extract_dir "x64_vs\svpflow1_vs.dll"
        $src2 = Join-Path $extract_dir "x64_vs\svpflow2_vs.dll"
        if (-not (Test-Path $src1) -or -not (Test-Path $src2)) {
            Write-Host "VapourSynth interface DLLs not found inside archive -- check the archive structure." -ForegroundColor Red
            return
        }
        $null = New-Item -ItemType Directory -Force $vs_dir
        Copy-Item $src1 $vs1_dst -Force
        Copy-Item $src2 $vs2_dst -Force
        Write-Host "vs1-x64.dll installed OK" -ForegroundColor Green
        Write-Host "vs2-x64.dll installed OK" -ForegroundColor Green
    }
    catch {
        Write-Host "VapourSynth interface download failed: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "You can manually download $archive_url, extract x64_vs\svpflow1_vs.dll and svpflow2_vs.dll and place them in portable_config\VapourSynth\ named vs1-x64.dll and vs2-x64.dll respectively." -ForegroundColor Yellow
    }
    finally {
        if (Test-Path $archive_path) { Remove-Item -Force $archive_path }
        if (Test-Path $extract_dir)  { Remove-Item -Recurse -Force $extract_dir }
    }
}

function Upgrade-Scripts-And-Updater {
    Write-Host "Checking for script updates..." -ForegroundColor Green

    $zip_url = "https://github.com/AJCrowley/mpv-synth/releases/latest/download/mpv-synth.zip"
    $temp_zip = Join-Path $env:TEMP "mpv-synth.zip"
    $extract_dir = Join-Path $env:TEMP "mpv_synth_extract"

    try {
        # Download latest release
        Write-Host "Downloading latest release..." -ForegroundColor Green
        Invoke-WebRequest -Uri $zip_url -OutFile $temp_zip -UserAgent $useragent

        # Clean + extract
        if (Test-Path $extract_dir) {
            Remove-Item $extract_dir -Recurse -Force
        }
        Expand-Archive -LiteralPath $temp_zip -DestinationPath $extract_dir -Force

        # Root folder inside zip (GitHub zips always wrap)
        $root = Get-ChildItem $extract_dir | Select-Object -First 1

        # Paths
        $src_scripts = Join-Path $root.FullName "portable_config\scripts"
        $dst_scripts = Join-Path (Get-Location).Path "portable_config\scripts"

        $src_updater = Join-Path $root.FullName "installer\updater.ps1"
        $dst_updater = $MyInvocation.MyCommand.Path

        # --- Update scripts (merge, don’t delete extras) ---
        if (Test-Path $src_scripts) {
            Write-Host "Updating scripts..." -ForegroundColor Green

            if (-not (Test-Path $dst_scripts)) {
                New-Item -ItemType Directory -Path $dst_scripts | Out-Null
            }

            Copy-Item "$src_scripts\*" $dst_scripts -Recurse -Force
            Write-Host "Scripts updated (custom files preserved)" -ForegroundColor Green
        }
        else {
            Write-Host "No scripts folder found in update." -ForegroundColor Yellow
        }

        # --- Self-update ---
        if (Test-Path $src_updater) {
            Write-Host "Updating updater.ps1..." -ForegroundColor Green

            # Copy to temp first to avoid overwrite issues while running
            $temp_self = "$dst_updater.new"
            Copy-Item $src_updater $temp_self -Force

            # Replace after script ends (safe approach)
            Start-Process powershell -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"Start-Sleep 1; Move-Item -Force '$temp_self' '$dst_updater'`"" -WindowStyle Hidden

            Write-Host "Updater will self-update after exit." -ForegroundColor Green
        }
        else {
            Write-Host "No updater.ps1 found in update." -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "Script update failed: $($_.Exception.Message)" -ForegroundColor Red
    }
    finally {
        if (Test-Path $temp_zip) { Remove-Item $temp_zip -Force }
        if (Test-Path $extract_dir) { Remove-Item $extract_dir -Recurse -Force }
    }
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (Test-Admin) {
    Write-Host "Running with administrator privileges" -ForegroundColor Yellow
}
else {
    Write-Host "Running without administrator privileges" -ForegroundColor Red
}

try {
    Check-PowershellVersion
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $global:progressPreference = 'silentlyContinue'

	$pc_dir = Join-Path (Get-Location).Path "portable_config"
	if (Test-Path $pc_dir) {
		Write-Host "Setting ACL on: $pc_dir" -ForegroundColor Yellow
		& icacls $pc_dir /grant "${env:USERNAME}:(OI)(CI)F" /T | Out-Null
	}
    Upgrade-Mpv
	Upgrade-Scripts-And-Updater
    Get-VapourSynth
    Get-VSDLLs
    Upgrade-Ytplugin
    Upgrade-FFmpeg
	if ($Unattended) {
		exit 0
	}
    Write-Host "Operation completed" -ForegroundColor Magenta
}
catch [System.Exception] {
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}
