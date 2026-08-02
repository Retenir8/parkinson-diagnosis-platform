"""手部/腿部输入契约与分段清单边界测试。"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from app.modules.providers.hand_motion import (
    HandMotionModule,
    _parse_segment_manifest,
)
from app.modules.providers.leg_motion import LegMotionModule
from app.schemas.modules import InferenceRequest, InputArtifact
from app.schemas.segmentation import VideoSegmentUpdate


def _video_artifact(path: Path, module_id: str, slot: str) -> InputArtifact:
    path.write_bytes(b"test-video")
    return InputArtifact(
        id=f"{module_id}-{slot}",
        module_id=module_id,
        input_slot=slot,
        kind="video",
        path=path,
    )


@pytest.mark.parametrize("suffix", [".webm", ".m4v"])
def test_hand_accepts_frontend_video_suffixes(tmp_path: Path, suffix: str):
    artifact = _video_artifact(
        tmp_path / f"hand{suffix}", "hand-motion", "hand_video"
    )
    request = InferenceRequest(
        assessment_id="a1",
        patient_id="p1",
        module_id="hand-motion",
        inputs={"hand_video": (artifact,)},
    )

    issues = HandMotionModule().validate(request)

    assert not any("不支持的视频格式" in issue for issue in issues)


@pytest.mark.parametrize("suffix", [".webm", ".m4v"])
def test_leg_accepts_frontend_video_suffixes(tmp_path: Path, suffix: str):
    toe = _video_artifact(
        tmp_path / f"toe{suffix}", "leg-motion", "toe_tapping_video"
    )
    agility = _video_artifact(
        tmp_path / f"agility{suffix}", "leg-motion", "leg_agility_video"
    )
    request = InferenceRequest(
        assessment_id="a1",
        patient_id="p1",
        module_id="leg-motion",
        inputs={
            "toe_tapping_video": (toe,),
            "leg_agility_video": (agility,),
        },
    )

    issues = LegMotionModule().validate(request)

    assert not any("不支持的视频格式" in issue for issue in issues)


def test_hand_manifest_rejects_unknown_task_type(tmp_path: Path):
    manifest = tmp_path / "segments.json"
    manifest.write_text(
        json.dumps(
            {
                "segments": [
                    {
                        "segment_id": "s1",
                        "label": "步行",
                        "task_type": "walk",
                        "start_s": 0,
                        "end_s": 2,
                    }
                ]
            },
            ensure_ascii=False,
        ),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match="不受手部模块支持"):
        _parse_segment_manifest(manifest)


@pytest.mark.parametrize("crop_region", [(0, 0, 0, 10), (0, 0, 10, 0)])
def test_crop_region_requires_positive_size(
    crop_region: tuple[int, int, int, int],
):
    with pytest.raises(ValidationError, match="宽度和高度必须大于 0"):
        VideoSegmentUpdate(crop_region=crop_region)
