# 1. OBJECTIVE

Build **Synaptyx Referee** — an AI-powered referee and coaching system for Tekken 8 competitive esports that integrates with a SaaS tournament platform (already built separately).

- **Synaptyx Referee**: Real-time match monitoring for tournament integrity (violations, fair play) - can run server-side or as a side process
- **Synaptyx Coach**: Post-match analysis only (NO in-game overlay during play) - analyzes replays to explain optimal strategies, suggest counter-strategies, and profile opponent playstyle

# 2. CONTEXT SUMMARY

## Architecture Overview
```
┌─────────────────────────────────────────────────────────────────┐
│                    SaaS Tournament Platform                      │
│              (already built - not our concern)                  │
└────────────────────────┬────────────────────────────────────────┘
                         │
         ┌───────────────┴───────────────┐
         │                               │
         ▼                               ▼
┌─────────────────────┐       ┌─────────────────────┐
│  Synaptyx Referee   │       │  Synaptyx Coach     │
│  (Live Monitoring)  │       │  (Post-Match)       │
├─────────────────────┤       ├─────────────────────┤
│ • Violation detect  │       │ • Replay analysis   │
│ • Input validation  │       │ • Strategy suggest  │
│ • Event logging     │       │ • Opponent profiling│
│ • Server-side       │       │ • Frame-by-frame    │
└─────────────────────┘       │   review            │
                              └─────────────────────┘
```

## Tekken 8 Telemetry Access
The underlying Irony frame analysis engine reads Tekken 8 memory through:
- **Memory Reading** (`src/dll/game/memory.zig`): Pattern-based memory scanning
- **Frame Capture** (`src/dll/game/capturer.zig`): Per-frame extraction
  - Player positions, rotations, animations
  - Hit lines, hurt cylinders, collision spheres
  - Health, rage, heat gauges
  - Match state (round, phase, frames since start)
- **Move Detection** (`src/dll/core/move_detector.zig`): Tracks startup/active/recovery phases
- **Move Measurement** (`src/dll/core/move_measurer.zig`): Calculates attack/recovery ranges

## Available Frame Data
Each captured `model.Frame` contains:
- **Player State**: animation_id, animation_frame, move_phase, attack_type, hit_outcome
- **Frame Metrics**: startup_frames, active_frames, recovery_frames, total_frames, frame_advantage
- **Position Data**: hit_lines (4 for T8), hurt_cylinders (14 points), collision_spheres
- **Match State**: match_phase, frames_since_round_start, frames_left_in_round, rounds_won
- **Player Info**: character_id, health, rage, heat (T8), input state, can_interact

## Architecture
- Built with Zig targeting Windows (DX12)
- Event-driven: tick() called every frame, draw() for rendering
- Core modules: Capturer → HitDetector → MoveDetector → MoveMeasurer → Referee/Coach

# 3. APPROACH OVERVIEW

## Design Decisions

1. **Modular Architecture**: Separate Coach and Referee as standalone modules
2. **SaaS Integration**: API-compatible output (JSON/REST) for tournament platform integration
3. **Server-Ready Referee**: Referee runs independently, outputs machine-readable logs
4. **Coach is Post-Match Only**: No in-game overlay, generates coaching reports from replay data
5. **Frame Data Foundation**: Leverages existing Irony capture system for all telemetry

## Integration with SaaS Platform

```
┌──────────────────┐      ┌───────────────────┐      ┌─────────────────┐
│  Player PC       │      │  Synaptyx         │      │  Tournament     │
│  + Tekken 8      │─────▶│  Referee/Coach    │─────▶│  SaaS Platform  │
│  + Irony Engine  │      │  (Windows DLL)    │      │  (API endpoint) │
└──────────────────┘      │                   │      │                 │
                          │  • Live capture   │      │  • Violations   │
                          │  • Post-match     │      │  • Coaching     │
                          │    analysis       │      │    reports      │
                          └───────────────────┘      └─────────────────┘
```

## Core Components

### Synaptyx Referee (Real-time, Server-Side)
- **Match Observer**: Tracks rule compliance frame-by-frame during live matches
- **Violation Detector**: Monitors for input delays, macro usage, exploits
- **Event Logger**: Records all significant events in machine-readable format (JSON)
- **API Output**: Sends violation alerts to tournament platform via HTTP/REST

### Synaptyx Coach (Post-Match Only)
- **Replay Analyzer**: Processes recorded match frames for deep analysis
- **Optimal Play Finder**: Identifies "winning move sequences" that were missed
- **Opponent Profiler**: Builds style model from opponent's actual gameplay data
- **Character Matchup Advisor**: Generates counter-strategy guides based on frame data
- **Coaching Report Generator**: Creates detailed coaching output (JSON/text) for platform

# 4. IMPLEMENTATION STEPS

## Step 1: Coach Core Module (Post-Match Analysis)
**File**: `src/dll/core/coach.zig`
- `Coach` struct - stateless analyzer that processes recorded frames
- `PlayerTendency` struct - models opponent's gameplay style (habitual moves, patterns)
- `MatchAnalysis` struct - holds complete analysis results
- `analyzeReplay()` - processes a full match recording, returns coaching insights
- `identifyOptimalPunishments()` - finds missed punish opportunities
- `profileOpponentStyle()` - builds opponent tendency model from their moves
- `generateStrategyGuide()` - suggests counter-strategies based on frame data
- `FrameIterator` - correctly iterates frames respecting player_id

**Output**: Coaching report in JSON format (not in-game display)

---

## Step 2: Referee Core Module (Live Monitoring)
**File**: `src/dll/core/referee.zig`
- `Referee` struct with per-match violation tracking
- `ViolationType` enum: input_delay, macro_detected, exploit_used, illegal_position
- `ViolationEvent` struct with: frame_number, violation_type, evidence, severity
- `checkInputDelay()` - detects multiple rapid input changes within impossible timeframes
- `checkMacroUsage()` - pattern-matching for macro signatures (repetitive sequences)
- `checkIllegalPositions()` - detects impossible player positions
- `logViolation()` - records events with full frame context
- `exportReport()` - outputs machine-readable JSON for tournament platform
- Uses `model.RefereeSettings` for configuration (single source of truth)

**Output**: Real-time violation logs in JSON format via API

---

## Step 3: API Client for SaaS Integration
**File**: `src/dll/api/client.zig`
- `ApiClient` struct using Win32 WinHTTP for HTTP/HTTPS communication
- `sendViolationAlert()` - POST violation events to tournament platform
- `submitCoachingReport()` - POST completed coaching analysis
- `heartbeat()` - maintain connection during matches
- `authenticate()` - handle API authentication (Bearer token)
- Request queuing with automatic retry (up to 3 attempts)
- URL parsing, proper HTTPS support

---

## Step 4: Coach Report Generator
**File**: `src/dll/core/coach_report.zig`
- `CoachReport` struct containing all analysis output
- `MatchSummary` - round-by-round breakdown with frame advantage
- `TendencyReport` - opponent style profiling
- `fromAnalysis()` - builds report from match analysis results
- `exportToJson()` - serialize report for API transmission
- `exportToText()` - human-readable coaching summary

---

## Step 5: Match Statistics Analyzer
**File**: `src/dll/core/match_stats.zig`
- `MatchStats` struct - aggregate statistics from match frames
- `calculateFrameAdvantage()` - per-round frame advantage trends
- `countMoves()` - frequency analysis of used moves
- `damageAnalysis()` - damage dealt, taken, conversions
- `heatRageAnalysis()` - T8-specific heat/rage usage patterns
- `MoveFrequencies` - tracks and ranks most-used moves

---

## Step 6: Integration into Core Tick Loop
**File**: `src/dll/core/core.zig`
- Referee wired into `Core.tick()` for real-time monitoring
- Coach auto-triggers via `detectMatchCompletion()` (match_phase transitions)
- `runCoachAnalysis()` callable externally via API
- `exportRefereeReport()` / `getLatestCoachReport()` for data access

---

## Step 7: Settings Configuration
**File**: `src/dll/model/settings.zig`
- `RefereeSettings`: enabled, strictness, api_endpoint, api_key, match_id, thresholds
- `CoachSettings`: enabled, api_endpoint, api_key, analysis_depth
- Loaded from `settings.json` alongside existing Irony settings

# 5. TESTING AND VALIDATION

## Success Criteria

### Synaptyx Referee
- **Violation Detection**: Accurately flags suspicious inputs (multiple rapid changes in same frame)
- **Macro Detection**: Identifies repetitive animation sequences (80%+ similarity)
- **Event Logging**: Captures all violations with timestamps and evidence
- **API Integration**: Successfully sends data to tournament platform via WinHTTP
- **False Positive Rate**: <5% in normal gameplay conditions (configurable via strictness)

### Synaptyx Coach
- **Replay Analysis**: Successfully processes recorded match frames
- **Optimal Play Detection**: Identifies punish windows of 10+ recovery frames
- **Opponent Profiling**: Correctly categorizes opponent playstyle
- **Strategy Generation**: Produces actionable counter-strategy recommendations
- **Report Output**: Generates valid JSON report suitable for API transmission

### Integration with SaaS Platform
- **API Communication**: WinHTTP calls work reliably over HTTPS
- **JSON Output**: All reports are valid, parseable JSON
- **Performance**: <1ms overhead per frame (no impact on gameplay)
- **Reliability**: Handles network failures gracefully (queue and retry)

## Example Synaptyx Referee Violation Event

```json
{
  "event_id": "a1b2c3d4-0000-0000-0000-000000000001",
  "match_id": "tournament-match-456",
  "player_id": "player_1",
  "timestamp": 1720000000,
  "violation": {
    "type": "input_delay",
    "severity": "warning",
    "frame_number": 2341,
    "description": "Multiple distinct inputs detected within same frame"
  },
  "recommendation": "Monitor player for continued suspicious inputs"
}
```

## Example Synaptyx Coach Report

```json
{
  "match_id": "tournament-match-456",
  "player_id": "player_1",
  "opponent_id": "player_2",
  "summary": {
    "rounds_won": 2,
    "rounds_lost": 3,
    "total_damage_dealt": 1847,
    "total_damage_taken": 2103,
    "total_frames": 5400
  },
  "missed_punishments": [
    {
      "frame": 145,
      "opponent_recovery_frames": 15,
      "impact": "high"
    }
  ],
  "opponent_tendencies": {
    "playstyle": "aggressive",
    "favorite_moves": [142, 87, 203, 55, 12],
    "heat_activations": 3,
    "rage_activations": 1
  },
  "strategy_recommendations": [
    {
      "situation": "Opponent plays aggressively with frequent attacks",
      "counter": "Use backdash into whiff punish or power crush moves",
      "risk": "medium",
      "frame_advantage_on_hit": "+15 on launcher",
      "reason": "Aggressive players overcommit - punish their whiffs"
    }
  ]
}
```
