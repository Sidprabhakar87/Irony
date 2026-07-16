"""Coach Report - Structured output for coaching analysis results."""

import time
from dataclasses import dataclass, field
from typing import Any

from synaptyx_intelligence.coach.analyzer import MatchAnalysis


@dataclass
class CoachReport:
    """Structured coaching report for API submission."""

    match_id: str = ""
    player_id: str = ""
    opponent_id: str = ""
    generated_at: float = field(default_factory=time.time)
    analysis: MatchAnalysis = field(default_factory=MatchAnalysis)

    def to_api_dict(self) -> dict[str, Any]:
        """Convert to JSON-serializable dict for API submission."""
        return {
            "match_id": self.match_id,
            "player_id": self.player_id,
            "opponent_id": self.opponent_id,
            "generated_at": self.generated_at,
            "summary": {
                "rounds_won": self.analysis.player_rounds_won,
                "rounds_lost": self.analysis.opponent_rounds_won,
                "total_damage_dealt": self.analysis.player_damage_dealt,
                "total_damage_taken": self.analysis.player_damage_taken,
                "total_frames": self.analysis.total_frames,
            },
            "missed_punishments": [
                {
                    "frame": p.frame_number,
                    "recovery_frames": p.recovery_frames,
                    "impact": p.impact,
                    "optimal_punish": p.optimal_punish,
                }
                for p in self.analysis.missed_punishments
            ],
            "opponent_tendencies": {
                "playstyle": self.analysis.opponent_profile.playstyle.value,
                "favorite_moves": self.analysis.opponent_profile.favorite_moves[:5],
                "heat_activations": self.analysis.opponent_profile.heat_activations,
                "rage_activations": self.analysis.opponent_profile.rage_activations,
            },
            "strategy_recommendations": self.analysis.strategy_recommendations,
        }
