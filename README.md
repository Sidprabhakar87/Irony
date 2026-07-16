# Synaptyx Referee

AI-powered referee and coaching system for competitive Tekken 8 esports tournaments. Built on the Irony frame analysis engine, Synaptyx Referee provides real-time match monitoring, violation detection, and post-match coaching insights for tournament organizers and players.

## Features

### AI Referee (Real-Time Match Monitoring)
- Detect suspicious input patterns (macros, inhuman input speed)
- Monitor for exploits and illegal player positions
- Real-time violation alerting to tournament platform via REST API
- Configurable strictness levels (lenient, normal, strict)
- Complete audit trail with frame-level evidence

### AI Coach (Post-Match Analysis)
- Analyze recorded matches frame by frame
- Identify missed punish opportunities with frame-precise data
- Profile opponent playstyle (aggressive, defensive, poke-heavy, neutral)
- Generate counter-strategy recommendations
- Produce structured coaching reports (JSON/text) for platform integration

### Frame Analysis Engine (from Irony)
- View situations from front, top and side
- Record situations from practice mode, live games and replays
- Examine hit lines, hurt cylinders and collision spheres
- Measure startup, active and recovery frames as well as the frame advantage
- Precisely measure attack range, attack height and recovery range
- Precisely measure distance and angle to opponent and wall
- Examine posture, blocking and crushing frame by frame
- Record suspicious replays and examine player inputs frame by frame

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  Tournament SaaS Platform                     │
│                  (GameParlour / Custom)                       │
└───────────────────────────┬──────────────────────────────────┘
                            │ REST API
            ┌───────────────┴───────────────┐
            │                               │
            ▼                               ▼
┌───────────────────────┐       ┌───────────────────────┐
│   Synaptyx Referee    │       │   Synaptyx Coach      │
│   (Live Monitoring)   │       │   (Post-Match)        │
├───────────────────────┤       ├───────────────────────┤
│ • Violation detection │       │ • Replay analysis     │
│ • Input validation    │       │ • Strategy generation │
│ • Event logging       │       │ • Opponent profiling  │
│ • Real-time alerts    │       │ • Punish optimization │
└───────────────────────┘       └───────────────────────┘
            │                               │
            └───────────────┬───────────────┘
                            │
                ┌───────────▼───────────┐
                │   Irony Frame Engine  │
                │   (Memory + Capture)  │
                ├───────────────────────┤
                │ • Per-frame capture   │
                │ • Hit/hurt detection  │
                │ • Move measurement    │
                │ • Position tracking   │
                └───────────────────────┘
```

## Quick Start

### For Tournament Organizers

1. Download the latest release from [Releases](https://github.com/Sidprabhakar87/Irony/releases/latest).
2. Extract the `.zip` archive.
3. Configure `settings.json` with your tournament platform API endpoint and key:
   ```json
   {
     "referee": {
       "enabled": true,
       "strictness": "normal",
       "api_endpoint": "https://your-platform.com",
       "api_key": "your-api-key",
       "match_id": "tournament-match-001"
     },
     "coach": {
       "enabled": true,
       "api_endpoint": "https://your-platform.com",
       "api_key": "your-api-key",
       "analysis_depth": "detailed"
     }
   }
   ```
4. Run `irony_injector.exe` on each player's PC.
5. Launch Tekken 8 via Steam.
6. The referee monitors automatically; coach analysis triggers after each match.

### For Players (Standalone Coaching)

1. Download and extract the release.
2. Enable coach in settings (referee can be disabled for personal use).
3. Run `irony_injector.exe` and launch Tekken 8.
4. Play matches - coaching reports generate automatically after each match.
5. Press `Tab` to open the UI for frame analysis visualization.

## Installation

### Windows

1. Download the latest release from [here](https://github.com/Sidprabhakar87/Irony/releases/latest).
2. Extract the `.zip` archive anywhere you want.
3. Run `irony_injector.exe` from the extracted archive.
4. Launch the game using Steam.
5. Once in the game, press `Tab` to open the UI.

(You can also run `irony_injector.exe` after the game already started.)

### Linux

1. Download the latest release from [here](https://github.com/Sidprabhakar87/Irony/releases/latest).
2. Extract the `.zip` archive anywhere you want.
3. Launch the game using Steam.
4. Use proton to run `irony_injector.exe` with `only_inject` command line argument inside the same Wine prefix that the game is running in:
    - For native Steam installation:

    ```bash
    STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.local/share/Steam \
    STEAM_COMPAT_DATA_PATH=$HOME/.local/share/Steam/steamapps/compatdata/1778820 \
    WINEPREFIX=$HOME/.local/share/Steam/steamapps/compatdata/1778820/pfx \
    $HOME/.local/share/Steam/compatibilitytools.d/GE-Proton10-20/proton run \
    Z:/home/user_name/path_to_synaptyx_folder/irony_injector.exe only_inject
    ```

    - For flatpak Steam installation:

    ```bash
    flatpak run --command=bash com.valvesoftware.Steam -c '
    STEAM_COMPAT_CLIENT_INSTALL_PATH=$HOME/.var/app/com.valvesoftware.Steam/.steam/root \
    STEAM_COMPAT_DATA_PATH=$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata/1778820 \
    WINEPREFIX=$HOME/.var/app/com.valvesoftware.Steam/.local/share/Steam/steamapps/compatdata/1778820/pfx \
    $HOME/.var/app/com.valvesoftware.Steam/.steam/root/compatibilitytools.d/GE-Proton10-20/proton run \
    Z:/home/user_name/path_to_synaptyx_folder/irony_injector.exe only_inject
    '
    ```

    - Modify the command to reflect your steamapps directory, proton version, and Synaptyx Referee directory location.

5. Once injected, press `Tab` to open the UI.

## API Integration

### Violation Events (Referee)

The referee sends violation events to your platform in real-time:

```json
{
  "event_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "match_id": "tournament-match-456",
  "player_id": "player_1",
  "timestamp": 1720000000,
  "violation": {
    "type": "macro_detected",
    "severity": "warning",
    "frame_number": 2341,
    "description": "Repetitive input pattern detected - possible macro usage"
  },
  "recommendation": "Review player input history for macro patterns"
}
```

### Coaching Reports (Coach)

Post-match coaching reports are submitted automatically:

```json
{
  "match_id": "tournament-match-456",
  "player_id": "player_1",
  "opponent_id": "player_2",
  "summary": {
    "rounds_won": 2,
    "rounds_lost": 3,
    "total_damage_dealt": 1847,
    "total_damage_taken": 2103
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
    "favorite_moves": [142, 87, 203],
    "heat_activations": 3,
    "rage_activations": 1
  },
  "strategy_recommendations": [
    {
      "situation": "Opponent plays aggressively with frequent attacks",
      "counter": "Use backdash into whiff punish or power crush moves",
      "risk": "medium",
      "reason": "Aggressive players overcommit - punish their whiffs"
    }
  ]
}
```

## Building From Source

Take a look inside the [build.zig.zon](./build.zig.zon) file.
Under the property `.zig_version` there is a version of the Zig programming language that the project is to be compiled with.
Install that version of the Zig compiler onto your machine using the [official Zig tutorial](https://ziglang.org/learn/getting-started).

Make sure that your version of the Zig compiler matches the `.zig_version`, execute:

```bash
zig version
```

To build the project in debug mode:

```bash
zig build
```

To build the project in release mode:

```bash
zig build --release=fast
```

After compilation, binaries will be in `zig-out/bin`.

To run during development:

```bash
zig build run
```

Disable compilation of a specific game's DLL:

```bash
zig build run -Dt7=false
zig build run -Dt8=false
```

To run tests:

```bash
zig build test
```

If you are on Linux, tests run inside Wine. Make sure Wine is installed with `dxvk` and `vkd3d`:

```bash
winetricks dxvk vkd3d
```

## Project Structure

```
src/
├── dll/
│   ├── api/          # REST API client for SaaS platform communication
│   ├── core/         # Core logic: referee, coach, match stats, frame processing
│   ├── game/         # Game memory reading, frame capture, hooks
│   ├── model/        # Data models: frames, players, settings
│   ├── rendering/    # 3D visualization (hit lines, hurt cylinders)
│   └── ui/           # ImGui-based UI overlay
├── injector/         # DLL injection into game process
└── sdk/              # Shared utilities (math, memory, DirectX, logging)
```

## Credits

- **Frame Analysis Engine**: Based on [Irony](https://github.com/tomislav-ivankovic/Irony) by Tomislav Ivankovic
- **AI Referee & Coach**: Developed for the Synaptyx esports platform

## License

This software is licensed under the [PolyForm Strict License 1.0.0](./LICENSE.md).
The AI Referee and Coach components are proprietary additions for tournament use.
