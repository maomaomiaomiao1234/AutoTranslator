#!/usr/bin/env python3
"""Build helper for packaging the project as a macOS .app via py2app."""

from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path


ROOT = Path(__file__).parent.resolve()
STAGE_ROOT = ROOT / ".py2app-build"
STAGE_APP = STAGE_ROOT / "app"
DIST_DIR = ROOT / "dist"
APP_NAME = "AutoTranslator"
ICON_FILE = ROOT / "assets" / f"{APP_NAME}.icns"
COPY_IGNORE = shutil.ignore_patterns("__pycache__", "*.pyc", "*.pyo", ".DS_Store")

STAGE_SETUP = """\
from setuptools import setup

APP = ["macos_app.py"]
OPTIONS = {
    "argv_emulation": False,
    "strip": False,
    "packages": ["backend", "frontend"],
    "includes": [
        "objc",
        "Quartz",
        "Cocoa",
        "AppKit",
        "Foundation",
        "ApplicationServices",
    ],
    "plist": {
        "CFBundleName": "AutoTranslator",
        "CFBundleDisplayName": "AutoTranslator",
        "CFBundleIdentifier": "com.autotranslator.desktop",
        "CFBundleShortVersionString": "0.1.0",
        "CFBundleVersion": "0.1.0",
        "CFBundleExecutable": "AutoTranslator",
        "CFBundlePackageType": "APPL",
        "LSUIElement": True,
        "NSHighResolutionCapable": True,
    },
}

try:
    from pathlib import Path
    icon_path = Path("assets/AutoTranslator.icns")
    if icon_path.exists():
        OPTIONS["iconfile"] = str(icon_path)
except Exception:
    pass

setup(
    app=APP,
    options={"py2app": OPTIONS},
    setup_requires=["py2app"],
)
"""


def prepare_stage():
    if STAGE_ROOT.exists():
        shutil.rmtree(STAGE_ROOT)

    STAGE_APP.mkdir(parents=True)
    shutil.copy2(ROOT / "macos_app.py", STAGE_APP / "macos_app.py")
    shutil.copytree(ROOT / "backend", STAGE_APP / "backend", ignore=COPY_IGNORE)
    shutil.copytree(ROOT / "frontend", STAGE_APP / "frontend", ignore=COPY_IGNORE)

    if ICON_FILE.exists():
        assets_dir = STAGE_APP / "assets"
        assets_dir.mkdir()
        shutil.copy2(ICON_FILE, assets_dir / ICON_FILE.name)

    (STAGE_APP / "setup.py").write_text(STAGE_SETUP, encoding="utf-8")


def copy_artifact():
    stage_dist = STAGE_APP / "dist"
    if not stage_dist.exists():
        raise SystemExit("py2app 未生成 dist 目录")

    if DIST_DIR.exists():
        shutil.rmtree(DIST_DIR)
    shutil.copytree(stage_dist, DIST_DIR, symlinks=True)


def ensure_supported_python():
    alias_mode = any(arg in ("-A", "--alias") for arg in sys.argv[2:])
    if alias_mode:
        return

    import zlib

    if getattr(zlib, "__file__", None):
        return

    raise SystemExit(
        "当前 Python 运行时不支持 py2app 的完整 standalone 构建。\n"
        "原因：当前解释器把 zlib 编译成了内建模块，py2app 无法打包它。\n"
        "可行方案：\n"
        "1. 继续使用开发版构建：uv run --with py2app python setup.py py2app -A\n"
        "2. 安装 python.org 的 Framework Python 3.12，再执行正式构建：\n"
        "   uv run --with py2app python setup.py py2app"
    )


def main():
    if len(sys.argv) < 2 or sys.argv[1] != "py2app":
        raise SystemExit(
            "Usage: python setup.py py2app [py2app options]\n"
            "Example: uv run --with py2app python setup.py py2app -A"
        )

    ensure_supported_python()
    prepare_stage()
    cmd = [sys.executable, "setup.py", *sys.argv[1:]]
    subprocess.run(cmd, cwd=STAGE_APP, check=True)
    copy_artifact()
    print(f"Built app bundle: {DIST_DIR / (APP_NAME + '.app')}")


if __name__ == "__main__":
    main()
