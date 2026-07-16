const std = @import("std");
const w32 = @import("win32").everything;
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

/// IPC Bridge - Named Pipe server that exports frame data to external consumers
/// (Python intelligence service). Uses Windows Named Pipes for low-latency
/// inter-process communication within the same machine.
///
/// Architecture:
///   Zig DLL (in-game) → Named Pipe → Python Intelligence Service
///
/// The bridge serializes frame data as a compact binary protocol with a JSON
/// metadata header, enabling the Python side to consume frames in real-time.
pub const IpcBridge = struct {
    allocator: std.mem.Allocator,
    pipe_handle: ?w32.HANDLE = null,
    is_connected: bool = false,
    frames_sent: u64 = 0,
    last_error: ?IpcError = null,
    settings: IpcSettings = .{},
    write_buffer: [max_frame_buffer_size]u8 = undefined,

    const Self = @This();
    const pipe_name = "\\\\.\\pipe\\synaptyx_referee_ipc";
    const max_frame_buffer_size = 16384; // 16KB per frame message
    const protocol_version: u8 = 1;

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
    }

    /// Creates the named pipe server and waits for a client connection (non-blocking).
    pub fn start(self: *Self) !void {
        if (self.pipe_handle != null) return;

        const pipe_name_wide = std.unicode.utf8ToUtf16LeStringLiteral(pipe_name);

        const handle = w32.CreateNamedPipeW(
            pipe_name_wide,
            w32.PIPE_ACCESS_DUPLEX | w32.FILE_FLAG_OVERLAPPED,
            w32.PIPE_TYPE_MESSAGE | w32.PIPE_READMODE_MESSAGE | w32.PIPE_WAIT,
            1, // max instances
            max_frame_buffer_size, // out buffer size
            4096, // in buffer size
            0, // default timeout
            null, // security attributes
        );

        if (handle == w32.INVALID_HANDLE_VALUE) {
            self.last_error = .{ .kind = .pipe_create_failed, .os_error = w32.GetLastError() };
            return error.PipeCreateFailed;
        }

        self.pipe_handle = handle;
        std.log.info("[IPC Bridge] Named pipe created: {s}", .{pipe_name});
    }

    /// Attempts to connect a client (non-blocking check).
    pub fn tryAcceptClient(self: *Self) bool {
        if (self.pipe_handle == null) return false;
        if (self.is_connected) return true;

        // Non-blocking connect attempt
        const result = w32.ConnectNamedPipe(self.pipe_handle.?, null);
        if (result != 0) {
            self.is_connected = true;
            std.log.info("[IPC Bridge] Client connected.", .{});
            return true;
        }

        const err = w32.GetLastError();
        if (err == .ERROR_PIPE_CONNECTED) {
            self.is_connected = true;
            std.log.info("[IPC Bridge] Client already connected.", .{});
            return true;
        }

        // ERROR_IO_PENDING means waiting for client - this is normal
        return false;
    }

    /// Sends a frame to the connected client.
    /// Returns true if the frame was sent successfully.
    pub fn sendFrame(self: *Self, frame: *const model.Frame) bool {
        if (!self.is_connected) {
            _ = self.tryAcceptClient();
            return false;
        }

        const message = self.serializeFrame(frame) catch |err| {
            std.log.warn("[IPC Bridge] Failed to serialize frame: {}", .{err});
            return false;
        };

        var bytes_written: u32 = 0;
        const success = w32.WriteFile(
            self.pipe_handle.?,
            message.ptr,
            @intCast(message.len),
            &bytes_written,
            null,
        );

        if (success == 0) {
            const err = w32.GetLastError();
            if (err == .ERROR_BROKEN_PIPE or err == .ERROR_NO_DATA) {
                std.log.info("[IPC Bridge] Client disconnected.", .{});
                self.handleClientDisconnect();
            }
            return false;
        }

        self.frames_sent += 1;
        return true;
    }

    /// Sends a match event (non-frame data like match start/end).
    pub fn sendEvent(self: *Self, event: MatchEvent) bool {
        if (!self.is_connected) return false;

        var buf: [1024]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const writer = stream.writer();

        // Write message header
        writer.writeByte(protocol_version) catch return false;
        writer.writeByte(@intFromEnum(MessageType.event)) catch return false;

        // Write event type and data
        writer.writeByte(@intFromEnum(event.event_type)) catch return false;
        writer.writeInt(i64, event.timestamp, .little) catch return false;

        // Write event payload as length-prefixed string
        const payload = event.payload;
        writer.writeInt(u16, @intCast(payload.len), .little) catch return false;
        writer.writeAll(payload) catch return false;

        const message = buf[0..stream.pos];
        var bytes_written: u32 = 0;
        const success = w32.WriteFile(
            self.pipe_handle.?,
            message.ptr,
            @intCast(message.len),
            &bytes_written,
            null,
        );

        return success != 0;
    }

    /// Checks if a client has sent a command (e.g., request coach analysis).
    pub fn readCommand(self: *Self) ?ClientCommand {
        if (!self.is_connected) return null;

        var buf: [512]u8 = undefined;
        var bytes_read: u32 = 0;

        // Peek to see if data is available (non-blocking)
        var bytes_available: u32 = 0;
        _ = w32.PeekNamedPipe(
            self.pipe_handle.?,
            null,
            0,
            null,
            &bytes_available,
            null,
        );

        if (bytes_available == 0) return null;

        const success = w32.ReadFile(
            self.pipe_handle.?,
            &buf,
            @intCast(buf.len),
            &bytes_read,
            null,
        );

        if (success == 0 or bytes_read == 0) return null;

        return parseCommand(buf[0..bytes_read]);
    }

    fn parseCommand(data: []const u8) ?ClientCommand {
        if (data.len < 2) return null;
        if (data[0] != protocol_version) return null;

        return switch (data[1]) {
            0x01 => .request_coach_analysis,
            0x02 => .get_referee_status,
            0x03 => .clear_violations,
            0x04 => .set_match_id,
            0x10 => .ping,
            else => null,
        };
    }

    /// Serializes a frame into the binary wire format.
    fn serializeFrame(self: *Self, frame: *const model.Frame) ![]const u8 {
        var stream = std.io.fixedBufferStream(&self.write_buffer);
        const writer = stream.writer();

        // Message header
        try writer.writeByte(protocol_version);
        try writer.writeByte(@intFromEnum(MessageType.frame_data));

        // Frame metadata
        try writer.writeInt(u32, frame.frames_since_round_start orelse 0, .little);
        try writer.writeInt(u32, frame.frames_left_in_round orelse 0, .little);
        try writer.writeByte(if (frame.match_phase) |mp| @intFromEnum(mp) else 0xFF);
        try writer.writeByte(if (frame.source) |src| @intFromEnum(src) else 0xFF);

        // Player 1 data
        try serializePlayer(writer, &frame.players[0]);
        // Player 2 data
        try serializePlayer(writer, &frame.players[1]);

        return self.write_buffer[0..stream.pos];
    }

    fn serializePlayer(writer: anytype, player: *const model.Player) !void {
        // Identity
        try writer.writeInt(u32, player.character_id orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.animation_id orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.animation_frame orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.animation_total_frames orelse 0xFFFFFFFF, .little);

        // Move state
        try writer.writeByte(if (player.move_phase) |mp| @intFromEnum(mp) else 0xFF);
        try writer.writeByte(if (player.attack_type) |at| @intFromEnum(at) else 0xFF);
        try writer.writeByte(if (player.hit_outcome) |ho| @intFromEnum(ho) else 0xFF);
        try writer.writeByte(if (player.posture) |p| @intFromEnum(p) else 0xFF);
        try writer.writeByte(if (player.blocking) |b| @intFromEnum(b) else 0xFF);

        // Combat stats
        try writer.writeInt(u32, player.health orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.max_health orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.combo_hits orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.combo_damage orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.rounds_won orelse 0xFFFFFFFF, .little);

        // Startup/active/recovery
        try writer.writeInt(u32, player.first_active_frame orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.last_active_frame orelse 0xFFFFFFFF, .little);
        try writer.writeInt(u32, player.connected_frame orelse 0xFFFFFFFF, .little);

        // Input state (packed)
        if (player.input) |input| {
            try writer.writeByte(1); // has_input = true
            var input_bits: u16 = 0;
            if (input.forward) input_bits |= (1 << 0);
            if (input.back) input_bits |= (1 << 1);
            if (input.up) input_bits |= (1 << 2);
            if (input.down) input_bits |= (1 << 3);
            if (input.left) input_bits |= (1 << 4);
            if (input.right) input_bits |= (1 << 5);
            if (input.button_1) input_bits |= (1 << 6);
            if (input.button_2) input_bits |= (1 << 7);
            if (input.button_3) input_bits |= (1 << 8);
            if (input.button_4) input_bits |= (1 << 9);
            if (input.special_style) input_bits |= (1 << 10);
            if (input.rage) input_bits |= (1 << 11);
            if (input.heat) input_bits |= (1 << 12);
            try writer.writeInt(u16, input_bits, .little);
        } else {
            try writer.writeByte(0); // has_input = false
            try writer.writeInt(u16, 0, .little);
        }

        // Heat/Rage state
        if (player.heat) |heat| {
            try writer.writeByte(switch (heat) {
                .available => 0,
                .activated => 1,
                .used_up => 2,
            });
        } else {
            try writer.writeByte(0xFF);
        }

        if (player.rage) |rage| {
            try writer.writeByte(switch (rage) {
                .available => 0,
                .activated => 1,
                .used_up => 2,
            });
        } else {
            try writer.writeByte(0xFF);
        }

        // Position (from collision spheres if available)
        if (player.getPosition()) |pos| {
            try writer.writeByte(1); // has_position
            try writer.writeInt(i32, @bitCast(pos.x()), .little);
            try writer.writeInt(i32, @bitCast(pos.y()), .little);
            try writer.writeInt(i32, @bitCast(pos.z()), .little);
        } else {
            try writer.writeByte(0); // no position
            try writer.writeInt(i32, 0, .little);
            try writer.writeInt(i32, 0, .little);
            try writer.writeInt(i32, 0, .little);
        }

        // Rotation
        if (player.rotation) |rot| {
            try writer.writeInt(i32, @bitCast(rot), .little);
        } else {
            try writer.writeInt(i32, @bitCast(@as(f32, 0.0)), .little);
        }
    }

    fn handleClientDisconnect(self: *Self) void {
        self.is_connected = false;
        _ = w32.DisconnectNamedPipe(self.pipe_handle.?);
        // Ready for next client
        std.log.info("[IPC Bridge] Waiting for new client...", .{});
    }

    pub fn disconnect(self: *Self) void {
        if (self.pipe_handle) |handle| {
            if (self.is_connected) {
                _ = w32.DisconnectNamedPipe(handle);
            }
            _ = w32.CloseHandle(handle);
            self.pipe_handle = null;
            self.is_connected = false;
            std.log.info("[IPC Bridge] Pipe closed.", .{});
        }
    }

    pub fn getStatus(self: *const Self) IpcStatus {
        return .{
            .is_running = self.pipe_handle != null,
            .is_connected = self.is_connected,
            .frames_sent = self.frames_sent,
            .last_error = self.last_error,
        };
    }
};

// ============================================================================
// Protocol Types
// ============================================================================

pub const MessageType = enum(u8) {
    frame_data = 0x01,
    event = 0x02,
    referee_alert = 0x03,
    coach_report = 0x04,
    status = 0x05,
};

pub const EventType = enum(u8) {
    match_start = 0x01,
    match_end = 0x02,
    round_start = 0x03,
    round_end = 0x04,
    recording_start = 0x05,
    recording_end = 0x06,
};

pub const MatchEvent = struct {
    event_type: EventType,
    timestamp: i64,
    payload: []const u8,
};

pub const ClientCommand = enum {
    request_coach_analysis,
    get_referee_status,
    clear_violations,
    set_match_id,
    ping,
};

pub const IpcSettings = struct {
    enabled: bool = false,
    send_every_n_frames: u32 = 1, // Send every frame by default
    include_position: bool = true,
    include_input: bool = true,
};

pub const IpcStatus = struct {
    is_running: bool,
    is_connected: bool,
    frames_sent: u64,
    last_error: ?IpcError,
};

pub const IpcError = struct {
    kind: IpcErrorKind,
    os_error: w32.WIN32_ERROR = .NO_ERROR,
};

pub const IpcErrorKind = enum {
    pipe_create_failed,
    write_failed,
    client_disconnected,
    serialization_failed,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "IpcBridge.init should initialize correctly" {
    var bridge = IpcBridge.init(testing.allocator);
    defer bridge.deinit();
    try testing.expectEqual(false, bridge.is_connected);
    try testing.expectEqual(@as(u64, 0), bridge.frames_sent);
    try testing.expectEqual(@as(?w32.HANDLE, null), bridge.pipe_handle);
}

test "IpcBridge.getStatus should return correct status" {
    var bridge = IpcBridge.init(testing.allocator);
    defer bridge.deinit();
    const status = bridge.getStatus();
    try testing.expectEqual(false, status.is_running);
    try testing.expectEqual(false, status.is_connected);
    try testing.expectEqual(@as(u64, 0), status.frames_sent);
}

test "MessageType enum values should be correct" {
    try testing.expectEqual(@as(u8, 0x01), @intFromEnum(MessageType.frame_data));
    try testing.expectEqual(@as(u8, 0x02), @intFromEnum(MessageType.event));
}

test "parseCommand should handle valid commands" {
    const ping_cmd = [_]u8{ 1, 0x10 };
    try testing.expectEqual(ClientCommand.ping, IpcBridge.parseCommand(&ping_cmd));

    const analysis_cmd = [_]u8{ 1, 0x01 };
    try testing.expectEqual(ClientCommand.request_coach_analysis, IpcBridge.parseCommand(&analysis_cmd));
}

test "parseCommand should reject invalid data" {
    const empty = [_]u8{};
    try testing.expectEqual(@as(?ClientCommand, null), IpcBridge.parseCommand(&empty));

    const wrong_version = [_]u8{ 99, 0x01 };
    try testing.expectEqual(@as(?ClientCommand, null), IpcBridge.parseCommand(&wrong_version));
}
