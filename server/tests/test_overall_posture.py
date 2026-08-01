from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.modules.providers.overall_posture import (
    WALK_FEATURES,
    OverallPostureModule,
)
from app.schemas.modules import InferenceRequest, InputArtifact


def test_overall_posture_walk17_inference_contract(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bag_path = tmp_path / "walk.bag"
    bag_path.write_bytes(b"test-bag-placeholder")
    manifest_path = tmp_path / "segments.json"
    manifest_path.write_text(
        json.dumps(
            {
                "walk_distance_m": 5.0,
                "segments": [
                    {
                        "segment_id": "1",
                        "label": "walk_1",
                        "task_type": "walk",
                        "start_s": 2.0,
                        "end_s": 7.0,
                    },
                    {
                        "segment_id": "2",
                        "label": "turn_1",
                        "task_type": "turn",
                        "start_s": 7.0,
                        "end_s": 8.0,
                    },
                ],
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )
    output_dir = tmp_path / "output"

    feature_values = {
        "SP_U": 1.0,
        "RA_AMP_U": 20.0,
        "LA_AMP_U": 19.0,
        "RA_STD_U": 2.0,
        "LA_STD_U": 2.1,
        "SYM_U": 0.05,
        "R_JERK_U": 4.0,
        "L_JERK_U": 4.2,
        "ASA_U": 1.5,
        "ASYM_IND_U": 2.5,
        "TRA_U": 1.0,
        "T_AMP_U": 8.0,
        "STR_T_U": 1.1,
        "STR_CV_U": 3.0,
        "STEP_REG_U": 0.7,
        "STEP_SYM_U": 0.9,
        "JERK_T_U": 2.0,
    }
    assert list(feature_values) == WALK_FEATURES

    captured_args = None

    def fake_analysis(args):
        nonlocal captured_args
        captured_args = args
        metrics_path = Path(args.out) / "metrics" / "walk_metrics.csv"
        metrics_path.parent.mkdir(parents=True, exist_ok=True)
        metrics_path.write_text("test", encoding="utf-8")
        video_path = Path(args.out) / "videos" / "walk_1_annotated.webm"
        video_path.parent.mkdir(parents=True, exist_ok=True)
        video_path.write_bytes(b"annotated-video")
        return {
            "metrics_path": metrics_path,
            "metric_rows": [
                {
                    "bag": "walk",
                    "segment_id": "1",
                    "label": "walk_1",
                    "task_type": "walk",
                    "start_s": 2.0,
                    "end_s": 7.0,
                    "duration_s": 5.0,
                    "metric_status": "computed",
                    "frames_total": 150,
                    "pose_detection_rate": 0.98,
                    "valid_depth_rate": 0.85,
                    **feature_values,
                }
            ],
            "quality_rows": [
                {
                    "segment_id": "1",
                    "label": "walk_1",
                    "annotated_video": str(video_path),
                }
            ],
        }

    monkeypatch.setattr(
        "app.modules.providers.overall_posture.analysis.run_analysis",
        fake_analysis,
    )
    module = OverallPostureModule()
    request = InferenceRequest(
        assessment_id="assessment-test",
        patient_id="patient-test",
        module_id="overall-posture",
        inputs={
            "walk_source": (
                InputArtifact(
                    id="bag",
                    module_id="overall-posture",
                    input_slot="walk_source",
                    kind="realsense_bag",
                    path=bag_path,
                ),
            ),
            "segment_manifest": (
                InputArtifact(
                    id="segments",
                    module_id="overall-posture",
                    input_slot="segment_manifest",
                    kind="tabular",
                    path=manifest_path,
                ),
            ),
        },
        parameters={"output_dir": str(output_dir)},
    )

    assert module.validate(request) == []
    progress: list[tuple[float, str]] = []
    result = module.infer(
        request,
        progress=lambda value, detail: progress.append((value, detail)),
    )

    assert captured_args is not None
    assert captured_args.walk_distance_m == 5.0
    assert captured_args.score_file is None
    assert captured_args.write_annotated_video is True
    assert captured_args.video_codec == "VP80"
    assert captured_args.write_excel_report is False
    assert result.module_id == "overall-posture"
    assert result.scores["np3gait_class"] in {0, 1, 2}
    assert result.metrics["walk_segment_count"] == 1
    assert result.result_data["model"]["features"] == WALK_FEATURES
    segment = result.result_data["segments"][0]
    assert segment["features"] == feature_values
    visualization = result.result_data["visualization"]
    assert visualization["availability"] == "ready"
    assert visualization["annotated_videos"][0]["artifact_index"] == 2
    assert len(result.output_artifacts) == 3
    probabilities = segment["prediction"]["probabilities"]
    assert sum(value for value in probabilities.values() if value is not None) == pytest.approx(1.0)
    assert any("忽略" in warning for warning in result.warnings)
    assert not any("补 0" in warning for warning in result.warnings)
    assert progress[-1][0] == 1.0

    normalized = (output_dir / "walk_segments.csv").read_text(
        encoding="utf-8-sig"
    )
    assert "walk_1" in normalized
    assert "turn_1" not in normalized
