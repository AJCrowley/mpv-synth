-- To the extent possible under law, the author(s) have dedicated all copyright
-- and related and neighboring rights to this software to the public domain
-- worldwide. This software is distributed without any warranty. See
-- <https://creativecommons.org/publicdomain/zero/1.0/> for a copy of the CC0
-- Public Domain Dedication, which applies to this software.

utils = require 'mp.utils'

local function clearPlaylist()
	local count
	while mp.get_property_number('playlist-count') > 1 do
		mp.commandv('playlist-remove', 0)
	end
end

local function open_dialog(type)
	mp.msg.info("Opening " .. type .. " dialog")
	local first_file
	local was_ontop = mp.get_property_native("ontop")
	if was_ontop then mp.set_property_native("ontop", false) end
	if type == 'file' then
		mp.msg.info("file dialog")
		local res = utils.subprocess({
			args = {'powershell', '-NoProfile', '-Command', [[& {
				Trap {
					Write-Error -ErrorRecord $_
					Exit 1
				}
				Add-Type -AssemblyName PresentationFramework

				$u8 = [System.Text.Encoding]::UTF8
				$out = [Console]::OpenStandardOutput()

				$ofd = New-Object Microsoft.Win32.OpenFileDialog
				$ofd.Multiselect = $true

				If ($ofd.ShowDialog() -eq $true) {
					ForEach ($filename in $ofd.FileNames) {
						$u8filename = $u8.GetBytes("$filename`n")
						$out.Write($u8filename, 0, $u8filename.Length)
					}
				}
			}]]},
			cancellable = false,
		})
		if was_ontop then mp.set_property_native("ontop", true) end
		if (res.status ~= 0) then return end
		first_file = true
		for filename in string.gmatch(res.stdout, '[^\n]+') do
			mp.commandv('loadfile', filename, first_file and 'replace' or 'append')
			first_file = false
		end
	elseif type == 'folder' then
		mp.msg.info("folder dialog")
		local res = utils.subprocess({
			args = {'powershell', '-NoProfile', '-Command', [[& {
				Trap {
					Write-Error -ErrorRecord $_
					Exit 1
				}
				Add-Type -AssemblyName System.Windows.Forms

				$folderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
				$folderBrowser.Description = "Select a folder"
				$folderBrowser.RootFolder = "MyComputer"

				# Show dialog and get result
				if ($folderBrowser.ShowDialog() -eq "OK") {
					$selectedFolder = $folderBrowser.SelectedPath
					ForEach ($file in Get-ChildItem -Path $selectedFolder -File | Where-Object { $_.Name -NotLike ".*" }) {
						Write-Host $file.FullName
					}
				}
			}]]},
			cancellable = false,
		})
		if was_ontop then mp.set_property_native("ontop", true) end
		if (res.status ~= 0) then return end
		first_file = true
		clearPlaylist()
		for filename in string.gmatch(res.stdout, '[^\n]+') do
			mp.commandv('loadfile', filename, first_file and 'replace' or 'append')
			first_file = false
		end
	end
end

local function open_file_dialog()
	open_dialog('file')
end

local function open_folder_dialog()
	open_dialog('folder')
end

mp.register_script_message('open_file_dialog', function()
    open_file_dialog()
end)

mp.register_script_message('open_folder_dialog', function()
    open_folder_dialog()
end)

mp.register_script_message('clear_playlist', function()
    clearPlaylist()
end)