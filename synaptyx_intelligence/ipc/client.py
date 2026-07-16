"""Named pipe client that connects to the Zig DLL and consumes frame data."""

import asyncio
import struct
import time
from collections.abc import AsyncGenerator
from typing import Optional

import structlog

from synaptyx_intelligence.config.settings import Settings
from synaptyx_intelligence.ipc.protocol import (
    FrameData,
    MatchEvent,
    MessageType,
    deserialize_event,
    deserialize_frame,
)

logger = structlog.get_logger()

# Windows named pipe constants
PIPE_READMODE_MESSAGE = 0x00000002
GENERIC_READ = 0x80000000
GENERIC_WRITE = 0x40000000
OPEN_EXISTING = 3


class IpcClient:
    """Async client that connects to the Synaptyx IPC named pipe.

    Usage:
        client = IpcClient(settings)
        async for frame in client.stream_frames():
            process(frame)
    """

    def __init__(self, settings: Settings):
        self.pipe_name = settings.ipc_pipe_name
        self.reconnect_interval = settings.ipc_reconnect_interval_seconds
        self.protocol_version = settings.ipc_protocol_version
        self._pipe = None
        self._connected = False
        self._frames_received: int = 0
        self._running = False

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def frames_received(self) -> int:
        return self._frames_received

    async def connect(self) -> bool:
        """Attempt to connect to the named pipe.

        On Windows, uses win32file. On other platforms (for testing),
        uses a file-based fallback or returns False.
        """
        try:
            import win32file
            import win32pipe

            self._pipe = win32file.CreateFile(
                self.pipe_name,
                GENERIC_READ | GENERIC_WRITE,
                0,  # no sharing
                None,  # default security
                OPEN_EXISTING,
                0,  # default attributes
                None,  # no template
            )
            win32pipe.SetNamedPipeHandleState(
                self._pipe, PIPE_READMODE_MESSAGE, None, None
            )
            self._connected = True
            logger.info("ipc_connected", pipe=self.pipe_name)
            return True

        except ImportError:
            # Not on Windows - use asyncio pipe for testing
            logger.warning("ipc_not_windows", msg="Win32 pipe not available, using test mode")
            return await self._connect_unix_fallback()

        except Exception as e:
            logger.debug("ipc_connect_failed", error=str(e))
            self._connected = False
            return False

    async def _connect_unix_fallback(self) -> bool:
        """Fallback for non-Windows platforms (testing/development)."""
        # For local development on Linux/Mac, try a Unix domain socket
        socket_path = "/tmp/synaptyx_referee_ipc.sock"
        try:
            reader, writer = await asyncio.open_unix_connection(socket_path)
            self._pipe = (reader, writer)
            self._connected = True
            logger.info("ipc_connected_unix", socket=socket_path)
            return True
        except (FileNotFoundError, ConnectionRefusedError):
            return False

    async def disconnect(self) -> None:
        """Disconnect from the pipe."""
        if self._pipe is not None:
            try:
                import win32file
                win32file.CloseHandle(self._pipe)
            except (ImportError, Exception):
                pass
            self._pipe = None
        self._connected = False
        logger.info("ipc_disconnected")

    async def stream_frames(self) -> AsyncGenerator[FrameData | MatchEvent, None]:
        """Stream frames from the IPC pipe. Reconnects automatically on disconnect.

        Yields FrameData or MatchEvent objects as they arrive.
        """
        self._running = True
        while self._running:
            if not self._connected:
                connected = await self.connect()
                if not connected:
                    await asyncio.sleep(self.reconnect_interval)
                    continue

            try:
                data = await self._read_message()
                if data is None:
                    self._connected = False
                    continue

                message = self._parse_message(data)
                if message is not None:
                    self._frames_received += 1
                    yield message

            except (BrokenPipeError, ConnectionResetError, OSError):
                logger.warning("ipc_pipe_broken", msg="Pipe disconnected, reconnecting...")
                self._connected = False
                await asyncio.sleep(self.reconnect_interval)

    async def _read_message(self) -> Optional[bytes]:
        """Read one complete message from the pipe."""
        try:
            import win32file
            # Read from Windows named pipe
            result, data = win32file.ReadFile(self._pipe, 16384)
            if result == 0:  # Success
                return bytes(data)
            return None
        except ImportError:
            # Unix fallback
            if isinstance(self._pipe, tuple):
                reader, _ = self._pipe
                # Read message length prefix (if using stream mode)
                try:
                    data = await asyncio.wait_for(reader.read(16384), timeout=1.0)
                    return data if data else None
                except asyncio.TimeoutError:
                    return None
            return None

    def _parse_message(self, data: bytes) -> Optional[FrameData | MatchEvent]:
        """Parse raw bytes into a typed message."""
        if len(data) < 2:
            return None

        msg_type = data[1]

        if msg_type == MessageType.FRAME_DATA:
            return deserialize_frame(data)
        elif msg_type == MessageType.EVENT:
            return deserialize_event(data)
        else:
            return None

    async def send_command(self, command_id: int) -> bool:
        """Send a command to the Zig DLL."""
        cmd_data = struct.pack("BB", self.protocol_version, command_id)
        try:
            import win32file
            win32file.WriteFile(self._pipe, cmd_data)
            return True
        except (ImportError, Exception):
            return False

    async def request_coach_analysis(self) -> bool:
        """Request the DLL to trigger coach analysis."""
        return await self.send_command(0x01)

    async def ping(self) -> bool:
        """Send a ping to verify the connection."""
        return await self.send_command(0x10)

    def stop(self) -> None:
        """Stop the streaming loop."""
        self._running = False
