"""Referee Engine - Rule-based violation detection consuming frame data.

This module implements the real-time referee logic. Currently uses hardcoded
heuristics. Future versions will integrate ML models for anomaly detection.
See ROADMAP.md for ML integration plans.
"""

import time
from collections import deque
from dataclasses import dataclass, field

import structlog

from synaptyx_intelligence.config.settings import Settings
from synaptyx_intelligence.ipc.protocol import FrameData, InputState, MovePhase
from synaptyx_intelligence.referee.violations import Severity, Violation, ViolationType

logger = structlog.get_logger()



# Strictness thresholds
THRESHOLDS = {
    "lenient": {"rapid_input_count": 5, "macro_similarity": 0.9, "position_bound": 150.0},
    "normal": {"rapid_input_count": 3, "macro_similarity": 0.8, "position_bound": 100.0},
    "strict": {"rapid_input_count": 2, "macro_similarity": 0.7, "position_bound": 80.0},
}


@dataclass
class PlayerState:
    """Tracks per-player state for violation detection."""

    previous_input: InputState | None = None
    frames_since_last_input_change: int = 0
    rapid_change_count: int = 0
    animation_history: deque = field(default_factory=lambda: deque(maxlen=20))
    last_recorded_animation: int | None = None



class RefereeEngine:
    """Real-time violation detection engine.

    Processes frames as they arrive from the IPC bridge and detects:
    - Input delay anomalies (impossible input speeds)
    - Macro usage (repetitive input patterns)
    - Illegal positions (out-of-bounds players)

    Future (ML): Anomaly detection via autoencoder on input distributions.
    """

    def __init__(self, settings: Settings):
        self.settings = settings
        self.match_id = settings.referee_match_id
        self.strictness = settings.referee_strictness
        self.thresholds = THRESHOLDS.get(self.strictness, THRESHOLDS["normal"])
        self.player_states: dict[str, PlayerState] = {
            "player_1": PlayerState(),
            "player_2": PlayerState(),
        }
        self.violations: list[Violation] = []
        self.frames_processed: int = 0

    def process_frame(self, frame: FrameData) -> list[Violation]:
        """Process one frame and return any new violations detected."""
        new_violations: list[Violation] = []
        self.frames_processed += 1

        # Check each player
        for player_id, player_data in [
            ("player_1", frame.player_1),
            ("player_2", frame.player_2),
        ]:
            state = self.player_states[player_id]

            # Input delay check
            v = self._check_input_delay(player_id, player_data.input, state, frame)
            if v:
                new_violations.append(v)

            # Macro check
            v = self._check_macro(player_id, player_data.animation_id, state, frame)
            if v:
                new_violations.append(v)

            # Position check
            v = self._check_position(player_id, player_data.position, frame)
            if v:
                new_violations.append(v)

        self.violations.extend(new_violations)
        return new_violations


    def _check_input_delay(
        self, player_id: str, current_input: InputState | None,
        state: PlayerState, frame: FrameData,
    ) -> Violation | None:
        """Detect impossible input speeds (multiple changes in same frame)."""
        if current_input is None:
            return None

        if state.previous_input is not None:
            changed = self._input_changed(state.previous_input, current_input)
            if changed:
                state.rapid_change_count += 1
                if (
                    state.frames_since_last_input_change == 0
                    and state.rapid_change_count >= self.thresholds["rapid_input_count"]
                ):
                    state.rapid_change_count = 0
                    return Violation(
                        match_id=self.match_id,
                        player_id=player_id,
                        violation_type=ViolationType.INPUT_DELAY,
                        severity=Severity.WARNING,
                        frame_number=frame.frames_since_round_start,
                        evidence={
                            "input_interval": 0,
                            "rapid_change_count": state.rapid_change_count,
                            "threshold": self.thresholds["rapid_input_count"],
                        },
                        description="Multiple distinct inputs in same frame",
                        recommendation="Monitor for continued suspicious inputs",
                    )
                state.frames_since_last_input_change = 0
            else:
                state.frames_since_last_input_change += 1
                if state.frames_since_last_input_change > 3:
                    state.rapid_change_count = 0

        state.previous_input = current_input
        return None

    def _check_macro(
        self, player_id: str, animation_id: int | None,
        state: PlayerState, frame: FrameData,
    ) -> Violation | None:
        """Detect repetitive animation sequences (macro usage)."""
        if animation_id is None:
            return None
        if animation_id == state.last_recorded_animation:
            return None

        state.last_recorded_animation = animation_id
        state.animation_history.append(animation_id)

        if len(state.animation_history) >= 20:
            seq1 = list(state.animation_history)[:10]
            seq2 = list(state.animation_history)[10:]
            similarity = sum(a == b for a, b in zip(seq1, seq2)) / 10.0

            if similarity >= self.thresholds["macro_similarity"]:
                state.animation_history.clear()
                return Violation(
                    match_id=self.match_id,
                    player_id=player_id,
                    violation_type=ViolationType.MACRO_DETECTED,
                    severity=Severity.WARNING,
                    frame_number=frame.frames_since_round_start,
                    evidence={
                        "similarity": similarity,
                        "pattern_length": 10,
                        "threshold": self.thresholds["macro_similarity"],
                    },
                    description="Repetitive input pattern detected",
                    recommendation="Review player input history",
                )
        return None


    def _check_position(
        self, player_id: str, position, frame: FrameData,
    ) -> Violation | None:
        """Detect impossible player positions (teleportation exploits)."""
        if position is None:
            return None

        bound = self.thresholds["position_bound"]
        if (
            abs(position.x) > bound
            or abs(position.y) > bound
            or position.z < -30.0
            or position.z > 50.0
        ):
            return Violation(
                match_id=self.match_id,
                player_id=player_id,
                violation_type=ViolationType.ILLEGAL_POSITION,
                severity=Severity.CRITICAL,
                frame_number=frame.frames_since_round_start,
                evidence={
                    "x": position.x,
                    "y": position.y,
                    "z": position.z,
                    "bound": bound,
                },
                description="Player position outside valid game bounds",
                recommendation="Investigate for teleportation exploit",
            )
        return None

    @staticmethod
    def _input_changed(prev: InputState, curr: InputState) -> bool:
        """Check if any input button changed state."""
        return (
            prev.forward != curr.forward
            or prev.back != curr.back
            or prev.up != curr.up
            or prev.down != curr.down
            or prev.left != curr.left
            or prev.right != curr.right
            or prev.button_1 != curr.button_1
            or prev.button_2 != curr.button_2
            or prev.button_3 != curr.button_3
            or prev.button_4 != curr.button_4
        )

    def clear_violations(self) -> None:
        """Clear all recorded violations and reset state."""
        self.violations.clear()
        self.player_states = {
            "player_1": PlayerState(),
            "player_2": PlayerState(),
        }
        self.frames_processed = 0

    def get_violation_count(self) -> int:
        return len(self.violations)

    def get_report(self) -> dict:
        """Generate the referee report for API submission."""
        return {
            "match_id": self.match_id,
            "frames_processed": self.frames_processed,
            "violation_count": len(self.violations),
            "violations": [v.to_api_dict() for v in self.violations],
        }
