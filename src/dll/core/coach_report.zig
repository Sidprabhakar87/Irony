const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const coach = @import("coach.zig");

pub const CoachReport = struct {
    allocator: std.mem.Allocator,
    match_id: []const u8,
    player_id: []const u8,
    opponent_id: []const u8,
    player_character: []const u8,
    opponent_character: []const u8,
    summary: MatchSummary,
    missed_punishments: []const coach.PunishOpportunity,
    opponent_tendencies: TendencyReport,
    strategy_recommendations: []const coach.StrategyRecommendation,
    generated_at: i64,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        match_id: []const u8,
        player_id: []const u8,
        opponent_id: []const u8,
    ) Self {
        return .{
            .allocator = allocator,
            .match_id = match_id,
            .player_id = player_id,
            .opponent_id = opponent_id,
            .player_character = "",
            .opponent_character = "",
            .summary = .{},
            .missed_punishments = &.{},
            .opponent_tendencies = .{},
            .strategy_recommendations = &.{},
            .generated_at = std.time.timestamp(),
        };
    }

    pub fn deinit(self: *Self) void {
        for (self.strategy_recommendations) |rec| {
            self.allocator.free(rec.situation);
            self.allocator.free(rec.counter);
            self.allocator.free(rec.reason);
        }
        self.allocator.free(self.strategy_recommendations);
    }

    pub fn exportToJson(self: *const Self, writer: anytype) !void {
        try writer.print("{{\n", .{});
        try writer.print("  \"match_id\": \"{s}\",\n", .{self.match_id});
        try writer.print("  \"player_id\": \"{s}\",\n", .{self.player_id});
        try writer.print("  \"opponent_id\": \"{s}\",\n", .{self.opponent_id});
        try writer.print("  \"player_character\": \"{s}\",\n", .{self.player_character});
        try writer.print("  \"opponent_character\": \"{s}\",\n", .{self.opponent_character});
        try writer.print("  \"generated_at\": {d},\n", .{self.generated_at});

        try writer.print("  \"summary\": {{\n", .{});
        try writer.print("    \"rounds_won\": {d},\n", .{self.summary.rounds_won});
        try writer.print("    \"rounds_lost\": {d},\n", .{self.summary.rounds_lost});
        try writer.print("    \"total_damage_dealt\": {d},\n", .{self.summary.total_damage_dealt});
        try writer.print("    \"total_damage_taken\": {d},\n", .{self.summary.total_damage_taken});
        try writer.print("    \"total_frames\": {d}\n", .{self.summary.total_frames});
        try writer.print("  }},\n", .{});

        try writer.print("  \"missed_punishments\": [\n", .{});
        for (self.missed_punishments, 0..) |punish, i| {
            try writer.print("    {{\n", .{});
            try writer.print("      \"frame\": {d},\n", .{punish.frame_number});
            if (punish.opponent_recovery_frames.actual) |rec| {
                try writer.print("      \"opponent_recovery_frames\": {d},\n", .{rec});
            }
            try writer.print("      \"impact\": \"{s}\"\n", .{@tagName(punish.impact)});
            try writer.print("    }}", .{});
            if (i < self.missed_punishments.len - 1) try writer.print(",", .{});
            try writer.print("\n", .{});
        }
        try writer.print("  ],\n", .{});

        try writer.print("  \"opponent_tendencies\": {{\n", .{});
        try writer.print("    \"playstyle\": \"{s}\",\n", .{@tagName(self.opponent_tendencies.playstyle)});
        try writer.print("    \"favorite_moves\": [", .{});
        var first = true;
        for (self.opponent_tendencies.favorite_moves) |move| {
            if (!first) try writer.print(", ", .{});
            try writer.print("{d}", .{move});
            first = false;
        }
        try writer.print("],\n", .{});
        try writer.print("    \"heat_activations\": {d},\n", .{self.opponent_tendencies.heat_activations});
        try writer.print("    \"rage_activations\": {d}\n", .{self.opponent_tendencies.rage_activations});
        try writer.print("  }},\n", .{});

        try writer.print("  \"strategy_recommendations\": [\n", .{});
        for (self.strategy_recommendations, 0..) |rec, i| {
            try writer.print("    {{\n", .{});
            try writer.print("      \"situation\": \"{s}\",\n", .{rec.situation});
            try writer.print("      \"counter\": \"{s}\",\n", .{rec.counter});
            try writer.print("      \"risk\": \"{s}\",\n", .{@tagName(rec.risk)});
            try writer.print("      \"frame_advantage_on_hit\": \"{s}\",\n", .{rec.frame_advantage_on_hit});
            try writer.print("      \"reason\": \"{s}\"\n", .{rec.reason});
            try writer.print("    }}", .{});
            if (i < self.strategy_recommendations.len - 1) try writer.print(",", .{});
            try writer.print("\n", .{});
        }
        try writer.print("  ]\n", .{});

        try writer.print("}}\n", .{});
    }

    pub fn exportToText(self: *const Self, writer: anytype) !void {
        try writer.print("=== COACHING REPORT ===\n\n", .{});
        try writer.print("Match: {s}\n", .{self.match_id});
        try writer.print("Player: {s} ({s}) vs {s} ({s})\n\n", .{
            self.player_id, self.player_character,
            self.opponent_id, self.opponent_character,
        });

        try writer.print("--- MATCH SUMMARY ---\n", .{});
        try writer.print("Result: {d} - {d} (W-L)\n", .{ self.summary.rounds_won, self.summary.rounds_lost });
        try writer.print("Damage Dealt: {d} | Damage Taken: {d}\n", .{ self.summary.total_damage_dealt, self.summary.total_damage_taken });
        try writer.print("Total Frames: {d}\n\n", .{self.summary.total_frames});

        if (self.missed_punishments.len > 0) {
            try writer.print("--- MISSED PUNISHMENTS ({d}) ---\n", .{self.missed_punishments.len});
            for (self.missed_punishments) |punish| {
                try writer.print("  Frame {d}: {s} impact, {d} recovery frames\n", .{
                    punish.frame_number,
                    @tagName(punish.impact),
                    punish.opponent_recovery_frames.actual orelse 0,
                });
            }
            try writer.print("\n", .{});
        }

        try writer.print("--- OPPONENT TENDENCIES ---\n", .{});
        try writer.print("Playstyle: {s}\n", .{@tagName(self.opponent_tendencies.playstyle)});
        try writer.print("Favorite Moves: ", .{});
        for (self.opponent_tendencies.favorite_moves, 0..) |move, i| {
            if (i > 0) try writer.print(", ", .{});
            try writer.print("{d}", .{move});
        }
        try writer.print("\n", .{});
        try writer.print("Heat Uses: {d} | Rage Uses: {d}\n\n", .{
            self.opponent_tendencies.heat_activations,
            self.opponent_tendencies.rage_activations,
        });

        if (self.strategy_recommendations.len > 0) {
            try writer.print("--- STRATEGY RECOMMENDATIONS ---\n", .{});
            for (self.strategy_recommendations, 0..) |rec, i| {
                try writer.print("  {d}. {s}\n", .{ i + 1, rec.situation });
                try writer.print("     Counter: {s} ({s} risk)\n", .{ rec.counter, @tagName(rec.risk) });
                try writer.print("     Reason: {s}\n\n", .{rec.reason});
            }
        }

        try writer.print("Generated: {d}\n", .{self.generated_at});
    }
};

pub const MatchSummary = struct {
    rounds_won: u32 = 0,
    rounds_lost: u32 = 0,
    total_damage_dealt: u32 = 0,
    total_damage_taken: u32 = 0,
    total_frames: u32 = 0,
};

pub const TendencyReport = struct {
    playstyle: coach.Playstyle = .neutral,
    favorite_moves: [5]u32 = .{0} ** 5,
    habitual_patterns: [10][]const u8 = .{""} ** 10,
    heatmap: PositionHeatmap = .{},
    heat_activations: u32 = 0,
    rage_activations: u32 = 0,
};

pub const PositionHeatmap = struct {
    center_preference: []const u8 = "mid-range",
    favorite_distance: []const u8 = "close",
};

const testing = std.testing;

test "CoachReport.init should initialize correctly" {
    var report = CoachReport.init(std.heap.page_allocator, "match123", "player1", "player2");
    defer report.deinit();
    try testing.expectEqualStrings("match123", report.match_id);
    try testing.expectEqualStrings("player1", report.player_id);
    try testing.expectEqualStrings("player2", report.opponent_id);
}

test "MatchSummary should have correct defaults" {
    const summary = MatchSummary{};
    try testing.expectEqual(0, summary.rounds_won);
    try testing.expectEqual(0, summary.rounds_lost);
    try testing.expectEqual(0, summary.total_damage_dealt);
    try testing.expectEqual(0, summary.total_damage_taken);
}

test "TendencyReport should initialize correctly" {
    const report = TendencyReport{};
    try testing.expectEqual(.neutral, report.playstyle);
    try testing.expectEqual(0, report.heat_activations);
    try testing.expectEqual(0, report.rage_activations);
}