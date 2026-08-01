"""
端到端测试脚本
1. 创建患者 → 上传手部/腿部 bag → 创建评估 → 触发推理

使用方式：
    cd <project>/server
    python tests/test_e2e.py
"""

import os
from pathlib import Path

import requests

BASE = "http://127.0.0.1:8000/api/v1"

DATA_DIR = Path(
    os.getenv(
        "MEDVISION_DATA_DIR",
        Path(__file__).resolve().parents[2] / "data",
    )
).resolve()
SAMPLE_DIR = DATA_DIR / "samples"
HAND_BAG = SAMPLE_DIR / "hand" / "hand_motion.bag"
TOE_BAG = SAMPLE_DIR / "leg" / "toe_tapping.bag"
LEG_BAG = SAMPLE_DIR / "leg" / "leg_agility.bag"


def main():
    # ---- 1. 创建患者 ----
    print("[1/5] 创建患者...")
    p = requests.post(f"{BASE}/patients", json={
        "patient_code": "E2E-TEST",
        "name": "端到端测试患者",
        "gender": "male",
    })
    p.raise_for_status()
    pid = p.json()["id"]
    print(f"  患者ID: {pid}")

    # ---- 2. 上传手部 bag ----
    print("[2/5] 上传手部视频...")
    with HAND_BAG.open("rb") as f:
        hand_resp = requests.post(
            f"{BASE}/patients/{pid}/artifacts/upload",
            data={
                "kind": "realsense_bag",
                "module_id": "hand-motion",
                "input_slot": "hand_video",
            },
            files={"file": ("20260421_hand.bag", f, "application/octet-stream")},
        )
    hand_resp.raise_for_status()
    hand_aid = hand_resp.json()["id"]
    print(f"  手部资料ID: {hand_aid}")

    # ---- 3. 上传腿部 bag（脚趾拍地） ----
    print("[3/5] 上传腿部视频（脚趾拍地）...")
    with TOE_BAG.open("rb") as f:
        toe_resp = requests.post(
            f"{BASE}/patients/{pid}/artifacts/upload",
            data={
                "kind": "realsense_bag",
                "module_id": "leg-motion",
                "input_slot": "toe_tapping_video",
            },
            files={"file": ("20260603_toe.bag", f, "application/octet-stream")},
        )
    toe_resp.raise_for_status()
    toe_aid = toe_resp.json()["id"]
    print(f"  脚趾拍地资料ID: {toe_aid}")

    # ---- 4. 上传腿部 bag（抬腿） ----
    print("[3/5] 上传腿部视频（抬腿）...")
    with LEG_BAG.open("rb") as f:
        leg_resp = requests.post(
            f"{BASE}/patients/{pid}/artifacts/upload",
            data={
                "kind": "realsense_bag",
                "module_id": "leg-motion",
                "input_slot": "leg_agility_video",
            },
            files={"file": ("20260603_leg.bag", f, "application/octet-stream")},
        )
    leg_resp.raise_for_status()
    leg_aid = leg_resp.json()["id"]
    print(f"  抬腿资料ID: {leg_aid}")

    # ---- 5. 创建评估 ----
    print("[4/5] 创建评估任务...")
    e = requests.post(f"{BASE}/assessments", json={
        "patient_id": pid,
        "module_inputs": {
            "hand-motion": {"hand_video": [hand_aid]},
            "leg-motion": {
                "toe_tapping_video": [toe_aid],
                "leg_agility_video": [leg_aid],
            },
        },
    })
    e.raise_for_status()
    assessment = e.json()
    aid = assessment["id"]
    print(f"  评估ID: {aid}")
    print(f"  状态: {assessment['status']}")
    print(f"  手部模块状态: {assessment['module_runs']['hand-motion']['status']}")
    print(f"  腿部模块状态: {assessment['module_runs']['leg-motion']['status']}")

    # ---- 6. 触发推理 ----
    print("[5/5] 触发推理（后台执行）...")
    run_resp = requests.post(f"{BASE}/assessments/{aid}/run")
    if run_resp.status_code == 200:
        updated = run_resp.json()
        print(f"  推理已启动，状态: {updated['status']}")
        for mid, run in updated['module_runs'].items():
            print(f"    {mid}: {run['status']}")
    else:
        print(f"  推理触发: {run_resp.status_code} - {run_resp.json().get('detail', '')}")

    # ---- 7. 输出汇总 ----
    print("\n" + "=" * 60)
    print("数据就绪。推理在后台运行，前端轮询 /assessments/{id} 查看结果。")
    print(f"  手部 bag: {HAND_BAG}")
    print(f"  脚趾 bag: {TOE_BAG}")
    print(f"  抬腿 bag: {LEG_BAG}")
    print("=" * 60)


if __name__ == "__main__":
    # 先确认服务是否在运行
    try:
        r = requests.get(f"{BASE}/health", timeout=2)
        print(f"✓ 服务运行中: {r.json()['status']}")
    except Exception:
        print("✗ 请先启动服务: cd server && python -m uvicorn app.main:app --port 8000")
        exit(1)

    main()
