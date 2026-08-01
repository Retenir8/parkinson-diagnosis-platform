"""手部/腿部 MDS-UPDRS 评分指标计算测试（停顿/速度/幅度）。"""

from __future__ import annotations

from collections import deque

import pytest

from app.modules.providers.hand_motion import (
    _analyze_amplitude,
    _analyze_pauses,
    _analyze_speed,
    _compute_pause_intervals,
    _compute_pauses,
    _mds_updrs_score,
)
from app.modules.providers.leg_motion import (
    _analyze_amplitude as leg_analyze_amplitude,
    _analyze_speed as leg_analyze_speed,
    _mds_updrs_score as leg_mds_updrs_score,
)

DUIZHI_TH = [0.9, 0.8, 0.6, 0.4]


class TestPauseComputation:
    def test_pause_detected_from_static_signal(self):
        # 30fps：前 5s 静止（停顿），后 5s 摆动；阈值 1.5s
        t = [i / 30.0 for i in range(300)]
        sig = [0.2] * 150 + [0.2 + 0.5 * (i % 2) for i in range(150)]
        pauses = _compute_pauses(sig, t, pause_threshold=1.5)
        assert len(pauses) == 1
        assert pauses[0] >= 4.5  # 约 5 秒停顿

    def test_pause_intervals_from_action_times(self):
        # 动作时间戳：间隔 1s（<1.5s 不算停顿）与 2s（>1.5s 算停顿）
        times = [1.0, 2.0, 4.0]
        pauses = _compute_pause_intervals(times, pause_threshold=1.5)
        assert pauses == [2.0]

    def test_invalid_signal_gap_breaks_pause(self):
        # 中间有一段无效信号（时间空洞）不应被误判为停顿
        t = [0.0, 0.033, 0.066] + [2.0, 2.033, 2.066]  # 空洞 ~2s
        sig = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
        pauses = _compute_pauses(sig, t, pause_threshold=0.8)
        assert pauses == []  # 空洞被跳过，不是静止

    def test_freeze_counts_in_score(self):
        # 3-5 次停顿但含 1 次冻结（>=3.0s）→ 停顿子分 3 级
        pauses = [1.6, 3.5, 1.7]  # 3 次停顿，其中 1 次 >= 3.0s 冻结
        pa = _analyze_pauses(pauses, freeze_threshold=3.0)
        assert pa["total_pauses"] == 3
        assert pa["long_freezes"] == 1
        score, _ = _mds_updrs_score(pa, {"slow_level": 0, "speed_ratio": 1.0}, {"amplitude_decrease": 0})
        assert score == 1  # ceil((3+0+0)/3) = 1

        # 无冻结时同样 3 次停顿 → 2 级子分 → 最终 1
        pa2 = _analyze_pauses([1.6, 1.7, 1.8], freeze_threshold=3.0)
        assert pa2["long_freezes"] == 0
        score2, _ = _mds_updrs_score(pa2, {"slow_level": 0, "speed_ratio": 1.0}, {"amplitude_decrease": 0})
        assert score2 == 1

        # 冻结 + 慢速 + 幅度衰减 → 明显高分
        score3, _ = _mds_updrs_score(
            pa, {"slow_level": 2, "speed_ratio": 0.5},
            {"amplitude_decrease": 2},
        )
        assert score3 == 3  # ceil((3+2+2)/3)


class TestSpeedAnalysis:
    def test_first_third_vs_last_third_average(self):
        # 前 3 次动作快（0.2s/次），后 3 次慢（0.4s/次）
        # 首 1/3 平均速度 = 5，末 1/3 平均 = 2.5，ratio = 0.5
        durations = [0.2, 0.2, 0.2, 0.25, 0.3, 0.4, 0.4, 0.4]
        result = _analyze_speed(durations, DUIZHI_TH)
        assert result["slow_level"] == 3  # 0.5 < 0.6 → 3 级
        assert abs(result["speed_ratio"] - 0.5) < 1e-9

    def test_single_point_noise_no_longer_dominant(self):
        # 首末单点都正常，但中段有异常 → 分组平均后不应误判
        durations = [0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2, 0.2]
        result = _analyze_speed(durations, DUIZHI_TH)
        assert result["speed_ratio"] == 1.0
        assert result["slow_level"] == 0

    def test_zero_duration_guarded(self):
        durations = [0.2, 0.0, 0.2, 0.2, 0.2]
        result = _analyze_speed(durations, DUIZHI_TH)
        assert result["slow_level"] >= 0

    def test_leg_speed_uses_thirds(self):
        records = [
            {"time": 0.2 * i} for i in range(1, 10)
        ]
        result = leg_analyze_speed(records)
        assert abs(result["speed_ratio"] - 1.0) < 1e-9


class TestAmplitudeAnalysis:
    def test_mild_end_decrease(self):
        # 幅度从 1.0 缓慢降到 0.85（末期轻度衰减）→ 1 级
        amps = [1.0, 1.0, 1.0, 0.95, 0.95, 0.9, 0.88, 0.86, 0.85]
        assert _analyze_amplitude(amps)["amplitude_decrease"] == 1

    def test_severe_from_start(self):
        # 第一下正常（1.0），之后立刻崩到 0.3 左右 → 3 级
        amps = [1.0, 0.35, 0.3, 0.28, 0.25, 0.22]
        assert _analyze_amplitude(amps)["amplitude_decrease"] == 3

    def test_moderate_halfway(self):
        # 前半正常，后半明显衰减 → 2 级
        amps = [1.0, 1.0, 1.0, 0.95, 0.9, 0.6, 0.58, 0.55, 0.5]
        assert _analyze_amplitude(amps)["amplitude_decrease"] == 2

    def test_normal_amplitudes(self):
        amps = [1.0, 1.05, 0.98, 1.0, 1.02, 0.99, 1.01, 1.0, 0.99, 1.0]
        assert _analyze_amplitude(amps)["amplitude_decrease"] == 0

    def test_leg_amplitude_same_logic(self):
        amps = [1.0, 1.0, 1.0, 0.95, 0.9, 0.6, 0.58, 0.55, 0.5]
        assert leg_analyze_amplitude(amps)["amplitude_decrease"] == 2

    def test_first_action_slightly_larger_not_polluting_base(self):
        # 首个动作略大（1.3），后续稳定在 92% 以上 → 不应误报衰减
        amps = [1.3, 1.25, 1.2, 1.22, 1.2, 1.18, 1.2, 1.19, 1.2, 1.18]
        assert _analyze_amplitude(amps)["amplitude_decrease"] == 0


class _LM:
    def __init__(self, x, y):
        self.x, self.y = x, y


class _Hand:
    """模拟 MediaPipe 手部对象（.landmark 为 21 点列表）。"""

    def __init__(self, lms):
        self.landmark = lms


def _make_hand(dx_px: float):
    """构造手部 landmark：拇指/小指 x 差为 dx_px。"""
    lms = [_LM(0.5, 0.6) for _ in range(21)]
    lms[0] = _LM(0.5, 0.8)                     # wrist
    lms[2] = _LM(0.5 - dx_px / 2, 0.6)         # thumb mcp
    lms[9] = _LM(0.5, 0.5)                     # middle mcp
    lms[17] = _LM(0.5 + dx_px / 2, 0.6)        # pinky mcp
    return _Hand(lms)


class TestAlternationDebounce:
    """轮替方向持续确认：静止手抖动不计数，真实翻转计数。"""

    def _run_frames(self, dx_sequence):
        from app.modules.providers.hand_motion import HandMotionModule

        module = HandMotionModule()
        st = {
            "alt": {
                "prev_sign": 0, "count": 0, "last_action_time": 0.0,
                "records": [], "cur_sign": 0, "same_dir_time": 0.0,
                "last_frame_time": None,
            },
            "amp_alt": [],
        }
        now = 0.0
        for dx in dx_sequence:
            module._update_alternation(st, _make_hand(dx), now)
            now += 1.0 / 30.0
        return st["alt"]["count"]

    def test_static_hand_jitter_no_count(self):
        # 静止手抖动：信号每帧在 ±8.7 之间穿越阈值，方向保持不足 0.12s
        dx_sequence = [0.026, -0.026] * 60  # 4 秒抖动
        assert self._run_frames(dx_sequence) == 0

    def test_real_alternation_counts(self):
        # 真实翻转：+ 方向持续 10 帧（0.33s）后翻转到 - 方向
        dx_sequence = [0.05] * 10 + [-0.05] * 10
        assert self._run_frames(dx_sequence) == 1

    def test_slow_real_alternation_counts(self):
        # 慢速翻转同样计数
        dx_sequence = [0.05] * 20 + [-0.05] * 20
        assert self._run_frames(dx_sequence) == 1
