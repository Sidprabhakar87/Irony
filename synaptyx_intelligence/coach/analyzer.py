"""Coach Analyzer - Post-match analysis engine.

Processes recorded frames to identify missed punish opportunities,
profile opponent tendencies, and generate strategy recommendations.

Future (ML): Replace heuristics with trained models. See ROADMAP.md.
"""

from collections import Counter
from dataclasses import dataclass, field
from enum import Enum

import structlog

from synaptyx_intelligence.ipc.protocol import (
    AttackType, FrameData, MovePhase, PlayerData,
)

logger = structlog.get_logger()


class Playstyle(str, Enum):
    AGGRESSIVE = "aggressive"
    DEFENSIVE = "defensive"
    POKE_HEAVY = "poke_heavy"
    NEUTRAL = "neutral"



@dataclass
class PunishOpportunity:
    frame_number: int = 0
    recovery_frames: int = 0
    impact: str = "medium"
    player_used_move: int | None = None
    optimal_punish: int | None = None


@dataclass
class OpponentProfile:
    playstyle: Playstyle = Playstyle.NEUTRAL
    favorite_moves: list[int] = field(default_factory=list)
    move_frequencies: Counter = field(default_factory=Counter)
    punish_attempts: int = 0
    blocks: int = 0
    heat_activations: int = 0
    rage_activations: int = 0
    total_frames: int = 0


@dataclass
class MatchAnalysis:
    total_frames: int = 0
    player_rounds_won: int = 0
    opponent_rounds_won: int = 0
    player_damage_dealt: int = 0
    player_damage_taken: int = 0
    missed_punishments: list[PunishOpportunity] = field(default_factory=list)
    opponent_profile: OpponentProfile = field(default_factory=OpponentProfile)
    strategy_recommendations: list[dict] = field(default_factory=list)



class CoachAnalyzer:
    """Post-match analysis engine.

    Analyzes a sequence of recorded frames to produce coaching insights.
    Currently uses rule-based heuristics. Future: ML-based pattern recognition.
    """

    def __init__(self, player_id: str = "player_1"):
        self.player_id = player_id

    def analyze(self, frames: list[FrameData]) -> MatchAnalysis:
        """Run full analysis on a recorded match."""
        if not frames:
            return MatchAnalysis()

        analysis = MatchAnalysis(total_frames=len(frames))
        opponent_profile = OpponentProfile(total_frames=len(frames))

        for frame in frames:
            player = frame.player_1 if self.player_id == "player_1" else frame.player_2
            opponent = frame.player_2 if self.player_id == "player_1" else frame.player_1

            # Track rounds
            if player.rounds_won is not None:
                analysis.player_rounds_won = player.rounds_won
            if opponent.rounds_won is not None:
                analysis.opponent_rounds_won = opponent.rounds_won

            # Track damage
            if player.combo_damage and player.combo_damage > analysis.player_damage_dealt:
                analysis.player_damage_dealt = player.combo_damage
            if opponent.combo_damage and opponent.combo_damage > analysis.player_damage_taken:
                analysis.player_damage_taken = opponent.combo_damage

            # Missed punish detection
            punish = self._check_missed_punish(frame, player, opponent)
            if punish:
                analysis.missed_punishments.append(punish)

            # Profile opponent
            self._profile_opponent(opponent, player, opponent_profile)

        # Determine playstyle
        opponent_profile.playstyle = self._determine_playstyle(opponent_profile)
        opponent_profile.favorite_moves = [
            move for move, _ in opponent_profile.move_frequencies.most_common(5)
        ]
        analysis.opponent_profile = opponent_profile

        # Generate recommendations
        analysis.strategy_recommendations = self._generate_strategies(opponent_profile)

        logger.info(
            "coach_analysis_complete",
            frames=len(frames),
            missed_punishes=len(analysis.missed_punishments),
            playstyle=opponent_profile.playstyle.value,
        )
        return analysis


    def _check_missed_punish(
        self, frame: FrameData, player: PlayerData, opponent: PlayerData,
    ) -> PunishOpportunity | None:
        """Detect if player missed a punish opportunity."""
        if opponent.move_phase != MovePhase.RECOVERY:
            return None
        if player.move_phase is not None and player.move_phase != MovePhase.NEUTRAL:
            return None
        if player.attack_type is not None and player.attack_type != AttackType.NOT_ATTACK:
            return None

        # Estimate recovery frames
        recovery = self._estimate_recovery(opponent)
        if recovery is None or recovery < 10:
            return None

        impact = "low" if recovery < 14 else "high" if recovery >= 16 else "medium"
        optimal = self._find_optimal_punish(recovery)

        return PunishOpportunity(
            frame_number=frame.frames_since_round_start,
            recovery_frames=recovery,
            impact=impact,
            player_used_move=player.animation_id,
            optimal_punish=optimal,
        )

    def _estimate_recovery(self, player: PlayerData) -> int | None:
        """Estimate recovery frames from available data."""
        if player.animation_total_frames is None or player.animation_frame is None:
            return None
        remaining = player.animation_total_frames - player.animation_frame
        return max(0, remaining)

    @staticmethod
    def _find_optimal_punish(recovery_frames: int) -> int | None:
        """Find fastest available punish for given recovery window."""
        if recovery_frames < 10:
            return None
        elif recovery_frames <= 11:
            return 10  # i10 jab
        elif recovery_frames <= 13:
            return 12  # i12 punish
        elif recovery_frames <= 15:
            return 14  # i14 punish
        else:
            return 15  # i15 launcher

    def _profile_opponent(
        self, opponent: PlayerData, player: PlayerData, profile: OpponentProfile,
    ) -> None:
        """Build opponent behavior profile from frame data."""
        if opponent.animation_id is not None:
            profile.move_frequencies[opponent.animation_id] += 1

        if opponent.move_phase == MovePhase.RECOVERY:
            if (
                opponent.attack_type is not None
                and opponent.attack_type != AttackType.NOT_ATTACK
            ):
                profile.punish_attempts += 1

        if opponent.blocking is not None and opponent.blocking != 0:
            profile.blocks += 1

        if opponent.heat_state is not None and opponent.heat_state == 1:
            profile.heat_activations += 1

        if opponent.rage_state is not None and opponent.rage_state == 1:
            profile.rage_activations += 1

    @staticmethod
    def _determine_playstyle(profile: OpponentProfile) -> Playstyle:
        """Classify opponent playstyle from aggregate stats."""
        if profile.total_frames == 0:
            return Playstyle.NEUTRAL

        total_moves = sum(profile.move_frequencies.values())
        if total_moves == 0:
            return Playstyle.NEUTRAL

        offensive_ratio = profile.punish_attempts / total_moves
        block_ratio = profile.blocks / profile.total_frames

        if offensive_ratio > 0.3:
            return Playstyle.AGGRESSIVE
        elif block_ratio > 0.4:
            return Playstyle.DEFENSIVE
        # Future: use ML clustering for more nuanced classification
        return Playstyle.NEUTRAL


    @staticmethod
    def _generate_strategies(profile: OpponentProfile) -> list[dict]:
        """Generate counter-strategy recommendations based on opponent profile."""
        recs = []
        match profile.playstyle:
            case Playstyle.AGGRESSIVE:
                recs.append({
                    "situation": "Opponent plays aggressively with frequent attacks",
                    "counter": "Use backdash into whiff punish or power crush moves",
                    "risk": "medium",
                    "reason": "Aggressive players overcommit - punish their whiffs",
                })
            case Playstyle.DEFENSIVE:
                recs.append({
                    "situation": "Opponent blocks frequently and waits for punishes",
                    "counter": "Use throws and frame traps to open them up",
                    "risk": "low",
                    "reason": "Defensive players are vulnerable to throws and pressure",
                })
            case Playstyle.POKE_HEAVY:
                recs.append({
                    "situation": "Opponent relies on pokes and crush moves",
                    "counter": "Use mids to beat high crushes, block and punish lows",
                    "risk": "low",
                    "reason": "Poke-heavy players beaten with patient mid-checking",
                })
            case Playstyle.NEUTRAL:
                recs.append({
                    "situation": "Opponent plays balanced neutral game",
                    "counter": "Focus on fundamentals: spacing, whiff punish, advantage",
                    "risk": "medium",
                    "reason": "Balanced opponents require solid fundamentals",
                })
        return recs
