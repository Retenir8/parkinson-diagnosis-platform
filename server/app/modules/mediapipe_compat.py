from __future__ import annotations

import os
import shutil
import tempfile
import threading
from pathlib import Path


_prepare_lock = threading.Lock()
_prepared = False


def prepare_legacy_solutions() -> None:
    """Prepare MediaPipe Legacy Solutions resources on Windows.

    MediaPipe 0.10.x passes its installed package path to a native resource
    loader. That loader can report existing graph files as missing when the
    virtual environment path contains non-ASCII characters. In that case only
    the packaged model resources are copied to an ASCII cache directory and
    SolutionBase is pointed at that cache.
    """

    global _prepared
    if _prepared:
        return

    with _prepare_lock:
        if _prepared:
            return

        import mediapipe as mp
        import mediapipe.python.solution_base as solution_base

        if not hasattr(mp, "solutions"):
            raise RuntimeError(
                "当前 MediaPipe 不包含 mp.solutions；"
                "请按 requirements.txt 安装固定版本。"
            )

        installed_root = Path(solution_base.__file__).resolve().parents[2]
        if str(installed_root).isascii():
            _prepared = True
            return

        configured = os.getenv("MEDVISION_MEDIAPIPE_RESOURCE_DIR")
        cache_root = (
            Path(configured).expanduser().resolve()
            if configured
            else (
                Path(tempfile.gettempdir())
                / "medvision-mediapipe-resources"
                / mp.__version__
            ).resolve()
        )
        if not str(cache_root).isascii():
            raise RuntimeError(
                "MediaPipe 安装路径包含非 ASCII 字符，默认缓存路径也不可用；"
                "请将 MEDVISION_MEDIAPIPE_RESOURCE_DIR 指向纯英文目录。"
            )

        source_modules = installed_root / "mediapipe" / "modules"
        target_modules = cache_root / "mediapipe" / "modules"
        ready_marker = cache_root / ".ready"
        if not ready_marker.is_file():
            shutil.copytree(
                source_modules,
                target_modules,
                dirs_exist_ok=True,
            )
            ready_marker.write_text(
                f"mediapipe={mp.__version__}\n",
                encoding="utf-8",
            )

        # SolutionBase derives its resource root from this module path. The
        # Python source file itself need not be copied; only the path prefix is
        # used when resolving graph and model assets.
        solution_base.__file__ = str(
            cache_root / "mediapipe" / "python" / "solution_base.py"
        )
        _prepared = True
