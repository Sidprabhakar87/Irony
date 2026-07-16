const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

pub const Referee = struct {
    player_1_state: PlayerState = .{},
    player_2_state: PlayerState = .{},
    violations: std.ArrayList(ViolationEvent),
    settings: model.RefereeSettings = .{},
    violation_counter: u64 = 0,

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
        const frame_number = frame.frames_since_round_start orelse 0;
        self.checkInputDelay(&frame.players[0], .player_1, frame_number);
        self.checkInputDelay(&frame.players[1], .player_2, frame_number);
        self.checkMacroUsage(&frame.players[0], .player_1, frame_number);
        self.checkMacroUsage(&frame.players[1], .player_2, frame_number);
        self.checkIllegalPositions(frame);
    }

    fn checkInputDelay(self: *Self, player: *const model.Player, player_id: model.PlayerId, frame_number: u32) void {
        const state = switch (player_id) {
            .player_1 => &self.player_1_state,
            .player_2 => &self.player_2_state,
        };

        if (player.input == null) return;
        const current_input = player.input.?;

        if (state.previous_input) |prev| {
            const input_changed = hasInputChanged(prev, current_input);

            if (input_changed) {
                // Track rapid input changes - only flag if we see multiple
                // distinct input changes within an impossibly short window
                state.rapid_change_count += 1;

                if (state.frames_since_last_input == 0 and state.rapid_change_count >= getMinInputThreshold(self.settings.strictness)) {
                    // Multiple distinct inputs in the same frame - physically impossible
                    self.logViolation(.{
                        .event_id = self.nextViolationId(),
                        .match_id = self.settings.match_id,
                        .player_id = @tagName(player_id),
                        .timestamp = std.time.timestamp(),
                        .violation = .{
                            .violation_type = .input_delay,
                            .severity = .warning,
                            .frame_number = frame_number,
                            .evidence = .{ .input_delay = .{
                                .input_interval = 0,
                                .minimum_human_interval = self.settings.violation_thresholds.min_input_interval,
                                .rapid_change_count = state.rapid_change_count,
                            } },
                            .description = "Multiple distinct inputs detected within same frame",
                        },
                        .recommendation = "Monitor player for continued suspicious inputs",
                    });
                }

                state.frames_since_last_input = 0;
            } else {
                state.frames_since_last_input += 1;
                // Reset rapid change counter after a gap of normal frames
                if (state.frames_since_last_input > 3) {
                    state.rapid_change_count = 0;
                }
            }
        }

        state.previous_input = current_input;
    }

    fn getMinInputThreshold(strictness: model.RefereeSettings.Strictness) u32 {
        return switch (strictness) {
            .lenient => 5,
            .normal => 3,
            .strict => 2,
        };
    }

    fn hasInputChanged(prev: model.Input, current: model.Input) bool {
        // Count the number of buttons that changed state
        var changes: u32 = 0;
        if (prev.forward != current.forward) changes += 1;
        if (prev.back != current.back) changes += 1;
        if (prev.up != current.up) changes += 1;
        if (prev.down != current.down) changes += 1;
        if (prev.left != current.left) changes += 1;
        if (prev.right != current.right) changes += 1;
        if (prev.button_1 != current.button_1) changes += 1;
        if (prev.button_2 != current.button_2) changes += 1;
        if (prev.button_3 != current.button_3) changes += 1;
        if (prev.button_4 != current.button_4) changes += 1;
        if (prev.special_style != current.special_style) changes += 1;
        if (prev.rage != current.rage) changes += 1;
        if (prev.heat != current.heat) changes += 1;
        return changes > 0;
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
        const anim_id = player.animation_id.?;

        // Only record when animation changes (not every frame of the same animation)
        if (state.last_recorded_animation == anim_id) return;
        state.last_recorded_animation = anim_id;

        state.input_sequence[state.input_index % input_sequence_len] = anim_id;
        state.input_index += 1;

        // Need at least 2 full sequences to compare
        if (state.input_index >= input_sequence_len * 2) {
            if (detectRepetitivePattern(
                state.input_sequence[0..input_sequence_len],
                state.input_sequence[input_sequence_len..],
            )) {
                const threshold: f32 = self.settings.violation_thresholds.max_macro_similarity;
                _ = threshold;

                self.logViolation(.{
                    .event_id = self.nextViolationId(),
                    .match_id = self.settings.match_id,
                    .player_id = @tagName(player_id),
                    .timestamp = std.time.timestamp(),
                    .violation = .{
                        .violation_type = .macro_detected,
                        .severity = .warning,
                        .frame_number = frame_number,
                        .evidence = .{ .macro = .{
                            .pattern_type = "repetitive_sequence",
                            .pattern_length = input_sequence_len,
                            .similarity = 0.8,
                        } },
                        .description = "Repetitive input pattern detected - possible macro usage",
                    },
                    .recommendation = "Review player input history for macro patterns",
                });

                // Reset after detection to avoid spam
                state.input_index = 0;
            }
        }
    }

    const input_sequence_len: usize = 10;

    fn detectRepetitivePattern(seq1: []const u32, seq2: []const u32) bool {
        if (seq1.len != seq2.len) return false;
        var match_count: u32 = 0;
        for (seq1, seq2) |a, b| {
            if (a == b) match_count += 1;
        }
        // Require 80% similarity for macro detection
        return match_count >= (seq1.len * 8 / 10);
    }

    fn checkIllegalPositions(self: *Self, frame: *const model.Frame) void {
        if (!self.settings.violation_thresholds.check_exploits) return;

        for (frame.players, 0..) |player, i| {
            const player_id: model.PlayerId = if (i == 0) .player_1 else .player_2;
            if (player.collision_spheres == null) continue;

            if (player.collision_spheres) |*spheres| {
                const pos = spheres.get(.lower_torso).center;
                // Tekken 8 stages have variable sizes, use generous bounds
                // These values represent clearly impossible positions (meters)
                const bound_xy: f32 = 100.0;
                const bound_z_min: f32 = -30.0;
                const bound_z_max: f32 = 50.0;

                if (pos.x() < -bound_xy or pos.x() > bound_xy or
                    pos.y() < -bound_xy or pos.y() > bound_xy or
                    pos.z() < bound_z_min or pos.z() > bound_z_max)
                {
                    self.logViolation(.{
                        .event_id = self.nextViolationId(),
                        .match_id = self.settings.match_id,
                        .player_id = @tagName(player_id),
                        .timestamp = std.time.timestamp(),
                        .violation = .{
                            .violation_type = .illegal_position,
                            .severity = .critical,
                            .frame_number = frame.frames_since_round_start orelse 0,
                            .evidence = .{ .position = .{
                                .position_x = pos.x(),
                                .position_y = pos.y(),
                                .position_z = pos.z(),
                            } },
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

    fn nextViolationId(self: *Self) [36]u8 {
        // Generate a deterministic pseudo-unique ID based on counter
        self.violation_counter += 1;
        var buffer: [36]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        var counter = self.violation_counter;

        // Format as UUID-like string: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
        var pos: usize = 0;
        while (pos < 36) : (pos += 1) {
            if (pos == 8 or pos == 13 or pos == 18 or pos == 23) {
                buffer[pos] = '-';
            } else {
                buffer[pos] = hex_chars[@as(usize, @intCast(counter & 0xF))];
                counter >>= 4;
                if (counter == 0) counter = self.violation_counter *% 6364136223846793005 +% pos;
            }
        }
        return buffer;
    }

    pub fn exportReport(self: *const Self, allocator: std.mem.Allocator) []const u8 {
        var buffer = std.ArrayList(u8).init(allocator);
        const writer = buffer.writer();

        writer.print("{{\n", .{}) catch return "";
        writer.print("  \"match_id\": \"{s}\",\n", .{self.settings.match_id}) catch return "";
        writer.print("  \"violation_count\": {d},\n", .{self.violations.items.len}) catch return "";
        writer.print("  \"violations\": [\n", .{}) catch return "";

        for (self.violations.items, 0..) |violation, i| {
            writer.print("    {{\n", .{}) catch return "";
            writer.print("      \"event_id\": \"{s}\",\n", .{&violation.event_id}) catch return "";
            writer.print("      \"player_id\": \"{s}\",\n", .{violation.player_id}) catch return "";
            writer.print("      \"timestamp\": {d},\n", .{violation.timestamp}) catch return "";
            writer.print("      \"violation\": {{\n", .{}) catch return "";
            writer.print("        \"type\": \"{s}\",\n", .{@tagName(violation.violation.violation_type)}) catch return "";
            writer.print("        \"severity\": \"{s}\",\n", .{@tagName(violation.violation.severity)}) catch return "";
            writer.print("        \"frame_number\": {d},\n", .{violation.violation.frame_number}) catch return "";
            writer.print("        \"description\": \"{s}\"\n", .{violation.violation.description}) catch return "";
            writer.print("      }},\n", .{}) catch return "";
            writer.print("      \"recommendation\": \"{s}\"\n", .{violation.recommendation}) catch return "";
            writer.print("    }}", .{}) catch return "";
            if (i < self.violations.items.len - 1) writer.print(",", .{}) catch return "";
            writer.print("\n", .{}) catch return "";
        }

        writer.print("  ]\n", .{}) catch return "";
        writer.print("}}\n", .{}) catch return "";

        return buffer.toOwnedSlice() catch "";
    }

    pub fn getViolationCount(self: *const Self) usize {
        return self.violations.items.len;
    }

    pub fn clearViolations(self: *Self) void {
        self.violations.clearRetainingCapacity();
        self.player_1_state = .{};
        self.player_2_state = .{};
    }
};

pub const PlayerState = struct {
    previous_input: ?model.Input = null,
    frames_since_last_input: u32 = 0,
    rapid_change_count: u32 = 0,
    input_sequence: [20]u32 = .{0} ** 20,
    input_index: usize = 0,
    last_recorded_animation: u32 = 0,
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
    event_id: [36]u8,
    match_id: []const u8,
    player_id: []const u8,
    timestamp: i64,
    violation: ViolationDetails,
    recommendation: []const u8,
};

pub const ViolationDetails = struct {
    violation_type: ViolationType,
    severity: ViolationSeverity,
    frame_number: u32,
    evidence: ViolationEvidence,
    description: []const u8,
};

pub const ViolationEvidence = union(ViolationEvidenceTag) {
    input_delay: InputDelayEvidence,
    macro: MacroEvidence,
    exploit: ExploitEvidence,
    position: PositionEvidence,
};

pub const ViolationEvidenceTag = enum {
    input_delay,
    macro,
    exploit,
    position,
};

pub const InputDelayEvidence = struct {
    input_interval: u32,
    minimum_human_interval: u32,
    rapid_change_count: u32 = 0,
};

pub const MacroEvidence = struct {
    pattern_type: []const u8,
    pattern_length: usize,
    similarity: f32 = 0,
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

const testing = std.testing;

test "Referee.init should initialize correctly" {
    var referee = Referee.init(testing.allocator);
    defer referee.deinit();
    try testing.expectEqual(@as(usize, 0), referee.violations.items.len);
    try testing.expectEqual(false, referee.settings.enabled);
}

test "Referee.tick should not crash with empty frame" {
    var referee = Referee.init(testing.allocator);
    defer referee.deinit();
    const frame = model.Frame{};
    referee.tick(&frame);
    // Empty frame has no inputs, so no violations should be generated
    try testing.expectEqual(@as(usize, 0), referee.violations.items.len);
}

test "RefereeSettings should have correct defaults" {
    const settings = model.RefereeSettings{};
    try testing.expectEqual(false, settings.enabled);
    try testing.expectEqual(.normal, settings.strictness);
    try testing.expectEqual(@as(u32, 1), settings.violation_thresholds.min_input_interval);
}

test "detectRepetitivePattern should detect repetitive sequences" {
    const seq1 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const seq2 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    try testing.expectEqual(true, Referee.detectRepetitivePattern(&seq1, &seq2));
}

test "detectRepetitivePattern should not detect different sequences" {
    const seq1 = [_]u32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    const seq2 = [_]u32{ 10, 9, 8, 7, 6, 5, 4, 3, 2, 1 };
    try testing.expectEqual(false, Referee.detectRepetitivePattern(&seq1, &seq2));
}

test "PlayerState should initialize correctly" {
    const state = PlayerState{};
    try testing.expectEqual(@as(?model.Input, null), state.previous_input);
    try testing.expectEqual(@as(u32, 0), state.frames_since_last_input);
    try testing.expectEqual(@as(usize, 0), state.input_index);
}

test "hasInputChanged should detect input changes" {
    const input_a = model.Input{ .forward = true };
    const input_b = model.Input{ .forward = false };
    const input_c = model.Input{ .forward = true };
    try testing.expectEqual(true, Referee.hasInputChanged(input_a, input_b));
    try testing.expectEqual(false, Referee.hasInputChanged(input_a, input_c));
}
