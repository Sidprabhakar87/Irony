"""Binary protocol definitions matching the Zig DLL IPC bridge.

Wire format (little-endian):
  [1 byte]  protocol_version
  [1 byte]  message_type
  [...]     payload (depends on message_type)

Frame data payload:
  [4 bytes] frames_since_round_start (u32)
  [4 bytes] frames_left_in_round (u32)
  [1 byte]  match_phase (enum or 0xFF = null)
  [1 byte]  source (enum or 0xFF = null)
  [N bytes] player_1 data
  [N bytes] player_2 data
"""

import struct
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Optional


class MessageType(IntEnum):
    FRAME_DATA = 0x01
    EVENT = 0x02
    REFEREE_ALERT = 0x03
    COACH_REPORT = 0x04
    STATUS = 0x05


class MovePhase(IntEnum):
    NEUTRAL = 0
    START_UP = 1
    ACTIVE = 2
    ACTIVE_RECOVERY = 3
    RECOVERY = 4


class AttackType(IntEnum):
    NOT_ATTACK = 0
    HIGH = 1
    MID = 2
    LOW = 3
    SPECIAL_LOW = 4
    UNBLOCKABLE_HIGH = 5
    UNBLOCKABLE_MID = 6
    UNBLOCKABLE_LOW = 7
    THROW = 8
    PROJECTILE = 9
    ANTIAIR_ONLY = 10


class HitOutcome(IntEnum):
    NONE = 0
    BLOCKED_STANDING = 1
    BLOCKED_CROUCHING = 2
    JUGGLE = 3
    SCREW = 4
    GROUNDED_FACE_DOWN = 5
    GROUNDED_FACE_UP = 6
    COUNTER_HIT_STANDING = 7
    COUNTER_HIT_CROUCHING = 8
    NORMAL_HIT_STANDING = 9
    NORMAL_HIT_CROUCHING = 10


class MatchPhase(IntEnum):
    NOT_IN_A_MATCH = 0
    INTRO = 1
    OUTRO = 2
    ROUND_START = 3
    ROUND_END = 4
    MID_ROUND = 5
    IN_BETWEEN_ROUNDS = 6


class HeatState(IntEnum):
    AVAILABLE = 0
    ACTIVATED = 1
    USED_UP = 2


class RageState(IntEnum):
    AVAILABLE = 0
    ACTIVATED = 1
    USED_UP = 2


class EventType(IntEnum):
    MATCH_START = 0x01
    MATCH_END = 0x02
    ROUND_START = 0x03
    ROUND_END = 0x04
    RECORDING_START = 0x05
    RECORDING_END = 0x06


@dataclass
class InputState:
    """Packed input state from the game."""

    forward: bool = False
    back: bool = False
    up: bool = False
    down: bool = False
    left: bool = False
    right: bool = False
    button_1: bool = False
    button_2: bool = False
    button_3: bool = False
    button_4: bool = False
    special_style: bool = False
    rage: bool = False
    heat: bool = False

    @classmethod
    def from_bits(cls, bits: int) -> "InputState":
        return cls(
            forward=bool(bits & (1 << 0)),
            back=bool(bits & (1 << 1)),
            up=bool(bits & (1 << 2)),
            down=bool(bits & (1 << 3)),
            left=bool(bits & (1 << 4)),
            right=bool(bits & (1 << 5)),
            button_1=bool(bits & (1 << 6)),
            button_2=bool(bits & (1 << 7)),
            button_3=bool(bits & (1 << 8)),
            button_4=bool(bits & (1 << 9)),
            special_style=bool(bits & (1 << 10)),
            rage=bool(bits & (1 << 11)),
            heat=bool(bits & (1 << 12)),
        )

    def has_any(self) -> bool:
        return any([
            self.forward, self.back, self.up, self.down,
            self.left, self.right, self.button_1, self.button_2,
            self.button_3, self.button_4, self.special_style,
            self.rage, self.heat,
        ])

    def count_active(self) -> int:
        return sum([
            self.forward, self.back, self.up, self.down,
            self.left, self.right, self.button_1, self.button_2,
            self.button_3, self.button_4, self.special_style,
            self.rage, self.heat,
        ])


@dataclass
class Position:
    x: float = 0.0
    y: float = 0.0
    z: float = 0.0


@dataclass
class PlayerData:
    """Deserialized player state from one frame."""

    character_id: Optional[int] = None
    animation_id: Optional[int] = None
    animation_frame: Optional[int] = None
    animation_total_frames: Optional[int] = None
    move_phase: Optional[MovePhase] = None
    attack_type: Optional[AttackType] = None
    hit_outcome: Optional[HitOutcome] = None
    posture: Optional[int] = None
    blocking: Optional[int] = None
    health: Optional[int] = None
    max_health: Optional[int] = None
    combo_hits: Optional[int] = None
    combo_damage: Optional[int] = None
    rounds_won: Optional[int] = None
    first_active_frame: Optional[int] = None
    last_active_frame: Optional[int] = None
    connected_frame: Optional[int] = None
    input: Optional[InputState] = None
    heat_state: Optional[HeatState] = None
    rage_state: Optional[RageState] = None
    position: Optional[Position] = None
    rotation: float = 0.0


@dataclass
class FrameData:
    """One complete frame of game state."""

    frames_since_round_start: int = 0
    frames_left_in_round: int = 0
    match_phase: Optional[MatchPhase] = None
    source: Optional[int] = None
    player_1: PlayerData = field(default_factory=PlayerData)
    player_2: PlayerData = field(default_factory=PlayerData)


@dataclass
class MatchEvent:
    """A match lifecycle event."""

    event_type: EventType
    timestamp: int
    payload: str = ""


# ============================================================================
# Binary deserialization
# ============================================================================

PROTOCOL_VERSION = 1

# Player data format: character_id(4) + animation_id(4) + animation_frame(4) +
# animation_total_frames(4) + move_phase(1) + attack_type(1) + hit_outcome(1) +
# posture(1) + blocking(1) + health(4) + max_health(4) + combo_hits(4) +
# combo_damage(4) + rounds_won(4) + first_active_frame(4) + last_active_frame(4) +
# connected_frame(4) + has_input(1) + input_bits(2) + heat_state(1) + rage_state(1) +
# has_position(1) + pos_x(4) + pos_y(4) + pos_z(4) + rotation(4)
PLAYER_DATA_SIZE = 4 + 4 + 4 + 4 + 1 + 1 + 1 + 1 + 1 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 1 + 2 + 1 + 1 + 1 + 4 + 4 + 4 + 4  # = 70 bytes
FRAME_HEADER_SIZE = 2 + 4 + 4 + 1 + 1  # version + msg_type + frames_since + frames_left + match_phase + source = 12


def _read_optional_u32(data: bytes, offset: int) -> tuple[Optional[int], int]:
    """Read a u32, treating 0xFFFFFFFF as None."""
    val = struct.unpack_from("<I", data, offset)[0]
    return (None if val == 0xFFFFFFFF else val, offset + 4)


def _read_optional_u8(data: bytes, offset: int) -> tuple[Optional[int], int]:
    """Read a u8, treating 0xFF as None."""
    val = data[offset]
    return (None if val == 0xFF else val, offset + 1)


def deserialize_player(data: bytes, offset: int) -> tuple[PlayerData, int]:
    """Deserialize a player from binary data starting at offset."""
    player = PlayerData()

    player.character_id, offset = _read_optional_u32(data, offset)
    player.animation_id, offset = _read_optional_u32(data, offset)
    player.animation_frame, offset = _read_optional_u32(data, offset)
    player.animation_total_frames, offset = _read_optional_u32(data, offset)

    mp, offset = _read_optional_u8(data, offset)
    player.move_phase = MovePhase(mp) if mp is not None else None

    at, offset = _read_optional_u8(data, offset)
    player.attack_type = AttackType(at) if at is not None else None

    ho, offset = _read_optional_u8(data, offset)
    player.hit_outcome = HitOutcome(ho) if ho is not None else None

    player.posture, offset = _read_optional_u8(data, offset)
    player.blocking, offset = _read_optional_u8(data, offset)

    player.health, offset = _read_optional_u32(data, offset)
    player.max_health, offset = _read_optional_u32(data, offset)
    player.combo_hits, offset = _read_optional_u32(data, offset)
    player.combo_damage, offset = _read_optional_u32(data, offset)
    player.rounds_won, offset = _read_optional_u32(data, offset)

    player.first_active_frame, offset = _read_optional_u32(data, offset)
    player.last_active_frame, offset = _read_optional_u32(data, offset)
    player.connected_frame, offset = _read_optional_u32(data, offset)

    # Input
    has_input = data[offset]
    offset += 1
    input_bits = struct.unpack_from("<H", data, offset)[0]
    offset += 2
    player.input = InputState.from_bits(input_bits) if has_input else None

    # Heat/Rage
    hs, offset = _read_optional_u8(data, offset)
    player.heat_state = HeatState(hs) if hs is not None else None

    rs, offset = _read_optional_u8(data, offset)
    player.rage_state = RageState(rs) if rs is not None else None

    # Position
    has_pos = data[offset]
    offset += 1
    px = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    py = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    pz = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    if has_pos:
        player.position = Position(
            x=struct.unpack("<f", struct.pack("<i", px))[0],
            y=struct.unpack("<f", struct.pack("<i", py))[0],
            z=struct.unpack("<f", struct.pack("<i", pz))[0],
        )

    # Rotation
    rot_raw = struct.unpack_from("<i", data, offset)[0]
    offset += 4
    player.rotation = struct.unpack("<f", struct.pack("<i", rot_raw))[0]

    return player, offset


def deserialize_frame(data: bytes) -> Optional[FrameData]:
    """Deserialize a complete frame message from binary data."""
    if len(data) < FRAME_HEADER_SIZE:
        return None

    offset = 0
    version = data[offset]
    offset += 1
    if version != PROTOCOL_VERSION:
        return None

    msg_type = data[offset]
    offset += 1
    if msg_type != MessageType.FRAME_DATA:
        return None

    frame = FrameData()
    frame.frames_since_round_start = struct.unpack_from("<I", data, offset)[0]
    offset += 4
    frame.frames_left_in_round = struct.unpack_from("<I", data, offset)[0]
    offset += 4

    mp, offset = _read_optional_u8(data, offset)
    frame.match_phase = MatchPhase(mp) if mp is not None else None

    frame.source, offset = _read_optional_u8(data, offset)

    frame.player_1, offset = deserialize_player(data, offset)
    frame.player_2, offset = deserialize_player(data, offset)

    return frame


def deserialize_event(data: bytes) -> Optional[MatchEvent]:
    """Deserialize a match event message."""
    if len(data) < 4:
        return None

    offset = 0
    version = data[offset]
    offset += 1
    if version != PROTOCOL_VERSION:
        return None

    msg_type = data[offset]
    offset += 1
    if msg_type != MessageType.EVENT:
        return None

    event_type = EventType(data[offset])
    offset += 1

    timestamp = struct.unpack_from("<q", data, offset)[0]
    offset += 8

    payload_len = struct.unpack_from("<H", data, offset)[0]
    offset += 2

    payload = data[offset:offset + payload_len].decode("utf-8", errors="replace")

    return MatchEvent(event_type=event_type, timestamp=timestamp, payload=payload)
