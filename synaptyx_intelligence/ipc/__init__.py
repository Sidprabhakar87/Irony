"""IPC module - Named pipe client for communicating with Zig DLL."""

from synaptyx_intelligence.ipc.client import IpcClient
from synaptyx_intelligence.ipc.protocol import FrameData, PlayerData, MatchEvent, MessageType

__all__ = ["IpcClient", "FrameData", "PlayerData", "MatchEvent", "MessageType"]
