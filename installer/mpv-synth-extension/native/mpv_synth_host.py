#!/usr/bin/env python3
"""
mpv-synth Native Messaging Host
Receives JSON messages from the browser extension via stdin/stdout
using the Chrome Native Messaging protocol.

Messages handled:
  { "action": "browse_folder" }
    -> Opens a folder-picker dialog; responds { "folder": "C:\\..." }

  {
    "action": "play",
    "mpv_location": "...",
    "config_location": "...",
    "cache_secs": 30,
    "limit_1080p": false,
    "url": "..."
  }
    -> Launches mpv in a detached process; responds { "success": true }
"""

import sys
import json
import struct
import subprocess
import os
import logging

# ── Logging (goes to a file so it doesn't pollute the stdio protocol) ────────
LOG_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mpv_synth_host.log')
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.DEBUG,
    format='%(asctime)s %(levelname)s %(message)s',
)
log = logging.getLogger('mpv_synth_host')

# ── Native Messaging wire protocol ───────────────────────────────────────────

def read_message():
    """Read one length-prefixed JSON message from stdin."""
    raw_len = sys.stdin.buffer.read(4)
    if len(raw_len) < 4:
        return None
    msg_len = struct.unpack('=I', raw_len)[0]
    raw_msg = sys.stdin.buffer.read(msg_len)
    return json.loads(raw_msg.decode('utf-8'))


def send_message(obj):
    """Write one length-prefixed JSON message to stdout."""
    encoded = json.dumps(obj).encode('utf-8')
    sys.stdout.buffer.write(struct.pack('=I', len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()

# ── Folder picker (requires tkinter — bundled with standard Python on Windows) ─

def browse_folder():
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk()
        root.withdraw()
        root.lift()
        root.attributes('-topmost', True)
        folder = filedialog.askdirectory(title='Select folder')
        root.destroy()
        if folder:
            folder = os.path.normpath(folder)
        return folder if folder else ''
    except Exception as exc:
        log.exception('browse_folder failed')
        return ''

# ── Launch mpv ────────────────────────────────────────────────────────────────

def play_url(mpv_location, config_location, url, cache_secs=30, limit_1080p=False):
    """
    Build and run:
      <mpv_location>\\mpv.exe
        --config-dir="<config_location>"
        --cache=yes
        --cache-secs=<cache_secs>
        --ytdl=yes
        [--ytdl-format=bestvideo[height<=?1080][vcodec!=?vp9]+bestaudio/best]
        <url>

    The process is detached so the browser doesn't wait for it to finish.
    """
    try:
        mpv_location    = os.path.normpath(mpv_location)
        config_location = os.path.normpath(config_location)

        if sys.platform == 'win32':
            mpv_exe = 'mpv.com'
            if not os.path.isfile(os.path.join(mpv_location, mpv_exe)):
                mpv_exe = 'mpv.exe'
        else:
            mpv_exe = 'mpv'

        mpv_path = os.path.join(mpv_location, mpv_exe)

        cmd = [
            mpv_path,
            '--config-dir=' + config_location,
            '--cache=yes',
            '--cache-secs=' + str(int(cache_secs)),
            '--ytdl=yes',
        ]

        if limit_1080p:
            cmd.append(
                '--ytdl-format=bestvideo[height<=?1080][vcodec!=?vp9]+bestaudio/best'
            )

        cmd.append(url)

        log.info('Launching (cwd=%s): %s', mpv_location, cmd)

        if sys.platform == 'win32':
            DETACHED_PROCESS         = 0x00000008
            CREATE_NEW_PROCESS_GROUP = 0x00000200
            subprocess.Popen(
                cmd,
                cwd=mpv_location,
                creationflags=DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP,
                close_fds=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        else:
            subprocess.Popen(
                cmd,
                cwd=mpv_location,
                start_new_session=True,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

        return {'success': True}

    except FileNotFoundError:
        msg = f'mpv executable not found in: {mpv_location} (looked for {mpv_exe})'
        log.error(msg)
        return {'success': False, 'error': msg}
    except Exception as exc:
        log.exception('play_url failed')
        return {'success': False, 'error': str(exc)}

# ── Main loop ─────────────────────────────────────────────────────────────────

def main():
    log.info('Native host started (pid=%d)', os.getpid())
    while True:
        try:
            message = read_message()
        except Exception as exc:
            log.exception('read_message failed')
            break

        if message is None:
            log.info('stdin closed, exiting')
            break

        action = message.get('action', '')
        log.debug('Received action=%s', action)

        if action == 'browse_folder':
            folder = browse_folder()
            log.debug('browse_folder -> %r', folder)
            send_message({'folder': folder})

        elif action == 'play':
            result = play_url(
                message.get('mpv_location', ''),
                message.get('config_location', ''),
                message.get('url', ''),
                cache_secs=message.get('cache_secs', 30),
                limit_1080p=message.get('limit_1080p', False),
            )
            send_message(result)

        else:
            log.warning('Unknown action: %s', action)
            send_message({'error': f'Unknown action: {action}'})


if __name__ == '__main__':
    main()
