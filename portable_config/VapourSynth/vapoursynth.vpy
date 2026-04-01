# VAPOURSYNTH FRAME INTERPOLATION SCRIPT
# Uses SVPflow for GPU-accelerated frame interpolation.
# Requires vs1-x64.dll and vs2-x64.dll in the same folder as this .vpy.
# Controlled by vapoursynth.lua, which maintains a per-file FPS prefs store.
#
# No longer uses a current_fps.txt intermediary. Instead:
#   1. vapoursynth.lua writes the current file path to vapoursynth_current_path.txt
#      at the start-file event (before watch-later restores the vf chain).
#   2. This script reads that path, looks it up in vapoursynth_fps.txt, and uses
#      whatever FPS is stored there.
#   3. If either file is missing or the path has no stored preference, the script
#      passes video_in through unmodified — no exception, no crash.

import vapoursynth as vs
import os

core = vs.core
core.num_threads = 0

script_directory = os.path.dirname(os.path.abspath(__file__))

CURRENT_PATH_FILE = os.path.join(script_directory, "vapoursynth_current_path.txt")
PREFS_FILE        = os.path.join(script_directory, "vapoursynth_fps.txt")

# ---------------------------------------------------------------------------
# Resolve target FPS from the prefs file, keyed by current file path.
# Returns 0 (pass-through) if anything is absent or unreadable.
# ---------------------------------------------------------------------------
def read_target_fps():
    try:
        if not os.path.isfile(CURRENT_PATH_FILE):
            return 0
        with open(CURRENT_PATH_FILE, "r", encoding="utf-8") as f:
            current_path = f.read().strip()
        if not current_path or not os.path.isfile(PREFS_FILE):
            return 0
        with open(PREFS_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                sep = line.rfind("|")
                if sep == -1:
                    continue
                if line[:sep] == current_path:
                    try:
                        return int(line[sep + 1:])
                    except ValueError:
                        return 0
    except Exception:
        pass
    return 0

target_fps = read_target_fps()

# ---------------------------------------------------------------------------
# No stored FPS preference — pass video through unmodified.
# Lua's file-loaded handler will explicitly add the filter if/when needed.
# ---------------------------------------------------------------------------
if target_fps == 0:
    video_in.set_output()

else:
    # ---------------------------------------------------------------------------
    # Load SVPflow plugins if not already loaded
    # ---------------------------------------------------------------------------
    if not hasattr(core, "svp1"):
        core.std.LoadPlugin(os.path.join(script_directory, "vs1-x64.dll"))
    if not hasattr(core, "svp2"):
        core.std.LoadPlugin(os.path.join(script_directory, "vs2-x64.dll"))

    # ---------------------------------------------------------------------------
    # SVPflow parameters
    # ---------------------------------------------------------------------------
    super_params     = "{pel:2, gpu:1, full:true, scale:{up:2, down:4}, rc:0}"

    analyse_params   = "{gpu:1, vectors:3, main:{levels:0, search:{type:4, distance:-4, sort:true, satd:false, coarse:{width:1050, type:4, distance:0, satd:true, trymany:false, bad:{sad:1000, range:-24}}}, penalty:{lambda:10.0, plevel:1.5, lsad:8000, pnew:50, pglobal:50, pzero:100, pnbour:50, prev:0}}, refine:[{thsad:200, search:{type:4, distance:2, satd:false}, penalty:{pnew:50}}], special:{delta:1}}}"

    smoothfps_params = "{rate:{num:" + str(target_fps) + ", den:1, abs:true}, algo:23, block:false, cubic:1, gpuid:11, linear:true, mask:{cover:100, area:0, area_sharp:1.0}, scene:{mode:3, blend:true, limits:{m1:1600, m2:2800, scene:4000, zero:200, blocks:20}, luma:1.5}, light:{aspect:0.0, sar:1.0, zoom:0.0, lights:16, length:100, cell:1.0, border:12}}"

    src_fps     = container_fps if container_fps > 0.1 else 23.976
    stereo_type = 0

    # ---------------------------------------------------------------------------
    # Interpolation function
    # ---------------------------------------------------------------------------
    clip = video_in

    def interpolate(clip):
        input_um = clip.resize.Point(format=vs.YUV420P10, dither_type="random")
        input_m  = input_um
        input_m  = input_m.std.CropRel(4, 4, 0, 0)
        input_m8 = input_m.resize.Point(format=vs.YUV420P8)

        super   = core.svp1.Super(input_m8, super_params)
        vectors = core.svp1.Analyse(super["clip"], super["data"], input_m8, analyse_params)
        smooth  = core.svp2.SmoothFps(input_m, super["clip"], super["data"], vectors["clip"], vectors["data"], smoothfps_params, src=input_um, fps=src_fps)

        return smooth

    # ---------------------------------------------------------------------------
    # Stereo 3D dispatch
    # ---------------------------------------------------------------------------
    # stereo_type: 0 = normal mono, 1 = side-by-side 3D, 2 = over-under 3D
    if stereo_type == 1:
        lf     = interpolate(core.std.CropRel(clip, 0, clip.width  // 2, 0, 0))
        rf     = interpolate(core.std.CropRel(clip, clip.width  // 2, 0, 0, 0))
        smooth = core.std.StackHorizontal([lf, rf])
    elif stereo_type == 2:
        lf     = interpolate(core.std.CropRel(clip, 0, 0, 0, clip.height // 2))
        rf     = interpolate(core.std.CropRel(clip, 0, 0, clip.height // 2, 0))
        smooth = core.std.StackVertical([lf, rf])
    else:
        smooth = interpolate(clip)

    smooth.set_output()
