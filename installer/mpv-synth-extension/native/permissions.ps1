$pc_dir = Join-Path (Get-Location).Path "..\..\mpv-synth-extension"
if (Test-Path $pc_dir) {
	Write-Host "Setting ACL on: $pc_dir" -ForegroundColor Yellow
	& icacls $pc_dir /grant "${env:USERNAME}:(OI)(CI)F" /T | Out-Null
}