#!/usr/bin/env python3
"""Point macOS 14+ idle wallpaper at The Gibson screensaver appex.

System Settings can list the extension after pluginkit registration while
hot corners / idle still run a built-in saver. This writes the same Idle
blob PaperSaver uses for an .appex screensaver.
"""

from __future__ import annotations

import os
import plistlib
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path


APP = Path("/Applications/TheGibson.app")
APPEX = APP / "Contents/PlugIns/TheGibson.appex"
INDEX = (
    Path.home()
    / "Library/Application Support/com.apple.wallpaper/Store/Index.plist"
)


def binary_plist(obj) -> bytes:
    return plistlib.dumps(obj, fmt=plistlib.FMT_BINARY)


def idle_blob(appex: Path) -> dict:
    now = datetime.now(timezone.utc)
    config = binary_plist({"module": {"relative": appex.resolve().as_uri()}})
    return {
        "Content": {
            "Choices": [
                {
                    "Configuration": config,
                    "Files": [],
                    "Provider": "com.apple.wallpaper.choice.screen-saver",
                }
            ]
        },
        "LastSet": now,
        "LastUse": now,
    }


def set_module_dict(appex: Path) -> None:
    subprocess.run(
        [
            "defaults",
            "-currentHost",
            "write",
            "com.apple.screensaver",
            "moduleDict",
            "-dict",
            "moduleName",
            "The Gibson",
            "path",
            str(appex),
            "type",
            "-int",
            "0",
        ],
        check=False,
    )


def restart_wallpaper_agent() -> None:
    subprocess.run(
        ["killall", "WallpaperAgent"],
        check=False,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def idle_module(plist: dict) -> str | None:
    try:
        data = plist["AllSpacesAndDisplays"]["Idle"]["Content"]["Choices"][0][
            "Configuration"
        ]
        inner = plistlib.loads(data)
        return inner["module"]["relative"]
    except Exception:
        return None


def main() -> int:
    if not APPEX.exists():
        print(f"missing {APPEX}", file=sys.stderr)
        print("Install first with: make install-saver", file=sys.stderr)
        return 1
    if not INDEX.exists():
        print(f"missing {INDEX}", file=sys.stderr)
        return 1

    backup = INDEX.with_suffix(".plist.gibson-bak")
    if not backup.exists():
        shutil.copy2(INDEX, backup)
        print(f"backed up {backup}")

    with INDEX.open("rb") as fh:
        plist = plistlib.load(fh)

    idle = idle_blob(APPEX)
    for key in ("AllSpacesAndDisplays", "SystemDefault"):
        section = plist.get(key)
        if isinstance(section, dict):
            section["Idle"] = idle

    tmp = INDEX.with_suffix(".plist.tmp")
    with tmp.open("wb") as fh:
        plistlib.dump(plist, fh, fmt=plistlib.FMT_BINARY)
    os.replace(tmp, INDEX)
    set_module_dict(APPEX)
    restart_wallpaper_agent()
    time.sleep(1.5)

    with INDEX.open("rb") as fh:
        after = plistlib.load(fh)
    url = idle_module(after)
    print(f"idle module={url}")
    if url and "TheGibson.appex" in url:
        print("hot corners should now load The Gibson")
        return 0

    print("WallpaperAgent rewrote Idle; writing again", file=sys.stderr)
    with INDEX.open("rb") as fh:
        plist = plistlib.load(fh)
    idle = idle_blob(APPEX)
    for key in ("AllSpacesAndDisplays", "SystemDefault"):
        section = plist.get(key)
        if isinstance(section, dict):
            section["Idle"] = idle
    with tmp.open("wb") as fh:
        plistlib.dump(plist, fh, fmt=plistlib.FMT_BINARY)
    os.replace(tmp, INDEX)
    restart_wallpaper_agent()
    time.sleep(1.5)
    with INDEX.open("rb") as fh:
        after = plistlib.load(fh)
    url = idle_module(after)
    print(f"idle module={url}")
    return 0 if url and "TheGibson.appex" in url else 2


if __name__ == "__main__":
    raise SystemExit(main())
