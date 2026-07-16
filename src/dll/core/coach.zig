const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

pub const MaxMoveIds = 50;

pub const Coach = struct {
    const Self = @This();

    /// Analyzes a recorded match replay and returns comprehensive coaching insights.
    /// This is the primary entry point for post-match analysis.
    pub fn analyzeReplay(allocator: std.mem.Allocator, frames: []const model.Frame, player_id: model.PlayerId) MatchAnalysis {
        var analysis = MatchAnalysis{};
        if (frames.len == 0) return analysis;

        var player_tendency = PlayerTendency{};
        var opponent_tendency = PlayerTendency{};
        var match_stats = MatchStats{};
        var missed_punishments: std.ArrayList(PunishOpportunity) = .empty;

        var iter = FrameIterator.init(frames, player_id);
        while (iter.next()) |state| {
            match_stats.processFrame(state.frame, state.player, state.opponent);
            profilePlayerTendency(&player_tendency, state.player, state.opponent);
            profilePlayerTendency(&opponent_tendency, state.opponent, state.player);

            // Check if opponent is in recovery and player missed a punish
            if (state.opponent.move_phase == .recovery) {
                if (findMissedPunishment(state.frame, state.player, state.opponent)) |punish| {
                    missed_punishments.append(allocator, punish) catch {};
                }
            }
        }

        analysis.missed_punishments = missed_punishments.toOwnedSlice(allocator) catch &.{};
        analysis.player_tendency = player_tendency;
        analysis.opponent_tendency = opponent_tendency;
        analysis.match_stats = match_stats;
        analysis.opponent_tendency.playstyle = determinePlaystyle(&opponent_tendency);
        return analysis;
    }

    fn findMissedPunishment(frame: *const model.Frame, player: *const model.Player, opponent: *const model.Player) ?PunishOpportunity {
        // Player is in neutral (not attacking) while opponent is in recovery
        if (player.move_phase != .neutral and player.move_phase != null) return null;
        if (opponent.move_phase != .recovery) return null;
        // Player didn't use an attack to punish
        if (player.attack_type != null and player.attack_type != .not_attack) return null;

        const opponent_recovery = opponent.getRecoveryFrames();
        // Only flag if the recovery window is large enough to punish (10+ frames)
        if (opponent_recovery.actual == null) return null;
        if (opponent_recovery.actual.? < 10) return null;

        // Calculate frame advantage using proper API
        const frame_adv = opponent.getFrameAdvantage(player);

        return .{
            .frame_number = frame.frames_since_round_start orelse 0,
            .opponent_frame_advantage = frame_adv,
            .opponent_recovery_frames = opponent_recovery,
            .player_used_move = player.animation_id,
            .impact = categorizePunishImpact(opponent_recovery.actual.?),
        };
    }

    fn categorizePunishImpact(recovery_frames: u32) PunishImpact {
        return switch (recovery_frames) {
            0...9 => .low,
            10...14 => .medium,
            15...19 => .high,
            else => .critical,
        };
    }

    fn profilePlayerTendency(
        tendency: *PlayerTendency,
        player_frame: *const model.Player,
        opponent_frame: *const model.Player,
    ) void {
        if (player_frame.animation_id) |anim_id| {
            recordMoveFrequency(tendency, anim_id);
        }

        // Track punish attempts: player attacks while opponent is in recovery
        if (opponent_frame.move_phase == .recovery) {
            if (player_frame.attack_type != null and player_frame.attack_type != .not_attack) {
                tendency.punish_attempts += 1;
            }
        }

        if (player_frame.blocking != null and player_frame.blocking != .not_blocking) {
            tendency.blocks += 1;
        }

        if (player_frame.heat) |heat| {
            switch (heat) {
                .activated => tendency.heat_activations += 1,
                else => {},
            }
        }

        if (player_frame.rage) |rage| {
            switch (rage) {
                .activated => tendency.rage_activations += 1,
                else => {},
            }
        }

        if (player_frame.crushing) |crush| {
            if (crush.high_crushing) tendency.high_crush_count += 1;
            if (crush.low_crushing) tendency.low_crush_count += 1;
        }

        tendency.total_frames += 1;
    }

    fn recordMoveFrequency(tendency: *PlayerTendency, anim_id: u32) void {
        for (tendency.move_ids, 0..) |existing_id, i| {
            if (existing_id == anim_id) {
                tendency.move_frequency[i] += 1;
                return;
            }
            if (tendency.move_frequency[i] == 0) {
                tendency.move_ids[i] = anim_id;
                tendency.move_frequency[i] = 1;
                return;
            }
        }
        // Array full, ignore additional moves
    }

    /// Identifies all punish opportunities in a replay, both taken and missed.
    pub fn identifyOptimalPunishments(
        allocator: std.mem.Allocator,
        frames: []const model.Frame,
        player_id: model.PlayerId,
    ) []const PunishOpportunity {
        var opportunities: std.ArrayList(PunishOpportunity) = .empty;

        var iter = FrameIterator.init(frames, player_id);
        while (iter.next()) |state| {
            if (state.opponent.move_phase != .recovery) continue;

            const recovery = state.opponent.getRecoveryFrames();
            if (recovery.actual == null) continue;
            if (recovery.actual.? < 10) continue;

            const frame_adv = state.opponent.getFrameAdvantage(state.player);
            const optimal_move = findOptimalPunishMove(recovery.actual.?);

            opportunities.append(allocator, .{
                .frame_number = state.frame.frames_since_round_start orelse 0,
                .opponent_frame_advantage = frame_adv,
                .opponent_recovery_frames = recovery,
                .player_used_move = state.player.animation_id,
                .impact = categorizePunishImpact(recovery.actual.?),
                .optimal_punish_move = optimal_move,
            }) catch {};
        }

        return opportunities.toOwnedSlice(allocator) catch &.{};
    }

    fn findOptimalPunishMove(recovery_frames: u32) ?u32 {
        // Returns the fastest startup frame punish available
        // These are generic Tekken 8 frame data values (i-frames for jabs/punishes)
        return switch (recovery_frames) {
            0...9 => null, // Not punishable
            10...11 => 10, // i10 jab punish
            12...13 => 12, // i12 punish (e.g., 2,1)
            14...15 => 14, // i14 punish (e.g., df2)
            16...17 => 15, // i15 launcher
            else => 15, // Full launch punish
        };
    }

    /// Profiles an opponent's play style from replay data.
    pub fn profileOpponentStyle(
        allocator: std.mem.Allocator,
        frames: []const model.Frame,
        player_id: model.PlayerId,
    ) PlayerTendency {
        _ = allocator;
        var tendency = PlayerTendency{};
        const opponent_id = player_id.getOther();

        var iter = FrameIterator.init(frames, opponent_id);
        while (iter.next()) |state| {
            // In this context, state.player IS the opponent (since we pass opponent_id)
            profilePlayerTendency(&tendency, state.player, state.opponent);
        }

        tendency.playstyle = determinePlaystyle(&tendency);
        return tendency;
    }

    fn determinePlaystyle(tendency: *const PlayerTendency) Playstyle {
        if (tendency.total_frames == 0) return .neutral;

        const total_moves: u32 = blk: {
            var total: u32 = 0;
            for (tendency.move_frequency) |count| total += count;
            break :blk total;
        };
        if (total_moves == 0) return .neutral;

        const offensive_ratio = @as(f32, @floatFromInt(tendency.punish_attempts)) / @as(f32, @floatFromInt(total_moves));
        const block_ratio = @as(f32, @floatFromInt(tendency.blocks)) / @as(f32, @floatFromInt(tendency.total_frames));

        if (offensive_ratio > 0.3) return .aggressive;
        if (block_ratio > 0.4) return .defensive;
        if (tendency.high_crush_count > 10 or tendency.low_crush_count > 10) return .poke_heavy;
        return .neutral;
    }

    /// Generates counter-strategy recommendations based on opponent tendencies.
    pub fn generateStrategyGuide(
        allocator: std.mem.Allocator,
        frames: []const model.Frame,
        player_id: model.PlayerId,
    ) []const StrategyRecommendation {
        var recommendations: std.ArrayList(StrategyRecommendation) = .empty;

        const opponent_tendency = profileOpponentStyle(allocator, frames, player_id);

        // Generate recommendations based on playstyle
        switch (opponent_tendency.playstyle) {
            .aggressive => {
                recommendations.append(allocator, .{
                    .situation = "Opponent plays aggressively with frequent attacks",
                    .counter = "Use backdash into whiff punish or power crush moves",
                    .risk = .medium,
                    .frame_advantage_on_hit = "+15 on launcher",
                    .reason = "Aggressive players overcommit - punish their whiffs",
                }) catch {};
            },
            .defensive => {
                recommendations.append(allocator, .{
                    .situation = "Opponent blocks frequently and waits for punishes",
                    .counter = "Use throws and frame traps to open them up",
                    .risk = .low,
                    .frame_advantage_on_hit = "+0 (throw damage)",
                    .reason = "Defensive players are vulnerable to throws and pressure resets",
                }) catch {};
            },
            .poke_heavy => {
                recommendations.append(allocator, .{
                    .situation = "Opponent relies on pokes and crush moves",
                    .counter = "Use mids to beat high crushes, block and punish lows",
                    .risk = .low,
                    .frame_advantage_on_hit = "variable",
                    .reason = "Poke-heavy players can be beaten with patient mid-checking",
                }) catch {};
            },
            .neutral => {
                recommendations.append(allocator, .{
                    .situation = "Opponent plays balanced/neutral game",
                    .counter = "Focus on fundamentals: spacing, whiff punish, and frame advantage",
                    .risk = .medium,
                    .frame_advantage_on_hit = "variable",
                    .reason = "Balanced opponents require solid fundamentals to beat",
                }) catch {};
            },
        }

        // Add move-specific recommendations based on opponent's favorite moves
        const favorite_moves = getFavoriteMoves(&opponent_tendency);
        for (favorite_moves) |_| {
            recommendations.append(allocator, .{
                .situation = "Opponent frequently uses this move pattern",
                .counter = "Prepare punish with fastest available option",
                .risk = .medium,
                .frame_advantage_on_hit = "+varies",
                .reason = "Opponent frequently uses this move - prepare a punish",
            }) catch {};
        }

        return recommendations.toOwnedSlice(allocator) catch &.{};
    }

    pub fn getFavoriteMoves(tendency: *const PlayerTendency) [5]u32 {
        var result: [5]u32 = .{ 0, 0, 0, 0, 0 };
        var result_counts: [5]u32 = .{ 0, 0, 0, 0, 0 };

        for (tendency.move_ids, 0..) |move_id, idx| {
            const count = tendency.move_frequency[idx];
            if (count == 0) break;

            // Insert into sorted top-5
            for (&result_counts, 0..) |*rc, j| {
                if (count > rc.*) {
                    // Shift down
                    var k: usize = 4;
                    while (k > j) : (k -= 1) {
                        result[k] = result[k - 1];
                        result_counts[k] = result_counts[k - 1];
                    }
                    result[j] = move_id;
                    result_counts[j] = count;
                    break;
                }
            }
        }

        return result;
    }
};

// ============================================================================
// Frame Iterator - correctly respects player_id
// ============================================================================

pub const FrameIterator = struct {
    frames: []const model.Frame,
    player_id: model.PlayerId,
    index: usize = 0,

    pub const FrameState = struct {
        frame: *const model.Frame,
        player: *const model.Player,
        opponent: *const model.Player,
    };

    pub fn init(frames: []const model.Frame, player_id: model.PlayerId) FrameIterator {
        return .{
            .frames = frames,
            .player_id = player_id,
        };
    }

    pub fn next(self: *FrameIterator) ?FrameState {
        if (self.index >= self.frames.len) return null;
        const frame = &self.frames[self.index];
        self.index += 1;
        return FrameState{
            .frame = frame,
            .player = frame.getPlayerById(self.player_id),
            .opponent = frame.getPlayerById(self.player_id.getOther()),
        };
    }

    pub fn reset(self: *FrameIterator) void {
        self.index = 0;
    }
};

// ============================================================================
// Data Types
// ============================================================================

pub const PlayerTendency = struct {
    playstyle: Playstyle = .neutral,
    move_ids: [MaxMoveIds]u32 = .{0} ** MaxMoveIds,
    move_frequency: [MaxMoveIds]u32 = .{0} ** MaxMoveIds,
    punish_attempts: u32 = 0,
    blocks: u32 = 0,
    heat_activations: u32 = 0,
    rage_activations: u32 = 0,
    high_crush_count: u32 = 0,
    low_crush_count: u32 = 0,
    total_frames: u32 = 0,
};

pub const MatchAnalysis = struct {
    missed_punishments: []const PunishOpportunity = &.{},
    player_tendency: PlayerTendency = .{},
    opponent_tendency: PlayerTendency = .{},
    match_stats: MatchStats = .{},
};

pub const PunishOpportunity = struct {
    frame_number: u32,
    opponent_frame_advantage: model.I32ActualMinMax = model.I32ActualMinMax.nulls,
    opponent_recovery_frames: model.U32ActualMinMax = model.U32ActualMinMax.nulls,
    player_used_move: ?u32 = null,
    impact: PunishImpact = .medium,
    optimal_punish_move: ?u32 = null,
};

pub const PunishImpact = enum {
    low,
    medium,
    high,
    critical,
};

pub const Playstyle = enum {
    aggressive,
    defensive,
    poke_heavy,
    neutral,
};

pub const StrategyRecommendation = struct {
    situation: []const u8,
    counter: []const u8,
    risk: RiskLevel = .medium,
    frame_advantage_on_hit: []const u8,
    reason: []const u8 = "",
};

pub const RiskLevel = enum {
    low,
    medium,
    high,
};

pub const MatchStats = struct {
    total_frames: u32 = 0,
    rounds_played: u32 = 0,
    player_damage_dealt: u32 = 0,
    player_damage_taken: u32 = 0,
    player_heat_uses: u32 = 0,
    player_rage_uses: u32 = 0,
    player_rounds_won: u32 = 0,
    opponent_rounds_won: u32 = 0,

    pub fn processFrame(self: *MatchStats, frame: *const model.Frame, player: *const model.Player, opponent: *const model.Player) void {
        _ = frame;
        self.total_frames += 1;

        // Track damage via combo_damage field
        if (player.combo_damage) |dmg| {
            if (dmg > self.player_damage_dealt) {
                self.player_damage_dealt = dmg;
            }
        }
        if (opponent.combo_damage) |dmg| {
            if (dmg > self.player_damage_taken) {
                self.player_damage_taken = dmg;
            }
        }

        // Track heat/rage usage
        if (player.heat) |heat| {
            switch (heat) {
                .activated => self.player_heat_uses += 1,
                else => {},
            }
        }
        if (player.rage) |rage| {
            switch (rage) {
                .activated => self.player_rage_uses += 1,
                else => {},
            }
        }

        // Track rounds won
        if (player.rounds_won) |won| {
            self.player_rounds_won = won;
        }
        if (opponent.rounds_won) |won| {
            self.opponent_rounds_won = won;
        }
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Coach.analyzeReplay should handle empty frames" {
    const result = Coach.analyzeReplay(testing.allocator, &.{}, .player_1);
    try testing.expectEqual(@as(usize, 0), result.missed_punishments.len);
}

test "PlayerTendency should initialize correctly" {
    const tendency = PlayerTendency{};
    try testing.expectEqual(Playstyle.neutral, tendency.playstyle);
    try testing.expectEqual(@as(u32, 0), tendency.punish_attempts);
    try testing.expectEqual(@as(u32, 0), tendency.blocks);
    try testing.expectEqual(@as(u32, 0), tendency.total_frames);
}

test "categorizePunishImpact should be correct" {
    try testing.expectEqual(PunishImpact.low, Coach.categorizePunishImpact(5));
    try testing.expectEqual(PunishImpact.medium, Coach.categorizePunishImpact(12));
    try testing.expectEqual(PunishImpact.high, Coach.categorizePunishImpact(17));
    try testing.expectEqual(PunishImpact.critical, Coach.categorizePunishImpact(25));
}

test "findOptimalPunishMove should return correct values" {
    try testing.expectEqual(@as(?u32, null), Coach.findOptimalPunishMove(5));
    try testing.expectEqual(@as(?u32, 10), Coach.findOptimalPunishMove(10));
    try testing.expectEqual(@as(?u32, 12), Coach.findOptimalPunishMove(12));
    try testing.expectEqual(@as(?u32, 14), Coach.findOptimalPunishMove(14));
    try testing.expectEqual(@as(?u32, 15), Coach.findOptimalPunishMove(20));
}

test "FrameIterator should iterate through frames with correct player assignment" {
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    var iter = FrameIterator.init(&frames, .player_1);
    var count: usize = 0;
    while (iter.next()) |state| {
        // Verify player is correctly assigned based on player_id
        try testing.expectEqual(&frames[count].players[0], state.player);
        try testing.expectEqual(&frames[count].players[1], state.opponent);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

test "FrameIterator should assign player_2 correctly" {
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
    };
    var iter = FrameIterator.init(&frames, .player_2);
    if (iter.next()) |state| {
        try testing.expectEqual(&frames[0].players[1], state.player);
        try testing.expectEqual(&frames[0].players[0], state.opponent);
    }
}

test "determinePlaystyle should classify correctly" {
    // Aggressive: high punish_attempts relative to total moves
    var aggressive = PlayerTendency{};
    aggressive.punish_attempts = 20;
    aggressive.move_frequency[0] = 30;
    aggressive.total_frames = 100;
    try testing.expectEqual(Playstyle.aggressive, Coach.determinePlaystyle(&aggressive));

    // Defensive: high block ratio
    var defensive = PlayerTendency{};
    defensive.blocks = 50;
    defensive.move_frequency[0] = 10;
    defensive.total_frames = 100;
    try testing.expectEqual(Playstyle.defensive, Coach.determinePlaystyle(&defensive));
}

test "recordMoveFrequency should track moves correctly" {
    var tendency = PlayerTendency{};
    Coach.recordMoveFrequency(&tendency, 100);
    Coach.recordMoveFrequency(&tendency, 100);
    Coach.recordMoveFrequency(&tendency, 200);
    try testing.expectEqual(@as(u32, 100), tendency.move_ids[0]);
    try testing.expectEqual(@as(u32, 2), tendency.move_frequency[0]);
    try testing.expectEqual(@as(u32, 200), tendency.move_ids[1]);
    try testing.expectEqual(@as(u32, 1), tendency.move_frequency[1]);
}

test "MatchStats should initialize correctly" {
    const stats = MatchStats{};
    try testing.expectEqual(@as(u32, 0), stats.total_frames);
    try testing.expectEqual(@as(u32, 0), stats.player_damage_dealt);
    try testing.expectEqual(@as(u32, 0), stats.player_rounds_won);
}
