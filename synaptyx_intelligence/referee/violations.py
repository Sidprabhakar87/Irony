"""Violation types and data structures for the referee system."""

import time
import uuid
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class ViolationType(str, Enum):
    INPUT_DELAY = "input_delay"
    MACRO_DETECTED = "macro_detected"
    EXPLOIT_USED = "exploit_used"
    ILLEGAL_POSITION = "illegal_position"


class Severity(str, Enum):
    INFO = "info"
    WARNING = "warning"
    CRITICAL = "critical"


@dataclass
class Violation:
    """A detected violation event."""

    event_id: str = field(default_factory=lambda: str(uuid.uuid4()))
    match_id: str = ""
    player_id: str = ""
    timestamp: float = field(default_factory=time.time)
    violation_type: ViolationType = ViolationType.INPUT_DELAY
    severity: Severity = Severity.WARNING
    frame_number: int = 0
    evidence: dict[str, Any] = field(default_factory=dict)
    description: str = ""
    recommendation: str = ""

    def to_api_dict(self) -> dict[str, Any]:
        """Convert to JSON-serializable dict for API submission."""
        return {
            "event_id": self.event_id,
            "match_id": self.match_id,
            "player_id": self.player_id,
            "timestamp": self.timestamp,
            "violation": {
                "type": self.violation_type.value,
                "severity": self.severity.value,
                "frame_number": self.frame_number,
                "evidence": self.evidence,
                "description": self.description,
            },
            "recommendation": self.recommendation,
        }
