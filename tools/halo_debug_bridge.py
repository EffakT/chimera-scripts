"""
halo_debug_bridge.py

Watches for chimera_debug_dump.json (written by debug_core.lua when you
type dbgdump in Halo's console), grabs a screenshot of the Halo window
at that moment, and bundles both into one payload.

Wire up the actual API call once you've confirmed the bundle
looks right (see `build_bundle()` / the __main__ block below for where
that goes).

Requires (Windows):
    pip install mss pygetwindow pillow

Usage:
    1. Edit HALO_DOCS_DIR and HALO_WINDOW_TITLE below.
    2. Run: python halo_debug_bridge.py
    3. In-game, type dbgdump in console.
    4. Script detects the new dump, screenshots, writes a bundle to
       ./dumps/<timestamp>/  containing dump.json + screenshot.png + bundle.json
"""

import json
import time
import os
from pathlib import Path
from datetime import datetime

import mss
import mss.tools

try:
    import pygetwindow as gw
except ImportError:
    gw = None  # window-specific cropping is optional; falls back to full screen


# ---- Config ---------------------------------------------------------------
POLL_INTERVAL_SECONDS = 2
DUMP_FILENAME = "chimera_debug_dump.json"
def resolve_data_dir() -> Path:
    home = os.environ.get("USERPROFILE")

    if not home:
        return Path(".")

    plain_dir = Path(home) / "Documents" / "My Games" / "Halo" / "chimera" / "lua" / "data" / "global"

    onedrive_dir = (
        Path(home)
        / "OneDrive"
        / "Documents"
        / "My Games"
        / "Halo"
        / "chimera"
        / "lua"
        / "data"
        / "global"
    )

    cache_file = (
        Path(home)
        / "AppData"
        / "Local"
        / "debugcore_resolved_dir.txt"
    )

    if cache_file.exists():
        cached = Path(cache_file.read_text().strip())
        if cached.exists():
            return cached

    if plain_dir.exists():
        resolved = plain_dir
    elif onedrive_dir.exists():
        resolved = onedrive_dir
    else:
        resolved = plain_dir

    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(str(resolved))

    return resolved


OUTPUT_DIR = resolve_data_dir()
DUMP_PATH = OUTPUT_DIR / DUMP_FILENAME

def get_dump_path() -> Path:
    return DUMP_PATH

def read_dump(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def take_screenshot(out_path: Path) -> Path:
    with mss.mss() as sct:
        region = None

        if gw is not None:
            matches = gw.getWindowsWithTitle(HALO_WINDOW_TITLE)
            if matches:
                win = matches[0]
                region = {
                    "left": win.left,
                    "top": win.top,
                    "width": win.width,
                    "height": win.height,
                }

        if region is None:
            # Fall back to primary monitor if window not found
            region = sct.monitors[1]

        shot = sct.grab(region)
        mss.tools.to_png(shot.rgb, shot.size, output=str(out_path))

    return out_path


def build_bundle(dump_data: dict, screenshot_path: Path) -> dict:
    """
    Combines the structured game-state dump with a pointer to the screenshot.
    """
    return {
        "captured_at": datetime.now().isoformat(),
        "screenshot_path": str(screenshot_path),
        "dump": dump_data,
    }


def watch_and_capture():
    dump_path = get_dump_path()
    last_mtime = None

    print(f"Watching {dump_path} for changes...")
    print("In-game: type dbgdump in console (press ~) to trigger a snapshot.")

    while True:
        if dump_path.exists():
            mtime = dump_path.stat().st_mtime
            if last_mtime is None:
                last_mtime = mtime  # don't react to a stale pre-existing file on startup
            elif mtime != last_mtime:
                last_mtime = mtime
                handle_new_dump(dump_path)

        time.sleep(POLL_INTERVAL_SECONDS)


def handle_new_dump(dump_path: Path):
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    session_dir = OUTPUT_DIR / timestamp
    session_dir.mkdir(parents=True, exist_ok=True)

    # Small delay so the screenshot reflects the same moment as the dump
    # rather than the instant the file write started.
    dump_data = read_dump(dump_path)

    screenshot_path = take_screenshot(session_dir / "screenshot.png")

    # Keep a copy of the raw dump alongside the screenshot for this session
    with open(session_dir / "dump.json", "w", encoding="utf-8") as f:
        json.dump(dump_data, f, indent=2)

    bundle = build_bundle(dump_data, screenshot_path)
    with open(session_dir / "bundle.json", "w", encoding="utf-8") as f:
        json.dump(bundle, f, indent=2)

    print(f"[{timestamp}] Captured dump + screenshot -> {session_dir}")


if __name__ == "__main__":
    OUTPUT_DIR.mkdir(exist_ok=True)
    watch_and_capture()
