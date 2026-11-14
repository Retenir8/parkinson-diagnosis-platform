"""Entry point for the packaged local API sidecar.

The data directory and auth token are supplied by the Tauri process before the
FastAPI application is imported. No patient files are embedded in the binary.
"""

from __future__ import annotations

import argparse
import multiprocessing
import os
import sys
from pathlib import Path


def main() -> None:
    multiprocessing.freeze_support()
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--data-dir", type=Path, required=True)
    args = parser.parse_args()
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    if not args.data_dir.is_absolute():
        parser.error("data-dir must be an absolute path")
    if not os.getenv("MEDVISION_DESKTOP_TOKEN"):
        parser.error("MEDVISION_DESKTOP_TOKEN is required for desktop mode")

    data_dir = args.data_dir.resolve()
    data_dir.mkdir(parents=True, exist_ok=True)
    log_dir = data_dir / "logs"
    log_dir.mkdir(exist_ok=True)
    os.environ["MEDVISION_DATA_DIR"] = str(data_dir)

    # PyInstaller's windowed executable has no console streams. Keep startup
    # failures and Uvicorn diagnostics in the user's own local data directory.
    log_stream = (log_dir / "backend.log").open("a", encoding="utf-8", buffering=1)
    sys.stdout = log_stream
    sys.stderr = log_stream

    import uvicorn
    from app.main import app

    uvicorn.run(
        app,
        host="127.0.0.1",
        port=args.port,
        log_config=None,
        access_log=False,
    )


if __name__ == "__main__":
    main()
