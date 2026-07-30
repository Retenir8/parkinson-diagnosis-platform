"""
直接推理测试 — 绕过 API，直接调用 HandMotionModule / LegMotionModule
====================================================================
使用方式：
    cd E:/aiMDS/parkinson-diagnosis-platform/server
    python tests/test_inference.py

前提：已 pip install numpy opencv-python mediapipe pyrealsense2
"""

import sys
from pathlib import Path

# tests/ 的父目录是 server/
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from app.modules.providers.hand_motion import HandMotionModule
from app.modules.providers.leg_motion import LegMotionModule
from app.schemas.modules import InferenceRequest, InputArtifact

HAND_BAG = Path(r"E:\aiMDS\bag\20260421.bag")
TOE_BAG  = Path(r"E:\aiMDS\bag\20260603_113005_2.bag")
LEG_BAG  = Path(r"E:\aiMDS\bag\20260603_113005_3.bag")


def test_hand():
    print("\n" + "=" * 70)
    print("  手部运动分析 (手指对指 / 手掌轮替 / 握拳)")
    print("=" * 70)

    module = HandMotionModule()

    if not HAND_BAG.exists():
        print(f"  ✗ 文件不存在: {HAND_BAG}")
        return

    artifact = InputArtifact(
        id="test-hand",
        module_id="hand-motion",
        input_slot="hand_video",
        kind="realsense_bag",
        path=HAND_BAG,
        metadata={},
    )
    request = InferenceRequest(
        assessment_id="test",
        patient_id="test",
        module_id="hand-motion",
        inputs={"hand_video": (artifact,)},
        parameters={},
    )

    issues = module.validate(request)
    if issues:
        print("  校验问题:", issues)
        return

    print(f"  输入: {HAND_BAG}")
    print("  推理中...")

    def progress(pct, msg):
        print(f"    [{pct:.0%}] {msg}")

    result = module.infer(request, progress=progress)

    print(f"\n  质量: {result.quality}")
    print(f"  摘要: {result.summary}")
    print(f"\n  评分明细:")
    for side in ("left", "right"):
        for task in ("finger_opposition", "hand_alternation", "fist_clenching"):
            r = result.result_data["tasks"][task][side]
            status = r["status"]
            score = r.get("score", "-")
            count = r["detected_actions"]
            print(f"    {task:25s} {side:5s}: {status:12s} score={score}  count={count}")

    if result.warnings:
        print(f"\n  警告: {result.warnings}")


def test_leg_toe():
    print("\n" + "=" * 70)
    print("  腿部运动分析 — 脚趾拍地 (MDS-UPDRS 3.7)")
    print("=" * 70)

    module = LegMotionModule()

    if not TOE_BAG.exists():
        print(f"  ✗ 文件不存在: {TOE_BAG}")
        return

    artifact = InputArtifact(
        id="test-toe",
        module_id="leg-motion",
        input_slot="toe_tapping_video",
        kind="realsense_bag",
        path=TOE_BAG,
        metadata={},
    )
    request = InferenceRequest(
        assessment_id="test",
        patient_id="test",
        module_id="leg-motion",
        inputs={"toe_tapping_video": (artifact,)},
        parameters={},
    )

    issues = module.validate(request)
    if issues:
        print("  校验问题:", issues)
        return

    print(f"  输入: {TOE_BAG}")
    print("  推理中...")

    def progress(pct, msg):
        print(f"    [{pct:.0%}] {msg}")

    result = module.infer(request, progress=progress)

    print(f"\n  质量: {result.quality}")
    print(f"  摘要: {result.summary}")
    print(f"\n  评分明细:")
    for side in ("left", "right"):
        r = result.result_data["tasks"]["toe_tapping"][side]
        print(f"    toe_tapping {side:5s}: {r['status']:12s} score={r.get('score', '-')}  count={r['detected_actions']}")
    if result.warnings:
        print(f"\n  警告: {result.warnings}")


def test_leg_agility():
    print("\n" + "=" * 70)
    print("  腿部运动分析 — 抬腿灵活性 (MDS-UPDRS 3.8)")
    print("=" * 70)

    module = LegMotionModule()

    if not LEG_BAG.exists():
        print(f"  ✗ 文件不存在: {LEG_BAG}")
        return

    artifact = InputArtifact(
        id="test-leg",
        module_id="leg-motion",
        input_slot="leg_agility_video",
        kind="realsense_bag",
        path=LEG_BAG,
        metadata={},
    )
    request = InferenceRequest(
        assessment_id="test",
        patient_id="test",
        module_id="leg-motion",
        inputs={"leg_agility_video": (artifact,)},
        parameters={},
    )

    issues = module.validate(request)
    if issues:
        print("  校验问题:", issues)
        return

    print(f"  输入: {LEG_BAG}")
    print("  推理中...")

    def progress(pct, msg):
        print(f"    [{pct:.0%}] {msg}")

    result = module.infer(request, progress=progress)

    print(f"\n  质量: {result.quality}")
    print(f"  摘要: {result.summary}")
    print(f"\n  评分明细:")
    for side in ("left", "right"):
        r = result.result_data["tasks"]["leg_agility"][side]
        print(f"    leg_agility {side:5s}: {r['status']:12s} score={r.get('score', '-')}  count={r['detected_actions']}")
    if result.warnings:
        print(f"\n  警告: {result.warnings}")


def test_leg_both():
    """同时传入两个槽，一次 infer 出两个结果"""
    print("\n" + "=" * 70)
    print("  腿部运动分析 — 双任务（一次调用）")
    print("=" * 70)

    module = LegMotionModule()

    if not TOE_BAG.exists() or not LEG_BAG.exists():
        print("  ✗ 文件不存在，跳过")
        return

    toe_a = InputArtifact(
        id="test-toe2", module_id="leg-motion",
        input_slot="toe_tapping_video", kind="realsense_bag",
        path=TOE_BAG, metadata={},
    )
    leg_a = InputArtifact(
        id="test-leg2", module_id="leg-motion",
        input_slot="leg_agility_video", kind="realsense_bag",
        path=LEG_BAG, metadata={},
    )
    request = InferenceRequest(
        assessment_id="test",
        patient_id="test",
        module_id="leg-motion",
        inputs={
            "toe_tapping_video": (toe_a,),
            "leg_agility_video": (leg_a,),
        },
        parameters={},
    )

    print(f"  脚趾拍地: {TOE_BAG}")
    print(f"  抬腿:     {LEG_BAG}")
    print("  推理中...")

    def progress(pct, msg):
        print(f"    [{pct:.0%}] {msg}")

    result = module.infer(request, progress=progress)

    print(f"\n  质量: {result.quality}")
    print(f"  摘要: {result.summary}")

    for task_id in ("toe_tapping", "leg_agility"):
        print(f"\n  --- {task_id} ---")
        for side in ("left", "right"):
            r = result.result_data["tasks"][task_id][side]
            print(f"    {side:5s}: {r['status']:12s} score={r.get('score', '-')}  count={r['detected_actions']}")

    if result.warnings:
        print(f"\n  警告: {result.warnings}")


if __name__ == "__main__":
    # 检查依赖
    try:
        import pyrealsense2  # noqa
        import mediapipe    # noqa
        import cv2          # noqa
        import numpy        # noqa
    except ImportError as e:
        print(f"缺少依赖: {e}")
        print("请运行: pip install numpy opencv-python mediapipe pyrealsense2")
        exit(1)

    # test_hand()
    # test_leg_both()

    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--hand", action="store_true", help="只测手部")
    parser.add_argument("--leg", action="store_true", help="只测腿部（双任务）")
    args = parser.parse_args()

    if not args.hand and not args.leg:
        # 默认全测
        args.hand = True
        args.leg = True

    if args.hand:
        test_hand()

    if args.leg:
        test_leg_both()
