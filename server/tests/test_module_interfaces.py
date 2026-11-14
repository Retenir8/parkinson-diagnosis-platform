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
from app.modules.providers.leg_motion import (
    LegMotionModule,
    _parse_leg_segment_manifest,
)
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


def test_leg_combined_csv_reads_crop_region(tmp_path: Path):
    manifest = tmp_path / "segments.csv"
    manifest.write_text(
        "segment_id,label,task_type,side,start_s,end_s,crop_x,crop_y,crop_w,crop_h\n"
        "s1,左脚脚趾拍地,toe_tapping,left,0,2,10,20,300,400\n"
        "s2,右脚脚趾拍地,toe_tapping,right,2,4,10,20,300,400\n",
        encoding="utf-8",
    )

    segments, crop = _parse_leg_segment_manifest(manifest)

    assert [(item["task_type"], item["side"]) for item in segments] == [
        ("toe_tapping", "left"),
        ("toe_tapping", "right"),
    ]
    assert crop == (10, 20, 300, 400)


@pytest.mark.parametrize(
    "second, error",
    [
        ({"segment_id": "s1", "side": "right", "start_s": 2, "end_s": 4}, "ID 为空或重复"),
        ({"segment_id": "s2", "side": "left", "start_s": 2, "end_s": 4}, "存在多个片段"),
        ({"segment_id": "s2", "side": "right", "start_s": 1, "end_s": 4}, "时间重叠"),
    ],
)
def test_leg_manifest_rejects_ambiguous_segments(
    tmp_path: Path, second: dict, error: str,
):
    first = {
        "segment_id": "s1", "label": "左脚", "task_type": "toe_tapping",
        "side": "left", "start_s": 0, "end_s": 2,
    }
    manifest = tmp_path / "segments.json"
    manifest.write_text(
        json.dumps({"segments": [first, {**first, **second}]}),
        encoding="utf-8",
    )

    with pytest.raises(ValueError, match=error):
        _parse_leg_segment_manifest(manifest)


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


def test_hand_csv_manifest_reads_crop_region(tmp_path: Path):
    manifest = tmp_path / "segments.csv"
    manifest.write_text(
        "segment_id,label,task_type,side,start_s,end_s,crop_x,crop_y,crop_w,crop_h\n"
        "h1,左手对指,finger_opposition,left,0,3,40,50,300,320\n",
        encoding="utf-8",
    )

    segments, crop = _parse_segment_manifest(manifest)

    assert segments[0]["side"] == "left"
    assert crop == (40, 50, 300, 320)


@pytest.mark.parametrize("crop_region", [(0, 0, 0, 10), (0, 0, 10, 0)])
def test_crop_region_requires_positive_size(
    crop_region: tuple[int, int, int, int],
):
    with pytest.raises(ValidationError, match="宽度和高度必须大于 0"):
        VideoSegmentUpdate(crop_region=crop_region)
