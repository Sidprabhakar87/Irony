# 1. OBJECTIVE

Build an **AI Referee** and **AI Coach** system for Tekken 8 that integrates with a SaaS tournament platform (already built separately). 

- **Referee**: Real-time match monitoring for tournament integrity (violations, fair play) - can run server-side or as a side process
- **Coach**: Post-match analysis only (NO in-game overlay during play) - analyzes replays to explain optimal strategies, suggest counter-strategies, and profile opponent playstyle

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
│    AI Referee       │       │    AI Coach        │
│  (Live Monitoring)  │       │  (Post-Match)      │
├─────────────────────┤       ├─────────────────────┤
│ • Violation detect  │       │ • Replay analysis  │
│ • Input validation  │       │ • Strategy suggest │
│ • Event logging     │       │ • Opponent profiling│
│ • Server-side       │       │ • Frame-by-frame   │
└─────────────────────┘       │   review           │
                              └─────────────────────┘
```

## Tekken 8 Telemetry Access
The existing Irony codebase reads Tekken 8 memory through:
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
- **Player Info**: character_id, health, rage, heat (T8), input state

## Architecture
- Built with Zig targeting Windows (DX12)
- Event-driven: tick() called every frame, draw() for rendering
- Core modules: Capturer → HitDetector → MoveDetector → MoveMeasurer

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
│  Gameparlour     │      │  AI Referee/Coach │      │  Tournament     │
│  Client PC       │─────▶│  (Windows DLL)    │─────▶│  SaaS Platform  │
│  + Tekken 8      │      │                   │      │  (API endpoint) │
│  + Irony DLL     │      │  • Live capture   │      │                 │
└──────────────────┘      │  • Post-match     │      │  • Violations   │
                         │    analysis       │      │  • Coaching      │
                         └───────────────────┘      │    reports       │
                                                    └─────────────────┘
```

## Core Components

### AI Referee System (Real-time, Server-Side)
- **Match Observer**: Tracks rule compliance frame-by-frame during live matches
- **Violation Detector**: Monitors for input delays, macro usage, exploits
- **Event Logger**: Records all significant events in machine-readable format (JSON)
- **API Output**: Sends violation alerts to tournament platform via HTTP/REST

### AI Coach System (Post-Match Only)
- **Replay Analyzer**: Processes recorded match frames for deep analysis
- **Optimal Play Finder**: Identifies "winning move sequences" that were missed
- **Opponent Profiler**: Builds style model from opponent's actual gameplay data
- **Character Matchup Advisor**: Generates counter-strategy guides based on frame data
- **Coaching Report Generator**: Creates detailed coaching output (JSON/text) for platform

# 4. IMPLEMENTATION STEPS

## Step 1: Create Coach Core Module (Post-Match Analysis)
**Goal**: Build the foundational coach module for post-match analysis
**Method**: Create `src/dll/core/coach.zig` with:
- `Coach` struct - stateless analyzer that processes recorded frames
- `PlayerTendency` struct - models opponent's gameplay style (habitual moves, patterns)
- `MatchAnalysis` struct - holds complete analysis results
- `analyzeReplay()` - processes a full match recording, returns coaching insights
- `identifyOptimalPunishment()` - finds missed punish opportunities
- `profileOpponentStyle()` - builds opponent tendency model from their moves
- `generateStrategyGuide()` - suggests counter-strategies based on frame data

**Output**: Coaching report in JSON format (not in-game display)

**Reference**: Extend pattern from `move_detector.zig` and `move_measurer.zig`

---

## Step 2: Create Referee Core Module (Live Monitoring)
**Goal**: Build the referee system for real-time tournament monitoring
**Method**: Create `src/dll/core/referee.zig` with:
- `Referee` struct with per-match violation tracking
- `ViolationType` enum:
  - `input_delay` - inputs faster/slower than humanly possible
  - `macro_detected` - repetitive input patterns from keyboard macros
  - `exploit_used` - known game exploits
  - `illegal_position` - impossible player positions
- `ViolationEvent` struct with: frame_number, violation_type, evidence, severity
- `checkInputDelay()` - detects inputs <1 frame apart
- `checkMacroUsage()` - pattern-matching for macro signatures
- `checkExploitUsage()` - detects known exploits
- `logViolation()` - records events with full frame context
- `exportReport()` - outputs machine-readable JSON for tournament platform

**Output**: Real-time violation logs in JSON format via API

**Reference**: Leverage existing `model.Frame` capture structure

---

## Step 3: Create API Client for SaaS Integration
**Goal**: Enable communication with the tournament SaaS platform
**Method**: Create `src/dll/api/client.zig` with:
- `ApiClient` struct for HTTP/REST communication
- `sendViolationAlert()` - POST violation events to tournament platform
- `submitCoachingReport()` - POST completed coaching analysis
- `heartbeat()` - maintain connection during matches
- `authenticate()` - handle API authentication
- Configuration for API endpoint URL, API keys, etc.

**Reference**: Use existing `sdk.io` patterns for file/network I/O

---

## Step 4: Create Coach Report Generator
**Goal**: Generate structured coaching reports from analysis
**Method**: Create `src/dll/core/coach_report.zig` with:
- `CoachReport` struct containing all analysis output
- `MatchSummary` - round-by-round breakdown with frame advantage
- `PunishAnalysis` - missed punish opportunities with frame data
- `TendencyReport` - opponent style profiling
- `StrategyGuide` - character-specific counter-strategy recommendations
- `exportToJson()` - serialize report for API transmission
- `exportToText()` - human-readable coaching summary

**Reference**: Follow existing serialization patterns in the codebase

---

## Step 5: Create Match Statistics Analyzer
**Goal**: Generate detailed match statistics for coaching insights
**Method**: Create `src/dll/core/match_stats.zig` with:
- `MatchStats` struct - aggregate statistics from match frames
- `calculateFrameAdvantage()` - per-round frame advantage trends
- `countMoves()` - frequency analysis of used moves
- `identifyPatterns()` - recurring move sequences
- `damageAnalysis()` - damage dealt, taken, conversions
- `heatRageAnalysis()` - T8-specific heat/rage usage patterns

---

## Step 6: Integrate Referee into Core Tick Loop
**Goal**: Wire referee into the main processing pipeline for live monitoring
**Method**: Modify `src/dll/core/core.zig`:
- Add `referee: Referee` to `Core` struct
- Call `referee.tick()` in `Core.tick()` for each captured frame
- Connect `referee.exportReport()` to API client
- Ensure minimal overhead (<1ms per frame)

**Reference**: Follow existing pattern in `core.zig` for capturer/detector integration

---

## Step 7: Add Coach Analysis Trigger
**Goal**: Enable post-match coach analysis via API request
**Method**: 
- Add `requestCoachAnalysis()` function that triggers analysis
- Process recorded frames from `model.Recording`
- Return `CoachReport` via API client
- Can be called on-demand after match completion

**Reference**: Leverage existing recording system in `controller.zig`

---

## Step 8: Add Referee & Coach Settings
**Goal**: Allow tournament organizers to configure behavior
**Method**: 
- Add `RefereeSettings` to `src/dll/model/settings.zig`:
  - `enabled`: bool
  - `strictness`: enum (lenient, normal, strict)
  - `api_endpoint`: string
  - `api_key`: string
  - `violation_thresholds`: configurable sensitivity
- Add `CoachSettings`:
  - `enabled`: bool
  - `api_endpoint`: string
  - `analysis_depth`: enum (basic, detailed, comprehensive)
- Load settings from config file or environment

---

## Step 9: Export Modules
**Goal**: Make new modules accessible from other parts of the codebase
**Method**: Modify `src/dll/core/root.zig`:
- Add exports for `Coach`, `Referee`, `ApiClient`, `CoachReport`, `MatchStats`
- Add exports for `ViolationType`, `ViolationEvent`, `CoachRecommendation`

---

## Step 10: Build, Test & Documentation
**Goal**: Verify implementation and prepare for integration
**Method**: 
- Run `zig build` to verify compilation
- Create unit tests for coach analysis logic
- Create unit tests for referee violation detection
- Create integration tests with mock frame data
- Document API endpoints and JSON formats for tournament platform team

# 5. TESTING AND VALIDATION

## Success Criteria

### AI Coach System (Post-Match)
- **Replay Analysis**: Successfully processes recorded match frames
- **Optimal Play Detection**: Identifies "winning moves" that player missed
- **Opponent Profiling**: Correctly categorizes opponent playstyle (aggressive, defensive, etc.)
- **Strategy Generation**: Produces actionable counter-strategy recommendations
- **Report Output**: Generates valid JSON report suitable for API transmission

### AI Referee System (Live)
- **Violation Detection**: Accurately flags suspicious inputs (<1 frame delay)
- **Macro Detection**: Identifies repetitive input patterns from macros
- **Event Logging**: Captures all violations with timestamps and evidence
- **API Integration**: Successfully sends data to tournament platform
- **False Positive Rate**: <5% in normal gameplay conditions

### Integration with SaaS Platform
- **API Communication**: HTTP/REST calls work reliably
- **JSON Output**: All reports are valid, parseable JSON
- **Performance**: <1ms overhead per frame (no impact on gameplay)
- **Reliability**: Handles network failures gracefully (queue and retry)

## Validation Methods

1. **Unit Tests**: 
   - Coach analysis logic with mock frame data
   - Referee violation detection with synthetic inputs
   - JSON serialization/deserialization

2. **Integration Tests**:
   - Referee integrates with tick loop without errors
   - API client sends/receives data correctly

3. **End-to-End Tests**:
   - Record a Tekken 8 match
   - Process through coach → verify report output
   - Run live match through referee → verify violation alerts

4. **SaaS Integration Tests**:
   - Connect to mock tournament platform API
   - Verify reports appear correctly on platform
   - Test webhook/notification delivery

## Example Coach Report Output

```json
{
  "match_id": "abc123",
  "player_id": "player1",
  "opponent_id": "player2",
  "player_character": "kazuya",
  "opponent_character": "jin",
  "summary": {
    "rounds_won": 2,
    "rounds_lost": 3,
    "total_damage_dealt": 1847,
    "total_damage_taken": 2103
  },
  "missed_punishments": [
    {
      "round": 2,
      "frame": 145,
      "opponent_move": "jin_13f_mid",
      "opponent_on_block": -13,
      "player_should_punish": true,
      "player_used_move": "none",
      "impact": "high"
    }
  ],
  "opponent_tendencies": {
    "playstyle": "aggressive",
    "favorite_moves": ["jin_13f_mid", "jin_ws4"],
    "habitual_patterns": ["always uses low after throw escape"],
    "heatmap": { "center": "mid-range", "favorite_distance": "close" }
  },
  "strategy_recommendations": [
    {
      "situation": "opponent uses jin_13f_mid",
      "counter": "electric_wind_god_fist",
      "risk": "high",
      "frame_advantage_on_hit": "+4",
      "reason": "Electric is i10, opponent is -13 on block"
    }
  ]
}
```

## Example Referee Violation Event

```json
{
  "event_id": "uuid-here",
  "match_id": "tournament-match-456",
  "player_id": "player1",
  "timestamp": "2024-01-15T10:30:00Z",
  "violation": {
    "type": "input_delay",
    "severity": "warning",
    "frame_number": 2341,
    "evidence": {
      "input_interval": 0,
      "minimum_human_interval": 1
    },
    "description": "Input detected at 0-frame interval"
  },
  "recommendation": "Monitor player for continued suspicious inputs"
}
```
