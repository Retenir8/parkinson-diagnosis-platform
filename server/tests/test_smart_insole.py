"""Cross-check the System import against a real Shoes MATLAB recording."""

from __future__ import annotations

import csv
import hashlib
from pathlib import Path

import pytest

from app.modules.providers.smart_insole import SmartInsoleModule
from app.schemas.modules import InferenceRequest, InputArtifact


SYSTEM_ROOT = Path(__file__).resolve().parents[2]
SHOES_ROOT = SYSTEM_ROOT.parent / "Shoes"


def _request(paths: list[Path], output_dir: Path) -> InferenceRequest:
    artifacts = tuple(
        InputArtifact(
            id=str(index),
            module_id="smart-insole",
            input_slot="insole_data",
            kind="tabular",
            path=path,
            metadata={"original_name": path.name},
        )
        for index, path in enumerate(paths)
    )
    return InferenceRequest(
        assessment_id="assessment-test",
        patient_id="patient-test",
        module_id="smart-insole",
        inputs={"insole_data": artifacts},
        parameters={"output_dir": str(output_dir)},
    )


def _hash(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def test_source_copy_matches_shoes_code() -> None:
    if not SHOES_ROOT.is_dir():
        pytest.skip("Original Shoes checkout is not available")
    from tools.sync_shoes_source import sync

    manifest = sync(check=True)
    assert "runMqttGaitLowLatency.m" in manifest
    assert "src/trajectory/updateTrajectoryEstimator.m" in manifest
    assert not any(
        path.startswith(("data/", "diagnostics/", "docs/", "third_party/"))
        for path in manifest
    )


def test_import_preserves_source_files_and_reported_steps(tmp_path: Path) -> None:
    session = SHOES_ROOT / "log" / "20260923_105810_913"
    if not session.is_dir():
        pytest.skip("Recorded Shoes comparison session is not available")
    paths = sorted(session.glob("*.csv")) + sorted(session.glob("*.txt"))
    module = SmartInsoleModule()
    request = _request(paths, tmp_path / "outputs")
    assert module.validate(request) == []
    result = module.infer(request)
    assert result.module_id == "smart-insole"
    assert result.scores == {}
    assert len(result.output_artifacts) == len(paths)
    for source, output in zip(paths, result.output_artifacts):
        assert _hash(source) == _hash(Path(output))

    step_path = next(path for path in paths if path.name.startswith("step_metrics_"))
    with step_path.open(encoding="utf-8-sig", newline="") as stream:
        source_steps = list(csv.DictReader(stream))
    for foot in ("left", "right"):
        source_count = sum(row["foot"] == foot for row in source_steps)
        assert result.metrics[f"{foot}_step_count"] == source_count
    assert result.quality["step_rows"] == len(source_steps)
    assert set(result.result_data["pressure_maps"]) <= {"left", "right"}
    if source_steps:
        last = source_steps[-1]
        assert result.result_data["steps"][-1]["reported_step_length_m"] == float(last["step_length_m"])
        assert result.result_data["steps"][-1]["reported_step_frequency_spm"] == float(last["step_frequency_spm"])

    gait_path = next(path for path in paths if path.name.startswith("gait_state_"))
    latest_by_foot: dict[str, dict[str, str]] = {}
    with gait_path.open(encoding="utf-8-sig", newline="") as stream:
        for row in csv.DictReader(stream):
            if row["foot"] in {"left", "right"}:
                latest_by_foot[row["foot"]] = row
    for foot, row in latest_by_foot.items():
        matrix = result.result_data["pressure_maps"][foot]
        for index in range(48):
            assert matrix[index % 12][index // 12] == float(row[f"p{index + 1:02d}"])


def test_rejects_mixed_shoes_sessions(tmp_path: Path) -> None:
    first = tmp_path / "gait_state_20260923_105810_913.csv"
    second = tmp_path / "step_metrics_20260923_105601_469.csv"
    first.write_text("foot,t\nleft,1\n", encoding="utf-8")
    second.write_text("foot,t\nleft,2\n", encoding="utf-8")
    issues = SmartInsoleModule().validate(_request([first, second], tmp_path / "outputs"))
    assert any("不同 Shoes 采集会话" in issue for issue in issues)
