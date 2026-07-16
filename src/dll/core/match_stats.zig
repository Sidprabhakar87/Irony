const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

/// Detailed match statistics analyzer for the AI Coach system.
/// Provides aggregate statistics from match frames for coaching insights.
pub const MatchStats = struct {
    allocator: std.mem.Allocator,
    total_frames: u32 = 0,
    rounds_played: u32 = 0,
    player_stats: PlayerStats = .{},
    opponent_stats: PlayerStats = .{},
    frame_advantage_trend: FrameAdvantageTrend = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Self) void {
        _ = self;
    }

    pub fn processFrame(self: *Self, frame: *const model.Frame, player_id: model.PlayerId) void {
        self.total_frames += 1;

        const player = frame.getPlayerById(player_id);
        const opponent = frame.getPlayerById(player_id.getOther());

        self.player_stats.processFrame(player, opponent);
        self.opponent_stats.processFrame(opponent, player);
        self.updateFrameAdvantage(player, opponent);
        self.detectRoundChange(player, opponent);
    }

    fn detectRoundChange(self: *Self, player: *const model.Player, opponent: *const model.Player) void {
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
            .rage_activations = stats.rage_activations,
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
    rage_activations: u32 = 0,
    move_frequencies: MoveFrequencies = .{},

    const SelfType = @This();

    pub fn processFrame(self: *SelfType, player: *const model.Player, opponent: *const model.Player) void {
        // Track attacks
        if (player.attack_type != null and player.attack_type != .not_attack) {
            self.total_attacks += 1;

            // Determine hit outcome
            if (opponent.hit_outcome != null and opponent.hit_outcome != .none) {
                self.total_hits += 1;
            } else if (opponent.blocking != null and opponent.blocking != .not_blocking) {
                self.total_blocked += 1;
            } else if (player.hit_lines.len == 0) {
                self.total_whiffs += 1;
            }
        }

        // Track damage via combo_damage
        if (player.combo_damage) |dmg| {
            if (dmg > self.total_damage_dealt) {
                self.total_damage_dealt = dmg;
            }
        }
        if (opponent.combo_damage) |dmg| {
            if (dmg > self.total_damage_taken) {
                self.total_damage_taken = dmg;
            }
        }

        // Track heat activations
        if (player.heat) |heat| {
            switch (heat) {
                .activated => self.heat_activations += 1,
                else => {},
            }
        }

        // Track rage activations
        if (player.rage) |rage| {
            switch (rage) {
                .activated => self.rage_activations += 1,
                else => {},
            }
        }

        // Track move frequencies
        if (player.animation_id) |anim_id| {
            self.move_frequencies.recordMove(anim_id);
        }
    }
};

pub const MoveFrequencies = struct {
    move_ids: [50]u32 = .{0} ** 50,
    frequencies: [50]u32 = .{0} ** 50,

    const SelfType = @This();

    pub fn recordMove(self: *SelfType, move_id: u32) void {
        for (self.move_ids, 0..) |existing_id, i| {
            if (existing_id == move_id) {
                self.frequencies[i] += 1;
                return;
            }
            if (self.frequencies[i] == 0) {
                self.move_ids[i] = move_id;
                self.frequencies[i] = 1;
                return;
            }
        }
    }

    pub fn getTopMoves(self: *const SelfType, max_count: usize) [10]u32 {
        var top: [10]u32 = .{0} ** 10;
        var top_freq: [10]u32 = .{0} ** 10;
        const limit = @min(max_count, 10);

        for (self.move_ids, 0..) |move_id, idx| {
            const freq = self.frequencies[idx];
            if (freq == 0) break;

            for (0..limit) |j| {
                if (freq > top_freq[j]) {
                    // Shift down
                    var k: usize = limit - 1;
                    while (k > j) : (k -= 1) {
                        top[k] = top[k - 1];
                        top_freq[k] = top_freq[k - 1];
                    }
                    top[j] = move_id;
                    top_freq[j] = freq;
                    break;
                }
            }
        }

        return top;
    }
};

pub const HeatRageStats = struct {
    heat_activations: u32 = 0,
    rage_activations: u32 = 0,
};

pub const FrameAdvantageTrend = struct {
    samples: [1000]i32 = .{0} ** 1000,
    sample_count: usize = 0,

    const SelfType = @This();

    pub fn addSample(self: *SelfType, advantage: i32) void {
        if (self.sample_count < self.samples.len) {
            self.samples[self.sample_count] = advantage;
            self.sample_count += 1;
        }
    }

    pub fn average(self: *const SelfType) i32 {
        if (self.sample_count == 0) return 0;
        var total: i64 = 0;
        for (self.samples[0..self.sample_count]) |sample| {
            total += sample;
        }
        return @intCast(@divTrunc(total, @as(i64, @intCast(self.sample_count))));
    }
};

pub const MoveCount = struct {
    total: u32 = 0,
    hits: u32 = 0,
    whiffs: u32 = 0,
    blocked: u32 = 0,
};

pub const DamageAnalysis = struct {
    damage_dealt: u32 = 0,
    damage_taken: u32 = 0,
    conversion_rate: f32 = 0,
    average_conversion: f32 = 0,
};

const testing = std.testing;

test "MatchStats.init should initialize correctly" {
    var stats = MatchStats.init(testing.allocator);
    defer stats.deinit();
    try testing.expectEqual(@as(u32, 0), stats.total_frames);
    try testing.expectEqual(@as(u32, 0), stats.rounds_played);
}

test "MoveFrequencies should track move frequencies" {
    var freqs = MoveFrequencies{};
    freqs.recordMove(100);
    freqs.recordMove(100);
    freqs.recordMove(200);
    try testing.expectEqual(@as(u32, 2), freqs.frequencies[0]);
    try testing.expectEqual(@as(u32, 100), freqs.move_ids[0]);
    try testing.expectEqual(@as(u32, 1), freqs.frequencies[1]);
    try testing.expectEqual(@as(u32, 200), freqs.move_ids[1]);
}

test "FrameAdvantageTrend should calculate average" {
    var trend = FrameAdvantageTrend{};
    trend.addSample(5);
    trend.addSample(10);
    trend.addSample(15);
    try testing.expectEqual(@as(i32, 10), trend.average());
}

test "FrameAdvantageTrend should handle empty samples" {
    const trend = FrameAdvantageTrend{};
    try testing.expectEqual(@as(i32, 0), trend.average());
}

test "MoveFrequencies.getTopMoves should return sorted results" {
    var freqs = MoveFrequencies{};
    freqs.recordMove(100);
    freqs.recordMove(200);
    freqs.recordMove(200);
    freqs.recordMove(300);
    freqs.recordMove(300);
    freqs.recordMove(300);
    const top = freqs.getTopMoves(3);
    try testing.expectEqual(@as(u32, 300), top[0]);
    try testing.expectEqual(@as(u32, 200), top[1]);
    try testing.expectEqual(@as(u32, 100), top[2]);
}
