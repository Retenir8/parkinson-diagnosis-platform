"""Build the Windows Python API sidecar consumed by Tauri externalBin.

Only source files and the three shipped model assets are bundled. Patient
records, source media, and smart-shoe calibration recordings are excluded.
"""

from __future__ import annotations

import argparse
import importlib.util
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


SYSTEM_ROOT = Path(__file__).resolve().parents[2]
SERVER_ROOT = SYSTEM_ROOT / "server"
BIN_DIR = SYSTEM_ROOT / "apps" / "desktop" / "src-tauri" / "binaries"
MODEL_DIR = SERVER_ROOT / "models"
INTEGRATIONS_ROOT = SYSTEM_ROOT / "integrations"


def _host_target() -> str:
    target = subprocess.check_output(
        ["rustc", "--print", "host-tuple"], text=True
    ).strip()
    if target != "x86_64-pc-windows-msvc":
        raise RuntimeError(f"当前仅配置 Windows x64 MSVC 桌面包：{target}")
    return target


def _copy_shoes_source(staging_root: Path) -> Path:
    destination = staging_root / "integrations"
    allowed_suffixes = {".m", ".json"}
    excluded_directories = {"data", "docs", "tests", "diagnostics", "log", "third_party"}
    for source_root in (
        INTEGRATIONS_ROOT / "shoes_reference",
        INTEGRATIONS_ROOT / "shoes_bridge",
    ):
        if not source_root.is_dir():
            continue
        for source in source_root.rglob("*"):
            if not source.is_file() or source.suffix.lower() not in allowed_suffixes:
                continue
            relative = source.relative_to(INTEGRATIONS_ROOT)
            if excluded_directories.intersection(relative.parts):
                continue
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
    destination.mkdir(exist_ok=True)
    return destination


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--if-missing", action="store_true")
    args = parser.parse_args()
    target = _host_target()
    output = BIN_DIR / f"medvision-server-{target}.exe"
    if args.if_missing and output.is_file():
        print(f"复用已有桌面后端：{output}")
        return

    required_models = (
        MODEL_DIR / "overall_posture" / "three_class_walk17_classifier.pkl",
        MODEL_DIR / "overall_posture" / "pose_landmarker_full.task",
        MODEL_DIR / "overall_posture" / "model_metadata.json",
    )
    missing = [str(path) for path in required_models if not path.is_file()]
    if missing:
        raise FileNotFoundError("缺少桌面包模型资源：" + ", ".join(missing))
    if importlib.util.find_spec("pyrealsense2") is None:
        raise RuntimeError("桌面包需要 pyrealsense2，请先安装 requirements-desktop.txt")

    BIN_DIR.mkdir(parents=True, exist_ok=True)
    work_dir = SERVER_ROOT / "tmp" / "desktop-sidecar-build"
    work_dir.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="medvision-sidecar-") as staging:
        integrations = _copy_shoes_source(Path(staging))
        command = [
            sys.executable, "-m", "PyInstaller",
            "--noconfirm", "--clean", "--onefile", "--windowed",
            "--name", f"medvision-server-{target}",
            "--distpath", str(BIN_DIR),
            "--workpath", str(work_dir),
            "--specpath", str(work_dir),
            "--add-data", f"{MODEL_DIR};models",
            "--add-data", f"{integrations};integrations",
            "--collect-data", "mediapipe",
            "--collect-binaries", "mediapipe",
            "--hidden-import", "sklearn.pipeline",
            "--hidden-import", "sklearn.impute._base",
            "--hidden-import", "sklearn.feature_selection._univariate_selection",
            "--hidden-import", "sklearn.ensemble._forest",
            "--hidden-import", "pyrealsense2",
            "--exclude-module", "pytest",
            "--exclude-module", "torch",
            str(SERVER_ROOT / "desktop_entry.py"),
        ]
        subprocess.run(command, cwd=SERVER_ROOT, check=True)
    if not output.is_file():
        raise FileNotFoundError(f"PyInstaller 未生成桌面后端：{output}")
    print(f"桌面后端已生成：{output} ({output.stat().st_size:,} 字节)")


if __name__ == "__main__":
    main()
