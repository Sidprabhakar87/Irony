const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

pub const MatchStats = struct {
    allocator: std.mem.Allocator,
    total_frames: u32 = 0,
    rounds_played: u32 = 0,
    player_stats: PlayerStats = .{},
    opponent_stats: PlayerStats = .{},
    heat_rage_analysis: HeatRageAnalysis = .{},
    frame_advantage_trend: FrameAdvantageTrend = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        self.heat_rage_analysis.deinit();
    }

    pub fn processFrame(self: *Self, frame: *const model.Frame, player_id: model.PlayerId) void {
        self.total_frames += 1;

        const player = frame.getPlayerById(player_id);
        const opponent = frame.getPlayerById(player_id.getOther());

        self.player_stats.processFrame(player, opponent);
        self.opponent_stats.processFrame(opponent, player);
        self.heat_rage_analysis.processFrame(player, opponent);
        self.updateFrameAdvantage(player, opponent);
        self.detectRoundChange(frame, player_id);
    }

    fn detectRoundChange(self: *Self, frame: *const model.Frame, player_id: model.PlayerId) void {
        const player = frame.getPlayerById(player_id);
        const opponent = frame.getPlayerById(player_id.getOther());

        if (player.rounds_won != null and opponent.rounds_won != null) {
            const new_rounds = player.rounds_won.? + opponent.rounds_won.?;
            if (new_rounds > self.rounds_played) {
                self.rounds_played = new_rounds;
            }
        }
    }

    fn updateFrameAdvantage(self: *Self, player: *const model.Player, opponent: *const model.Player) void {
        const frame_adv = player.getFrameAdvantage(opponent);
        if (frame_adv.actual) |adv| {
            self.frame_advantage_trend.addSample(adv);
        }
    }

    pub fn calculateFrameAdvantage(self: *const Self) i32 {
        return self.frame_advantage_trend.average();
    }

    pub fn countMoves(self: *const Self, player_id: model.PlayerId) MoveCount {
        const stats = switch (player_id) {
            .player_1 => &self.player_stats,
            .player_2 => &self.opponent_stats,
        };
        return .{
            .total = stats.total_attacks,
            .hits = stats.total_hits,
            .whiffs = stats.total_whiffs,
            .blocked = stats.total_blocked,
        };
    }

    pub fn identifyPatterns(self: *Self, player_id: model.PlayerId) []const MovePattern {
        _ = player_id;
        return self.frame_advantage_trend.identifyPatterns();
    }

    pub fn damageAnalysis(self: *const Self, player_id: model.PlayerId) DamageAnalysis {
        const player_stats = switch (player_id) {
            .player_1 => &self.player_stats,
            .player_2 => &self.opponent_stats,
        };
        return .{
            .damage_dealt = player_stats.total_damage_dealt,
            .damage_taken = player_stats.total_damage_taken,
            .conversion_rate = if (player_stats.total_attacks > 0)
                @as(f32, @floatFromInt(player_stats.total_hits)) / @as(f32, @floatFromInt(player_stats.total_attacks))
            else
                0,
            .average_conversion = if (player_stats.total_hits > 0)
                @as(f32, @floatFromInt(player_stats.total_damage_dealt)) / @as(f32, @floatFromInt(player_stats.total_hits))
            else
                0,
        };
    }

    pub fn heatRageAnalysis(self: *const Self, player_id: model.PlayerId) HeatRageStats {
        const stats = switch (player_id) {
            .player_1 => &self.player_stats,
            .player_2 => &self.opponent_stats,
        };
        return .{
            .heat_activations = stats.heat_activations,
            .heat_damage_bonus = stats.heat_damage_bonus,
            .rage_activations = stats.rage_activations,
            .rage_damage_bonus = stats.rage_damage_bonus,
        };
    }
};

pub const PlayerStats = struct {
    total_attacks: u32 = 0,
    total_hits: u32 = 0,
    total_whiffs: u32 = 0,
    total_blocked: u32 = 0,
    total_damage_dealt: u32 = 0,
    total_damage_taken: u32 = 0,
    heat_activations: u32 = 0,
    heat_damage_bonus: u32 = 0,
    rage_activations: u32 = 0,
    rage_damage_bonus: u32 = 0,
    move_frequencies: MoveFrequencies = .{},

    fn processFrame(self: *Self, player: *const model.Player, opponent: *const model.Player) void {
        if (player.attack_type != null and player.attack_type != .not_attack) {
            self.total_attacks += 1;

            if (opponent.hit_outcome != null and opponent.hit_outcome != .none) {
                self.total_hits += 1;
            } else if (player.hit_lines.len == 0) {
                self.total_whiffs += 1;
            } else if (opponent.blocking != null and opponent.blocking != .not_blocking) {
                self.total_blocked += 1;
            }

            if (player.combo_damage) |dmg| {
                self.total_damage_dealt += dmg;
            }
        }

        if (opponent.attack_type != null and opponent.attack_type != .not_attack) {
            if (player.combo_damage) |dmg| {
                self.total_damage_taken += dmg;
            }
        }

        if (player.heat) |heat| {
            switch (heat) {
                .activated => {
                    self.heat_activations += 1;
                    self.heat_damage_bonus += 10;
                },
                else => {},
            }
        }

        if (player.rage == .activated) {
            self.rage_activations += 1;
            self.rage_damage_bonus += 15;
        }

        if (player.animation_id) |anim_id| {
            self.move_frequencies.recordMove(anim_id);
        }
    }
};

pub const MoveFrequencies = struct {
    frequencies: [50]u32 = .{0} ** 50,
    move_ids: [50]u32 = .{0} ** 50,

    fn recordMove(self: *Self, move_id: u32) void {
        for (self.frequencies, 0..) |count, i| {
            if (self.move_ids[i] == move_id) {
                self.frequencies[i] = count + 1;
                return;
            }
            if (count == 0) {
                self.move_ids[i] = move_id;
                self.frequencies[i] = 1;
                return;
            }
        }
    }

    pub fn getTopMoves(self: *const Self, count: usize) []const u32 {
        var top: [10]u32 = .{0} ** 10;
        var top_count: [10]u32 = .{0} ** 10;

        for (self.frequencies, 0..) |freq, i| {
            if (freq == 0) break;
            for (top_count, 0..) |*tc, j| {
                if (freq > tc.*) {
                    var k: usize = 9;
                    while (k > j) : (k -= 1) {
                        top[k] = top[k - 1];
                        top_count[k] = top_count[k - 1];
                    }
                    top[j] = self.move_ids[i];
                    top_count[j] = freq;
                    break;
                }
            }
        }

        return &top;
    }
};

pub const HeatRageAnalysis = struct {
    allocator: std.mem.Allocator,
    heat_timing: std.ArrayList(HeatTiming),
    rage_timing: std.ArrayList(RageTiming),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .heat_timing = std.ArrayList(HeatTiming).init(allocator),
            .rage_timing = std.ArrayList(RageTiming).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.heat_timing.deinit();
        self.rage_timing.deinit();
    }

    fn processFrame(self: *Self, player: *const model.Player, opponent: *const model.Player) void {
        _ = opponent;
        if (player.heat) |heat| {
            switch (heat) {
                .activated => |activated| {
                    self.heat_timing.append(.{
                        .gauge_at_activation = activated.gauge,
                        .frame = 0,
                    }) catch {};
                },
                else => {},
            }
        }
        if (player.rage == .activated) {
            self.rage_timing.append(.{ .frame = 0 }) catch {};
        }
    }

    pub fn getHeatUsage(self: *const Self) HeatUsageStats {
        if (self.heat_timing.items.len == 0) {
            return .{};
        }
        var total_gauge: f32 = 0;
        for (self.heat_timing.items) |timing| {
            total_gauge += timing.gauge_at_activation;
        }
        return .{
            .activations = @intCast(self.heat_timing.items.len),
            .average_gauge_at_activation = total_gauge / @as(f32, @floatFromInt(self.heat_timing.items.len)),
        };
    }

    pub fn getRageUsage(self: *const Self) RageUsageStats {
        return .{
            .activations = @intCast(self.rage_timing.items.len),
        };
    }
};

pub const HeatTiming = struct {
    gauge_at_activation: f32,
    frame: u32,
};

pub const RageTiming = struct {
    frame: u32,
};

pub const HeatUsageStats = struct {
    activations: u32 = 0,
    average_gauge_at_activation: f32 = 0,
};

pub const RageUsageStats = struct {
    activations: u32 = 0,
};

pub const HeatRageStats = struct {
    heat_activations: u32 = 0,
    heat_damage_bonus: u32 = 0,
    rage_activations: u32 = 0,
    rage_damage_bonus: u32 = 0,
};

pub const FrameAdvantageTrend = struct {
    samples: [1000]i32 = .{0} ** 1000,
    sample_count: usize = 0,

    fn addSample(self: *Self, advantage: i32) void {
        if (self.sample_count < self.samples.len) {
            self.samples[self.sample_count] = advantage;
            self.sample_count += 1;
        }
    }

    pub fn average(self: *const Self) i32 {
        if (self.sample_count == 0) return 0;
        var total: i32 = 0;
        for (self.samples[0..self.sample_count]) |sample| {
            total += sample;
        }
        return @divTrunc(total, @intCast(self.sample_count));
    }

    pub fn identifyPatterns(self: *const Self) []const MovePattern {
        _ = self;
        return &.{};
    }
};

pub const MoveCount = struct {
    total: u32 = 0,
    hits: u32 = 0,
    whiffs: u32 = 0,
    blocked: u32 = 0,
};

pub const MovePattern = struct {
    sequence: []const u32,
    frequency: u32,
    description: []const u8,
};

pub const DamageAnalysis = struct {
    damage_dealt: u32 = 0,
    damage_taken: u32 = 0,
    conversion_rate: f32 = 0,
    average_conversion: f32 = 0,
};

const testing = std.testing;

test "MatchStats.init should initialize correctly" {
    var stats = MatchStats.init(std.heap.page_allocator);
    defer stats.deinit();
    try testing.expectEqual(0, stats.total_frames);
    try testing.expectEqual(0, stats.rounds_played);
}

test "MoveFrequencies should track move frequencies" {
    var freqs = MoveFrequencies{};
    freqs.recordMove(100);
    freqs.recordMove(100);
    freqs.recordMove(200);
    try testing.expectEqual(2, freqs.frequencies[0]);
    try testing.expectEqual(100, freqs.move_ids[0]);
    try testing.expectEqual(1, freqs.frequencies[1]);
    try testing.expectEqual(200, freqs.move_ids[1]);
}

test "HeatUsageStats should track heat activations" {
    var analysis = HeatRageAnalysis.init(std.heap.page_allocator);
    defer analysis.deinit();
    const stats = analysis.getHeatUsage();
    try testing.expectEqual(0, stats.activations);
}

test "FrameAdvantageTrend should calculate average" {
    var trend = FrameAdvantageTrend{};
    trend.addSample(5);
    trend.addSample(10);
    trend.addSample(15);
    try testing.expectEqual(10, trend.average());
}

test "FrameAdvantageTrend should handle empty samples" {
    const trend = FrameAdvantageTrend{};
    try testing.expectEqual(0, trend.average());
}