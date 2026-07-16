const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

pub const Referee = struct {
    player_1_state: PlayerState = .{},
    player_2_state: PlayerState = .{},
    violations: std.ArrayList(ViolationEvent),
    settings: RefereeSettings = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .violations = std.ArrayList(ViolationEvent).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.violations.deinit();
    }

    pub fn tick(self: *Self, frame: *const model.Frame) void {
        self.checkInputDelay(&frame.players[0], .player_1, frame.frames_since_round_start orelse 0);
        self.checkInputDelay(&frame.players[1], .player_2, frame.frames_since_round_start orelse 0);
        self.checkMacroUsage(&frame.players[0], .player_1, frame.frames_since_round_start orelse 0);
        self.checkMacroUsage(&frame.players[1], .player_2, frame.frames_since_round_start orelse 0);
        self.checkIllegalPositions(frame);
    }

    fn checkInputDelay(self: *Self, player: *const model.Player, player_id: model.PlayerId, frame_number: u32) void {
        const state = switch (player_id) {
            .player_1 => &self.player_1_state,
            .player_2 => &self.player_2_state,
        };

        if (player.input == null) return;
        const current_input = player.input.?;

        if (state.previous_input != null) {
            const prev = state.previous_input.?;
            const current = current_input;

            if (detectInstantInput(prev, current)) {
                self.logViolation(.{
                    .event_id = generateUuid(),
                    .match_id = self.settings.match_id,
                    .player_id = @tagName(player_id),
                    .timestamp = std.time.timestamp(),
                    .violation = .{
                        .type = .input_delay,
                        .severity = .warning,
                        .frame_number = frame_number,
                        .evidence = .{
                            .input_interval = 0,
                            .minimum_human_interval = 1,
                        },
                        .description = "Input detected at 0-frame interval",
                    },
                    .recommendation = "Monitor player for continued suspicious inputs",
                });
            }

            if (detectUnrealisticSpeed(prev, current, state)) {
                self.logViolation(.{
                    .event_id = generateUuid(),
                    .match_id = self.settings.match_id,
                    .player_id = @tagName(player_id),
                    .timestamp = std.time.timestamp(),
                    .violation = .{
                        .type = .input_delay,
                        .severity = .warning,
                        .frame_number = frame_number,
                        .evidence = .{
                            .input_interval = state.frames_since_last_input,
                            .minimum_human_interval = 2,
                        },
                        .description = "Input speed exceeds human capability",
                    },
                    .recommendation = "Review input patterns",
                });
            }
        }

        if (hasAnyInput(current_input)) {
            state.frames_since_last_input = 0;
        } else {
            state.frames_since_last_input += 1;
        }
        state.previous_input = current_input;
    }

    fn detectInstantInput(prev: model.Input, current: model.Input) bool {
        return prev.forward != current.forward or
            prev.back != current.back or
            prev.up != current.up or
            prev.down != current.down or
            prev.left != current.left or
            prev.right != current.right or
            prev.button_1 != current.button_1 or
            prev.button_2 != current.button_2 or
            prev.button_3 != current.button_3 or
            prev.button_4 != current.button_4;
    }

    fn detectUnrealisticSpeed(prev: model.Input, current: model.Input, state: *const PlayerState) bool {
        _ = prev;
        _ = current;
        return state.frames_since_last_input < 2;
    }

    fn hasAnyInput(input: model.Input) bool {
        return input.forward or input.back or input.up or input.down or
            input.left or input.right or input.button_1 or input.button_2 or
            input.button_3 or input.button_4 or input.special_style or
            input.rage or input.heat;
    }

    fn checkMacroUsage(self: *Self, player: *const model.Player, player_id: model.PlayerId, frame_number: u32) void {
        const state = switch (player_id) {
            .player_1 => &self.player_1_state,
            .player_2 => &self.player_2_state,
        };

        if (player.animation_id == null) return;

        state.input_sequence[state.input_index % input_sequence_len] = player.animation_id.?;
        state.input_index += 1;

        if (state.input_index >= input_sequence_len * 2) {
            if (detectRepetitivePattern(state.input_sequence[0..input_sequence_len], state.input_sequence[input_sequence_len..])) {
                self.logViolation(.{
                    .event_id = generateUuid(),
                    .match_id = self.settings.match_id,
                    .player_id = @tagName(player_id),
                    .timestamp = std.time.timestamp(),
                    .violation = .{
                        .type = .macro_detected,
                        .severity = .warning,
                        .frame_number = frame_number,
                        .evidence = .{
                            .pattern_type = "repetitive",
                            .pattern_length = input_sequence_len,
                        },
                        .description = "Repetitive input pattern detected - possible macro usage",
                    },
                    .recommendation = "Review player input history for macro patterns",
                });
            }
        }
    }

    const input_sequence_len = 10;

    fn detectRepetitivePattern(seq1: []const u32, seq2: []const u32) bool {
        var match_count: u32 = 0;
        for (seq1, seq2) |a, b| {
            if (a == b) match_count += 1;
        }
        return match_count >= 8;
    }

    fn checkIllegalPositions(self: *Self, frame: *const model.Frame) void {
        for (frame.players, 0..) |player, i| {
            const player_id: model.PlayerId = if (i == 0) .player_1 else .player_2;
            if (player.collision_spheres == null and player.hurt_cylinders == null) continue;

            if (player.collision_spheres) |spheres| {
                const pos = spheres.get(.lower_torso).center;
                if (pos.x() < -50 or pos.x() > 50 or pos.y() < -50 or pos.y() > 50 or pos.z() < -20 or pos.z() > 20) {
                    self.logViolation(.{
                        .event_id = generateUuid(),
                        .match_id = self.settings.match_id,
                        .player_id = @tagName(player_id),
                        .timestamp = std.time.timestamp(),
                        .violation = .{
                            .type = .illegal_position,
                            .severity = .critical,
                            .frame_number = frame.frames_since_round_start orelse 0,
                            .evidence = .{
                                .position_x = pos.x(),
                                .position_y = pos.y(),
                                .position_z = pos.z(),
                            },
                            .description = "Player position outside valid game bounds",
                        },
                        .recommendation = "Investigate for teleportation exploit",
                    });
                }
            }
        }
    }

    fn logViolation(self: *Self, violation: ViolationEvent) void {
        self.violations.append(violation) catch {};
    }

    pub fn exportReport(self: *const Self) []const u8 {
        var buffer = std.ArrayList(u8).init(std.heap.page_allocator);
        var writer = buffer.writer();

        writer.print("{{\n", .{}) catch return "";
        writer.print("  \"match_id\": \"{s}\",\n", .{self.settings.match_id}) catch return "";
        writer.print("  \"violation_count\": {d},\n", .{self.violations.items.len}) catch return "";
        writer.print("  \"violations\": [\n", .{}) catch return "";

        for (self.violations.items, 0..) |violation, i| {
            writer.print("    {{\n", .{}) catch return "";
            writer.print("      \"event_id\": \"{s}\",\n", .{violation.event_id}) catch return "";
            writer.print("      \"player_id\": \"{s}\",\n", .{violation.player_id}) catch return "";
            writer.print("      \"timestamp\": {d},\n", .{violation.timestamp}) catch return "";
            writer.print("      \"violation\": {{\n", .{}) catch return "";
            writer.print("        \"type\": \"{s}\",\n", .{@tagName(violation.violation.type)}) catch return "";
            writer.print("        \"severity\": \"{s}\",\n", .{@tagName(violation.violation.severity)}) catch return "";
            writer.print("        \"frame_number\": {d},\n", .{violation.violation.frame_number}) catch return "";
            writer.print("        \"description\": \"{s}\"\n", .{violation.violation.description}) catch return "";
            writer.print("      }}\n", .{}) catch return "";
            writer.print("      \"recommendation\": \"{s}\"\n", .{violation.recommendation}) catch return "";
            writer.print("    }}", .{}) catch return "";
            if (i < self.violations.items.len - 1) writer.print(",", .{}) catch return "";
            writer.print("\n", .{}) catch return "";
        }

        writer.print("  ]\n", .{}) catch return "";
        writer.print("}}\n", .{}) catch return "";

        return buffer.toOwnedSlice();
    }

    pub fn clearViolations(self: *Self) void {
        self.violations.clearRetainingCapacity();
    }
};

pub const RefereeSettings = struct {
    enabled: bool = true,
    strictness: Strictness = .normal,
    match_id: []const u8 = "",
    violation_thresholds: ViolationThresholds = .{},
};

pub const Strictness = enum {
    lenient,
    normal,
    strict,
};

pub const ViolationThresholds = struct {
    min_input_interval: u32 = 1,
    max_macro_similarity: f32 = 0.8,
    check_exploits: bool = true,
};

pub const PlayerState = struct {
    previous_input: ?model.Input = null,
    frames_since_last_input: u32 = 0,
    input_sequence: [20]u32 = .{0} ** 20,
    input_index: usize = 0,
};

pub const ViolationType = enum {
    input_delay,
    macro_detected,
    exploit_used,
    illegal_position,
};

pub const ViolationSeverity = enum {
    info,
    warning,
    critical,
};

pub const ViolationEvent = struct {
    event_id: []const u8,
    match_id: []const u8,
    player_id: []const u8,
    timestamp: i64,
    violation: ViolationDetails,
    recommendation: []const u8,
};

pub const ViolationDetails = struct {
    type: ViolationType,
    severity: ViolationSeverity,
    frame_number: u32,
    evidence: ViolationEvidence,
    description: []const u8,
};

pub const ViolationEvidence = union {
    input_delay: InputDelayEvidence,
    macro: MacroEvidence,
    exploit: ExploitEvidence,
    position: PositionEvidence,
};

pub const InputDelayEvidence = struct {
    input_interval: u32,
    minimum_human_interval: u32,
};

pub const MacroEvidence = struct {
    pattern_type: []const u8,
    pattern_length: u32,
};

pub const ExploitEvidence = struct {
    exploit_name: []const u8,
    severity: []const u8,
};

pub const PositionEvidence = struct {
    position_x: f32,
    position_y: f32,
    position_z: f32,
};

fn generateUuid() []const u8 {
    var buffer: [36]u8 = undefined;
    const chars = "0123456789abcdef";
    var i: usize = 0;
    while (i < 36) : (i += 1) {
        const idx = @as(usize, @intFromFloat(std.math.random()*16.0));
        buffer[i] = if (i == 8 or i == 13 or i == 18 or i == 23) '-' else chars[idx];
    }
    return &buffer;
}

const testing = std.testing;

test "Referee.init should initialize correctly" {
    var referee = Referee.init(std.heap.page_allocator);
    defer referee.deinit();
    try testing.expectEqual(0, referee.violations.items.len);
    try testing.expectEqual(true, referee.settings.enabled);
}

test "Referee.tick should not crash with empty frame" {
    var referee = Referee.init(std.heap.page_allocator);
    defer referee.deinit();
    const frame = model.Frame{};
    referee.tick(&frame);
    try testing.expectEqual(0, referee.violations.items.len);
}

test "RefereeSettings should have correct defaults" {
    const settings = RefereeSettings{};
    try testing.expectEqual(false, settings.enabled);
    try testing.expectEqual(.normal, settings.strictness);
    try testing.expectEqual(1, settings.violation_thresholds.min_input_interval);
}

test "detectRepetitivePattern should detect repetitive sequences" {
    const seq1 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const seq2 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try testing.expectEqual(true, detectRepetitivePattern(&seq1, &seq2));
}

test "detectRepetitivePattern should not detect different sequences" {
    const seq1 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const seq2 = [_]u32{ 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    try testing.expectEqual(false, detectRepetitivePattern(&seq1, &seq2));
}

test "PlayerState should initialize correctly" {
    const state = PlayerState{};
    try testing.expectEqual(null, state.previous_input);
    try testing.expectEqual(0, state.frames_since_last_input);
    try testing.expectEqual(0, state.input_index);
}