# Update pip
python -m pip install --upgrade pip
# Update subliminal
pip install --upgrade subliminal

# OPTIONAL IF SUBLIMINAL NOT WORKING
Write-Host "edit your opensubs.conf file and make sure that none of the values have quotes around them." -ForegroundColor Green

$pythonCode = @"
import logging
try:
    from subliminal.providers.opensubtitlescom import (
        OpenSubtitlesComProvider,
        OpenSubtitlesComError,
    )
    _logger = logging.getLogger(__name__)
    _original_search = OpenSubtitlesComProvider._search
    def _patched_search(self, *args, **kwargs):
        try:
            yield from _original_search(self, *args, **kwargs)
        except OpenSubtitlesComError as e:
            _logger.warning(
                'OpenSubtitles.com pagination error, stopping early and '
                'keeping results found so far: %s', e,
            )
            return
    OpenSubtitlesComProvider._search = _patched_search
except ImportError:
    # subliminal isn't installed in this environment; nothing to patch
    pass
"@

# Ask Python where its site-packages actually live, instead of guessing the path.
$sitePackages = (python -c "import site; print(site.getsitepackages()[0])").Trim()

if (-not $sitePackages -or -not (Test-Path $sitePackages)) {
    Write-Host "Could not resolve site-packages path via Python. Falling back to version-based path." -ForegroundColor Yellow

    # Get "314" style tag from the running interpreter
    $verTag = (python -c "import sys; print(f'{sys.version_info.major}{sys.version_info.minor}')").Trim()
    $sitePackages = "$env:USERPROFILE\AppData\Local\Programs\Python\Python$verTag\Lib\site-packages"
}

$targetPath = Join-Path $sitePackages "sitecustomize.py"
Set-Content -Path $targetPath -Value $pythonCode
Write-Host "sitecustomize.py written to: $targetPath" -ForegroundColor Cyan

# If still not working update all root certs, run roots.sst as soon as generated
# certutil -generateSSTFromWU roots.sst