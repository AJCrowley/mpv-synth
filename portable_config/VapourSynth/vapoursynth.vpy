# VAPOURSYNTH FRAME INTERPOLATION SCRIPT (R80+ era)
# Uses open-svpflow (https://github.com/Z1xus/open-svpflow) for GPU-accelerated
# frame interpolation, on VapourSynth R80+ (API 4). The classic closed
# SVPflow plugins are API 3 and R80+ cores refuse them; open-svpflow is the
# drop-in replacement (reverse-engineered from SVPFlow 4.3.0.168, Apache-2.0).
#
# Controlled by vapoursynth.lua. Three plumbing channels:
#   1. vapoursynth_params.json  - the interpolation knobs (written by the lua
#      at start-file from the script-opts). This script merges them over
#      DEFAULTS below; unknown keys in the JSON are ignored, missing keys
#      fall back to defaults, so old configs keep working after upgrades.
#   2. vapoursynth_fps.txt      - the per-file target FPS store (unchanged).
#   3. vapoursynth_current_path.txt - which file is playing right now.
#
# Plugin loading: R80+ auto-loads pip-installed plugins (pip install
# open-svpflow), so the explicit LoadPlugin only happens when the DLLs were
# placed manually in this folder. If neither exists, the video passes through
# unmodified without an exception.
#
# GPU knobs (cubic, gpuid, lean/exact acceleration) are only sent to the
# plugins when hardware.gpu is on; the CPU path rejects them outright.

import vapoursynth as vs
import os
import json

core = vs.core
core.num_threads = 0

script_directory = os.path.dirname(os.path.abspath(__file__))

CURRENT_PATH_FILE = os.path.join(script_directory, "vapoursynth_current_path.txt")
PREFS_FILE        = os.path.join(script_directory, "vapoursynth_fps.txt")
PARAMS_FILE       = os.path.join(script_directory, "vapoursynth_params.json")

# ---------------------------------------------------------------------------
# Defaults. vapoursynth_params.json overrides any of these flat keys.
# ---------------------------------------------------------------------------
DEFAULTS = {
    "hardware": {
        "gpu": 1,       # 0 = CPU rendering (slower, no cubic/gpuid), 1 = GPU
        "gpuid": 11,    # the device id as svpflow expects it
    },
    "super": {
        "pel": 2,           # subpixel precision: 1 or 2
        "full": True,       # build the full pyramid
        "scale_up": 2,      # scale:{up:N}
        "scale_down": 4,    # scale:{down:N}
        "rc": 0,
        "lean": False,      # open-svpflow: skip subpel/reduced levels when the
                            # GPU analyse chain builds them itself (fast,
                            # needs VRAM; pairs with gpu:1)
    },
    "analyse": {
        "vectors": 3,           # the number of vector refine passes
        "levels": 0,            # pyramid levels (0 = auto)
        "search_distance": -4,  # main search distance
        "coarse_width": 1050,   # the coarse pass width cap
        "coarse_satd": True,
        "refine_distance": 2,
    },
    "smooth": {
        "algo": 23,         # 23 = the standard high-quality path
        "block": False,
        "linear": True,
        "mask_cover": 100,
        "mask_area": 0,
        "mask_area_sharp": 1.0,
        "scene_mode": 3,
        "scene_blend": True,
        "limit_m1": 1600,
        "limit_m2": 2800,
        "limit_scene": 4000,
        "limit_zero": 200,
        "limit_blocks": 20,
        "luma": 1.5,
    },
    "features": {
        "cubic": False,         # GPU-only interpolation mode
        "dedup": 0.0,           # open-svpflow: 0..1+, 0 = off
        "still_mask": False,    # open-svpflow: keep static text/logos crisp
        "peel_mask": False,     # open-svpflow: learn and remove HUDs
        "peel_limit": 6,
        "still_limit": 4.5,
        "still_edge": 5,
        "still_tolerance": 30,
    },
    "pipeline": {
        # open-svpflow renders 8-bit only (both CPU and GPU; I444 is 8-bit
        # too), so the runtime is forced to 8 regardless of this knob for
        # now. The key stays for the day a 10-bit build ships, and mirrors
        # the classic script's behaviour with the closed plugins if anyone
        # restores them.
        "bitdepth": 8,
    },
}

def deep_merge(base, overrides):
    """One-level deep merge per section; unknown keys are dropped."""
    out = {}
    for section, values in base.items():
        incoming = overrides.get(section, {}) if isinstance(overrides, dict) else {}
        merged = dict(values)
        for key, value in incoming.items():
            if key in values:
                merged[key] = value
        out[section] = merged
    return out

def read_params():
    try:
        if os.path.isfile(PARAMS_FILE):
            with open(PARAMS_FILE, "r", encoding="utf-8") as f:
                incoming = json.load(f)
            if isinstance(incoming, dict):
                return deep_merge(DEFAULTS, incoming)
    except Exception:
        pass
    return dict(DEFAULTS)

params = read_params()

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
# No stored FPS preference - pass video through unmodified.
# ---------------------------------------------------------------------------
if target_fps == 0:
    video_in.set_output()

else:
    # -----------------------------------------------------------------------
    # Locate the plugins. open-svpflow pip installs auto-load on R80+; the
    # manual-DLL layout needs explicit LoadPlugin with its historical guard.
    # -----------------------------------------------------------------------
    use_gpu   = bool(params["hardware"]["gpu"])
    gpuid     = int(params["hardware"]["gpuid"])

    def _pip_plugin_path(dll_name):
        """site-packages/vapoursynth/plugins/open-svpflow/<name> if present."""
        import importlib.util
        spec = importlib.util.find_spec("vapoursynth")
        if not spec or not spec.origin:
            return None
        pkg_dir = os.path.dirname(spec.origin)
        name = dll_name if os.name == "nt" else dll_name.replace("svpflow", "libsvpflow").replace(".dll", ".so")
        candidate = os.path.join(pkg_dir, "plugins", "open-svpflow", name)
        return candidate if os.path.isfile(candidate) else None

    if not hasattr(core, "svp1"):
        try:
            core.std.LoadPlugin(os.path.join(script_directory, "svpflow1_vs.dll"))
        except Exception as load_error:
            candidate = _pip_plugin_path("svpflow1_vs.dll")
            if not candidate:
                raise load_error
            core.std.LoadPlugin(candidate)
    if not hasattr(core, "svp2"):
        try:
            core.std.LoadPlugin(os.path.join(script_directory, "svpflow2_vs.dll"))
        except Exception as load_error:
            candidate = _pip_plugin_path("svpflow2_vs.dll")
            if not candidate:
                raise load_error
            core.std.LoadPlugin(candidate)

    # -----------------------------------------------------------------------
    # Build the SVPflow parameter JSON from the merged flat knobs.
    # GPU-only keys are pruned on the CPU path (the CPU renderer rejects
    # cubic/gpuid outright).
    # -----------------------------------------------------------------------
    sup = params["super"]
    super_parts = ["pel:" + str(sup["pel"]),
                   "gpu:" + ("1" if use_gpu else "0"),
                   "full:" + ("true" if sup["full"] else "false"),
                   "scale:{up:" + str(sup["scale_up"]) + ", down:" + str(sup["scale_down"]) + "}",
                   "rc:" + str(sup["rc"])]
    if use_gpu and sup.get("lean"):
        super_parts.append("lean:true")
    super_params = "{" + ", ".join(super_parts) + "}"

    ana = params["analyse"]
    analyse_params = ("{gpu:" + ("1" if use_gpu else "0") +
                      ", vectors:" + str(ana["vectors"]) +
                      ", main:{levels:" + str(ana["levels"]) +
                      ", search:{type:4, distance:" + str(ana["search_distance"]) +
                      ", sort:true, satd:false" +
                      ", coarse:{width:" + str(ana["coarse_width"]) +
                      ", type:4, distance:0, satd:" + ("true" if ana["coarse_satd"] else "false") +
                      ", trymany:false, bad:{sad:1000, range:-24}}}" +
                      ", penalty:{lambda:10.0, plevel:1.5, lsad:8000, pnew:50, pglobal:50, pzero:100, pnbour:50, prev:0}}" +
                      ", refine:[{thsad:200, search:{type:4, distance:" + str(ana["refine_distance"]) +
                      ", satd:false}, penalty:{pnew:50}}]}")

    smo = params["smooth"]
    mask = ("mask:{cover:" + str(smo["mask_cover"]) +
            ", area:" + str(smo["mask_area"]) +
            ", area_sharp:" + str(smo["mask_area_sharp"]))
    if params["features"]["peel_mask"]:
        mask += ", peel:{limit:" + str(params["features"]["peel_limit"]) + "}"
    if params["features"]["still_mask"]:
        mask += (", still:{limit:" + str(params["features"]["still_limit"]) +
                 ", edge:" + str(params["features"]["still_edge"]) +
                 ", tolerance:" + str(params["features"]["still_tolerance"]) + "}")
    mask += "}"
    smooth_parts = ["rate:{num:" + str(target_fps) + ", den:1, abs:true}",
                    "algo:" + str(smo["algo"]),
                    "block:" + ("true" if smo["block"] else "false"),
                    mask,
                    "scene:{mode:" + str(smo["scene_mode"]) +
                    ", blend:" + ("true" if smo["scene_blend"] else "false") +
                    ", limits:{m1:" + str(smo["limit_m1"]) +
                    ", m2:" + str(smo["limit_m2"]) +
                    ", scene:" + str(smo["limit_scene"]) +
                    ", zero:" + str(smo["limit_zero"]) +
                    ", blocks:" + str(smo["limit_blocks"]) + "}" +
                    ", luma:" + str(smo["luma"]) + "}"]
    if params["features"]["dedup"] and float(params["features"]["dedup"]) > 0:
        smooth_parts.append("dedup:" + str(params["features"]["dedup"]))
    if use_gpu:
        if smo.get("cubic"):
            smooth_parts.append("cubic:1")
        smooth_parts.append("gpuid:" + str(gpuid))
    smooth_params = "{" + ", ".join(smooth_parts) + "}"

    src_fps     = container_fps if container_fps > 0.1 else 23.976
    stereo_type = 0

    clip = video_in

    # open-svpflow renders 8-bit only today (CPU and GPU alike), so every
    # intermediate is 8-bit. The knob remains for a future 10-bit build.
    bitdepth = int(params["pipeline"]["bitdepth"])
    if bitdepth < 8:
        bitdepth = 8
    if bitdepth > 8:
        bitdepth = 8  # see comment above; the OSS renderer is 8-bit for now

    def interpolate(clip):
        input_um  = clip.resize.Point(format=vs.YUV420P10 if bitdepth > 8 else vs.YUV420P8,
                                      dither_type="random")
        input_m   = input_um
        input_m   = input_m.std.CropRel(0, 0, 0, 0)
        input_m8  = input_m.resize.Point(format=vs.YUV420P8)
        smooth_in = input_m if bitdepth > 8 else input_m8

        super_clip  = core.svp1.Super(input_m8, super_params)
        vectors     = core.svp1.Analyse(super_clip["clip"], super_clip["data"],
                                        input_m8, analyse_params)
        smooth_clip = core.svp2.SmoothFps(smooth_in, super_clip["clip"], super_clip["data"],
                                          vectors["clip"], vectors["data"],
                                          smooth_params, src=input_um, fps=src_fps)
        return smooth_clip

    # Stereo 3D dispatch: 0 = mono, 1 = side-by-side, 2 = over-under
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
