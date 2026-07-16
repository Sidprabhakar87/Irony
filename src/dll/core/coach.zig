const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");

pub const MaxMoveIds = 50;

pub const Coach = struct {
    const Self = @This();

    pub fn analyzeReplay(frames: []const model.Frame, player_id: model.PlayerId) MatchAnalysis {
        var analysis = MatchAnalysis{};
        if (frames.len == 0) return analysis;

        var player_tendency = PlayerTendency{};
        var opponent_tendency = PlayerTendency{};
        var match_stats = MatchStats{};
        var missed_punishments = std.ArrayList(PunishOpportunity).init(std.heap.page_allocator);
        defer missed_punishments.deinit();

        var frame_iter = FrameIterator{ .frames = frames };
        while (frame_iter.next()) |state| {
            match_stats.processFrame(state.frame, player_id);
            profilePlayerTendency(&player_tendency, state.player_frame, state.opponent_frame, state.is_player_turn);
            profilePlayerTendency(&opponent_tendency, state.opponent_frame, state.player_frame, !state.is_player_turn);

            if (state.is_player_turn and state.opponent_frame.move_phase == .recovery) {
                if (findMissedPunishment(state.frame, player_id)) |punish| {
                    missed_punishments.append(punish) catch {};
                }
            }
        }

        analysis.missed_punishments = missed_punishments.toOwnedSlice();
        analysis.player_tendency = player_tendency;
        analysis.opponent_tendency = opponent_tendency;
        analysis.match_stats = match_stats;
        return analysis;
    }

    fn findMissedPunishment(frame: *const model.Frame, player_id: model.PlayerId) ?PunishOpportunity {
        const player = frame.getPlayerById(player_id);
        const opponent = frame.getPlayerById(player_id.getOther());

        if (player.move_phase != .neutral) return null;
        if (opponent.move_phase != .recovery) return null;
        if (player.attack_type != null and player.attack_type != .not_attack) return null;

        const opponent_recovery = opponent.getRecoveryFrames();
        if (opponent_recovery.actual == null or opponent_recovery.actual.? < 10) return null;

        return .{
            .frame_number = frame.frames_since_round_start orelse 0,
            .opponent_frame_advantage = opponent.frame_advantage,
            .opponent_recovery_frames = opponent_recovery,
            .player_used_move = null,
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
        is_player_turn: bool,
    ) void {
        if (player_frame.animation_id) |anim_id| {
            for (tendency.move_frequency, 0..) |count, i| {
                if (tendency.move_ids[i] == anim_id) {
                    tendency.move_frequency[i] = count + 1;
                    return;
                }
                if (count == 0) {
                    tendency.move_ids[i] = anim_id;
                    tendency.move_frequency[i] = 1;
                    return;
                }
            }
        }

        if (is_player_turn and opponent_frame.move_phase == .recovery) {
            tendency.punish_attempts += 1;
        }

        if (player_frame.blocking != null and player_frame.blocking != .not_blocking) {
            tendency.blocks += 1;
        }

        if (player_frame.heat) |heat| {
            switch (heat) {
                .available, .activated => tendency.heat_activations += 1,
                .used_up => {},
            }
        }

        if (player_frame.rage) |rage| {
            switch (rage) {
                .activated => tendency.rage_activations += 1,
                else => {},
            }
        }
    }

    pub fn identifyOptimalPunishment(
        self: *Self,
        frames: []const model.Frame,
        player_id: model.PlayerId,
    ) []const PunishOpportunity {
        _ = self;
        var opportunities = std.ArrayList(PunishOpportunity).init(std.heap.page_allocator);

        var frame_iter = FrameIterator{ .frames = frames };
        while (frame_iter.next()) |state| {
            if (!state.is_player_turn) continue;
            const opponent = state.opponent_frame;

            if (opponent.move_phase != .recovery) continue;
            if (opponent.attack_type != null and opponent.attack_type != .not_attack) continue;

            const recovery = opponent.getRecoveryFrames();
            if (recovery.actual == null) continue;

            const optimal_move = findOptimalPunishMove(recovery.actual.?);
            opportunities.append(.{
                .frame_number = state.frame.frames_since_round_start orelse 0,
                .opponent_frame_advantage = opponent.frame_advantage,
                .opponent_recovery_frames = recovery,
                .player_used_move = state.player_frame.animation_id,
                .impact = categorizePunishImpact(recovery.actual.?),
                .optimal_punish_move = optimal_move,
            }) catch {};
        }

        return opportunities.toOwnedSlice();
    }

    fn findOptimalPunishMove(recovery_frames: u32) ?u32 {
        return switch (recovery_frames) {
            0...9 => 10,
            10...11 => 11,
            12...13 => 13,
            14...15 => 15,
            else => 18,
        };
    }

    pub fn profileOpponentStyle(frames: []const model.Frame, opponent_id: model.PlayerId) PlayerTendency {
        _ = opponent_id;
        var tendency = PlayerTendency{};
        var previous_player_frame: ?*const model.Player = null;
        var previous_round: ?u32 = null;
        var sequence: [5]?u32 = .{ null, null, null, null, null };
        var sequence_index: usize = 0;

        var frame_iter = FrameIterator{ .frames = frames };
        while (frame_iter.next()) |state| {
            const opponent_frame = state.opponent_frame;

            if (previous_round != state.frame.frames_since_round_start) {
                previous_round = state.frame.frames_since_round_start;
                for (&sequence) |*s| s.* = null;
                sequence_index = 0;
            }

            if (opponent_frame.animation_id) |anim_id| {
                sequence[sequence_index % 5] = anim_id;
                sequence_index += 1;

                for (tendency.move_frequency, 0..) |_, i| {
                    if (tendency.move_ids[i] == anim_id) {
                        tendency.move_frequency[i] += 1;
                        break;
                    }
                    if (tendency.move_ids[i] == 0) {
                        tendency.move_ids[i] = anim_id;
                        tendency.move_frequency[i] = 1;
                        break;
                    }
                }
            }

            if (opponent_frame.blocking != null and opponent_frame.blocking != .not_blocking) {
                tendency.blocks += 1;
            }

            if (opponent_frame.crushing) |crush| {
                if (crush.high_crushing) tendency.high_crush_count += 1;
                if (crush.low_crushing) tendency.low_crush_count += 1;
            }

            previous_player_frame = state.player_frame;
        }

        tendency.playstyle = determinePlaystyle(&tendency);
        return tendency;
    }

    fn determinePlaystyle(tendency: *const PlayerTendency) Playstyle {
        const total_moves = blk: {
            var total: u32 = 0;
            for (tendency.move_frequency) |count| total += count;
            break :blk total;
        };
        if (total_moves == 0) return .neutral;

        const offensive_ratio = @as(f32, @floatFromInt(tendency.punish_attempts)) / @as(f32, @floatFromInt(total_moves));
        const block_ratio = @as(f32, @floatFromInt(tendency.blocks)) / @as(f32, @floatFromInt(total_moves));

        if (offensive_ratio > 0.6) return .aggressive;
        if (block_ratio > 0.4) return .defensive;
        if (tendency.high_crush_count > 5 or tendency.low_crush_count > 5) return .poke_heavy;
        return .neutral;
    }

    pub fn generateStrategyGuide(
        self: *Self,
        frames: []const model.Frame,
        player_id: model.PlayerId,
        opponent_id: model.PlayerId,
    ) []const StrategyRecommendation {
        _ = self;
        var recommendations = std.ArrayList(StrategyRecommendation).init(std.heap.page_allocator);

        const opponent_tendency = profileOpponentStyle(frames, opponent_id);
        const favorite_moves = findFavoriteMoves(&opponent_tendency);

        for (favorite_moves) |move_id| {
            recommendations.append(.{
                .situation = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "Opponent uses move {d}",
                    .{move_id},
                ) catch continue,
                .counter = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "Use i{d} punish",
                    .{findOptimalPunishMove(15) orelse 15},
                ) catch continue,
                .risk = .medium,
                .frame_advantage_on_hit = "+15",
                .reason = std.fmt.allocPrint(
                    std.heap.page_allocator,
                    "Opponent frequently uses this move - prepare a punish",
                    .{},
                ) catch continue,
            }) catch {};
        }

        return recommendations.toOwnedSlice();
    }

    fn findFavoriteMoves(tendency: *const PlayerTendency) []const u32 {
        var moves = std.ArrayList(u32).init(std.heap.page_allocator);
        const max_moves = @min(5, MaxMoveIds);

        var max_idx: usize = 0;
        var max_count: u32 = 0;
        var added: usize = 0;

        while (added < max_moves) {
            max_count = 0;
            max_idx = 0;
            for (tendency.move_frequency, 0..) |count, i| {
                if (count > max_count and !containsMove(moves.items, tendency.move_ids[i])) {
                    max_count = count;
                    max_idx = i;
                }
            }
            if (max_count > 0) {
                moves.append(tendency.move_ids[max_idx]) catch {};
                tendency.move_frequency[max_idx] = 0;
                added += 1;
            } else break;
        }

        return moves.toOwnedSlice();
    }

    fn containsMove(moves: []const u32, move_id: u32) bool {
        for (moves) |m| if (m == move_id) return true;
        return false;
    }
};

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
};

pub const MatchAnalysis = struct {
    missed_punishments: []PunishOpportunity = &.{},
    player_tendency: PlayerTendency = .{},
    opponent_tendency: PlayerTendency = .{},
    match_stats: MatchStats = .{},
};

pub const PunishOpportunity = struct {
    frame_number: u32,
    opponent_frame_advantage: ?model.I32ActualMinMax = null,
    opponent_recovery_frames: model.U32ActualMinMax = .nulls,
    player_used_move: ?u32,
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
    situation: []u8,
    counter: []u8,
    risk: RiskLevel = .medium,
    frame_advantage_on_hit: []const u8,
    reason: []u8,
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

    fn processFrame(self: *MatchStats, frame: *const model.Frame, player_id: model.PlayerId) void {
        self.total_frames += 1;

        const player = frame.getPlayerById(player_id);
        const opponent = frame.getPlayerById(player_id.getOther());

        if (player.health != null and opponent.health != null) {
            const prev_player_health = player.health.? + player.combo_damage.?;
            const prev_opponent_health = opponent.health.? + opponent.combo_damage.?;
            if (prev_player_health > player.health.?) {
                self.player_damage_taken += prev_player_health - player.health.?;
            }
            if (prev_opponent_health > opponent.health.?) {
                self.player_damage_dealt += prev_opponent_health - opponent.health.?;
            }
        }

        if (player.heat) |heat| {
            switch (heat) {
                .activated => self.player_heat_uses += 1,
                else => {},
            }
        }
        if (player.rage == .activated) {
            self.player_rage_uses += 1;
        }

        if (player.rounds_won) |won| {
            self.player_rounds_won = won;
        }
        if (opponent.rounds_won) |won| {
            self.opponent_rounds_won = won;
        }
    }
};

pub const FrameIterator = struct {
    frames: []const model.Frame,
    index: usize = 0,

    const FrameState = struct {
        frame: *const model.Frame,
        player_frame: *const model.Player,
        opponent_frame: *const model.Player,
        is_player_turn: bool,
    };

    pub fn next(self: *FrameIterator) ?FrameState {
        if (self.index >= self.frames.len) return null;
        const frame = &self.frames[self.index];
        self.index += 1;
        return FrameState{
            .frame = frame,
            .player_frame = &frame.players[0],
            .opponent_frame = &frame.players[1],
            .is_player_turn = frame.players[0].move_phase == .recovery,
        };
    }
};

const testing = std.testing;

test "Coach.analyzeReplay should handle empty frames" {
    const coach = Coach{};
    const result = coach.analyzeReplay(&.{}, .player_1);
    try testing.expectEqual(0, result.missed_punishments.len);
}

test "PlayerTendency should initialize correctly" {
    const tendency = PlayerTendency{};
    try testing.expectEqual(.neutral, tendency.playstyle);
    try testing.expectEqual(0, tendency.punish_attempts);
    try testing.expectEqual(0, tendency.blocks);
}

test "PunishImpact categorization should be correct" {
    try testing.expectEqual(.low, categorizePunishImpact(5));
    try testing.expectEqual(.medium, categorizePunishImpact(12));
    try testing.expectEqual(.high, categorizePunishImpact(17));
    try testing.expectEqual(.critical, categorizePunishImpact(25));
}

test "findOptimalPunishMove should return correct values" {
    try testing.expectEqual(10, findOptimalPunishMove(5));
    try testing.expectEqual(11, findOptimalPunishMove(10));
    try testing.expectEqual(13, findOptimalPunishMove(12));
    try testing.expectEqual(15, findOptimalPunishMove(14));
    try testing.expectEqual(18, findOptimalPunishMove(20));
}

test "FrameIterator should iterate through frames" {
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    var iter = FrameIterator{ .frames = &frames };
    var count: usize = 0;
    while (iter.next()) |_| {
        count += 1;
    }
    try testing.expectEqual(3, count);
}