"""Packaged desktop runtime boundary tests."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

from tools.build_desktop_sidecar import _copy_shoes_source


def test_desktop_token_required_for_local_api(tmp_path: Path) -> None:
    script = """
from fastapi.testclient import TestClient
from app.main import app
client = TestClient(app)
assert client.get('/api/v1/health').status_code == 403
assert client.get('/api/v1/health', headers={'X-Medvision-Token': 'desktop-test-token'}).status_code == 200
assert client.get('/api/v1/health?desktop_token=desktop-test-token').status_code == 200
"""
    env = os.environ.copy()
    env["MEDVISION_DATA_DIR"] = str(tmp_path / "desktop-data")
    env["MEDVISION_DESKTOP_TOKEN"] = "desktop-test-token"
    result = subprocess.run(
        [sys.executable, "-c", script],
        cwd=Path(__file__).resolve().parents[1],
        env=env,
        capture_output=True,
        text=True,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_desktop_bundle_excludes_shoes_recordings(tmp_path: Path) -> None:
    destination = _copy_shoes_source(tmp_path)
    assert (destination / "shoes_bridge" / "runShoesFromSystem.m").is_file()
    assert not (destination / "shoes_reference" / "data").exists()
    assert not list(destination.rglob("*.bag"))
    assert not list(destination.rglob("*.csv"))
