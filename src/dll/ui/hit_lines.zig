const std = @import("std");
const imgui = @import("imgui");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const ui = @import("../ui/root.zig");

pub const HitLines = struct {
    lingering: sdk.misc.CircularBuffer(128, LingeringLine) = .{},

    const Self = @This();
    const LingeringLine = struct {
        line: sdk.math.LineSegment3,
        player_id: model.PlayerId,
        remaining_time: f32,
        attack_type: ?model.AttackType,
        inactive_or_crushed: bool,
    };

    pub fn processFrame(
        self: *Self,
        settings: *const model.PlayerSettings(model.HitLinesSettings),
        frame: *const model.Frame,
    ) void {
        for (model.PlayerId.all) |player_id| {
            const player_settings = settings.getById(frame, player_id);
            if (!player_settings.enabled) {
                continue;
            }
            const player = frame.getPlayerById(player_id);
            const hit_lines: []const model.HitLine = player.hit_lines.asSlice();
            for (hit_lines) |*hit_line| {
                _ = self.lingering.addToBack(.{
                    .line = hit_line.line,
                    .player_id = player_id,
                    .remaining_time = player_settings.duration,
                    .attack_type = player.attack_type,
                    .inactive_or_crushed = hit_line.flags.is_inactive or hit_line.flags.is_crushed,
                });
            }
        }
    }

    pub fn update(self: *Self, delta_time: f32) void {
        for (0..self.lingering.len) |index| {
            const line = self.lingering.get(index) catch unreachable;
            line.remaining_time -= delta_time;
        }
        while (self.lingering.getFirst() catch null) |line| {
            if (line.remaining_time > 0.0) {
                break;
            }
            _ = self.lingering.removeFirst() catch unreachable;
        }
    }

    pub fn draw(
        self: *const Self,
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HitLinesSettings),
        frame: *const model.Frame,
    ) void {
        self.drawLingering(shapes, settings, frame);
        drawRegular(shapes, settings, frame);
    }

    fn drawRegular(
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HitLinesSettings),
        frame: *const model.Frame,
    ) void {
        for (model.PlayerId.all) |player_id| {
            const player_settings = settings.getById(frame, player_id);
            if (!player_settings.enabled) {
                continue;
            }
            const player = frame.getPlayerById(player_id);
            for (player.hit_lines.asSlice()) |hit_line| {
                const line_settings = if (hit_line.flags.is_inactive or hit_line.flags.is_crushed) block: {
                    if (!player_settings.inactive_or_crushed.enabled) {
                        continue;
                    }
                    break :block &player_settings.inactive_or_crushed;
                } else block: {
                    if (!player_settings.normal.enabled) {
                        continue;
                    }
                    break :block &player_settings.normal;
                };
                const line = hit_line.line;
                const color = line_settings.outline.colors.get(player.attack_type orelse .not_attack);
                const thickness = line_settings.fill.thickness + (2.0 * line_settings.outline.thickness);
                shapes.drawLine(line, color, thickness, 0);
            }
        }
        for (model.PlayerId.all) |player_id| {
            const player_settings = settings.getById(frame, player_id);
            if (!player_settings.enabled) {
                continue;
            }
            const player = frame.getPlayerById(player_id);
            for (player.hit_lines.asSlice()) |hit_line| {
                const line_settings = if (hit_line.flags.is_inactive or hit_line.flags.is_crushed) block: {
                    if (!player_settings.inactive_or_crushed.enabled) {
                        continue;
                    }
                    break :block &player_settings.inactive_or_crushed;
                } else block: {
                    if (!player_settings.normal.enabled) {
                        continue;
                    }
                    break :block &player_settings.normal;
                };
                const line = hit_line.line;
                const color = line_settings.fill.colors.get(player.attack_type orelse .not_attack);
                const thickness = line_settings.fill.thickness;
                shapes.drawLine(line, color, thickness, 0);
            }
        }
    }

    fn drawLingering(
        self: *const Self,
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HitLinesSettings),
        frame: *const model.Frame,
    ) void {
        for (0..self.lingering.len) |index| {
            const hit_line = self.lingering.get(index) catch unreachable;
            const player_settings = settings.getById(frame, hit_line.player_id);
            if (!player_settings.enabled) {
                continue;
            }

            const line = hit_line.line;
            const line_settings = if (hit_line.inactive_or_crushed) block: {
                if (!player_settings.inactive_or_crushed.enabled) {
                    continue;
                }
                break :block &player_settings.inactive_or_crushed;
            } else block: {
                if (!player_settings.normal.enabled) {
                    continue;
                }
                break :block &player_settings.normal;
            };

            const duration = player_settings.duration;
            const completion = 1.0 - (hit_line.remaining_time / duration);
            var color = line_settings.outline.colors.get(hit_line.attack_type orelse .not_attack);
            color.asColor().a *= 1.0 - (completion * completion * completion * completion);
            const thickness = line_settings.fill.thickness + (2.0 * line_settings.outline.thickness);

            shapes.drawLine(line, color, thickness, 0);
        }
        for (0..self.lingering.len) |index| {
            const hit_line = self.lingering.get(index) catch unreachable;
            const player_settings = settings.getById(frame, hit_line.player_id);
            if (!player_settings.enabled) {
                continue;
            }

            const line = hit_line.line;
            const line_settings = if (hit_line.inactive_or_crushed) block: {
                if (!player_settings.inactive_or_crushed.enabled) {
                    continue;
                }
                break :block &player_settings.inactive_or_crushed;
            } else block: {
                if (!player_settings.normal.enabled) {
                    continue;
                }
                break :block &player_settings.normal;
            };

            const duration = player_settings.duration;
            const completion = 1.0 - (hit_line.remaining_time / duration);
            var color = line_settings.fill.colors.get(hit_line.attack_type orelse .not_attack);
            color.asColor().a *= 1.0 - (completion * completion * completion * completion);
            const thickness = line_settings.fill.thickness;

            shapes.drawLine(line, color, thickness, 0);
        }
    }
};

const testing = std.testing;

test "should draw regular lines correctly" {
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();

    var hit_lines: HitLines = .{};
    const shapes = ui.Shapes{ ._void = .{} };
    const settings = model.PlayerSettings(model.HitLinesSettings){
        .mode = .id_separated,
        .players = .{
            .{
                .enabled = true,
                .normal = .{
                    .enabled = true,
                    .fill = .{ .colors = .initFill(.fill(0.1)), .thickness = 1 },
                    .outline = .{ .colors = .initFill(.fill(0.2)), .thickness = 2 },
                },
            },
            .{
                .enabled = true,
                .normal = .{
                    .enabled = true,
                    .fill = .{ .colors = .initFill(.fill(0.3)), .thickness = 3 },
                    .outline = .{ .colors = .initFill(.fill(0.4)), .thickness = 4 },
                },
            },
        },
    };
    const frame = model.Frame{ .players = .{
        .{ .hit_lines = .fromArray(.{
            model.HitLine{ .line = .{ .point_1 = .fill(1), .point_2 = .fill(2) } },
            model.HitLine{ .line = .{ .point_1 = .fill(3), .point_2 = .fill(4) } },
        }) },
        .{ .hit_lines = .fromArray(.{
            model.HitLine{ .line = .{ .point_1 = .fill(-1), .point_2 = .fill(-2) } },
            model.HitLine{ .line = .{ .point_1 = .fill(-3), .point_2 = .fill(-4) } },
        }) },
    } };
    hit_lines.draw(&shapes, &settings, &frame);

    try testing.expectEqual(8, ui.testing_shapes.getAll().len);
    const pairs = [4]?ui.TestingShapes.LinePair{
        ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001),
        ui.testing_shapes.findLinePairWithWorldPoints(.fill(3), .fill(4), 0.0001),
        ui.testing_shapes.findLinePairWithWorldPoints(.fill(-1), .fill(-2), 0.0001),
        ui.testing_shapes.findLinePairWithWorldPoints(.fill(-3), .fill(-4), 0.0001),
    };
    for (pairs, 0..) |pair, index| {
        try testing.expect(pair != null);
        if (index < 2) {
            try testing.expectEqual(sdk.math.Vec4.fill(0.1), pair.?.thinner.color);
            try testing.expectEqual(1, pair.?.thinner.thickness);
            try testing.expectEqual(sdk.math.Vec4.fill(0.2), pair.?.thicker.color);
            try testing.expectEqual(5, pair.?.thicker.thickness);
        } else {
            try testing.expectEqual(sdk.math.Vec4.fill(0.3), pair.?.thinner.color);
            try testing.expectEqual(3, pair.?.thinner.thickness);
            try testing.expectEqual(sdk.math.Vec4.fill(0.4), pair.?.thicker.color);
            try testing.expectEqual(11, pair.?.thicker.thickness);
        }
    }
}

test "should draw lingering lines correctly" {
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();

    var hit_lines: HitLines = .{};
    const shapes = ui.Shapes{ ._void = .{} };
    const settings = model.PlayerSettings(model.HitLinesSettings){
        .mode = .id_separated,
        .players = .{
            .{
                .enabled = true,
                .normal = .{
                    .enabled = true,
                    .fill = .{ .colors = .initFill(.fill(0.1)), .thickness = 1 },
                    .outline = .{ .colors = .initFill(.fill(0.2)), .thickness = 2 },
                },
                .duration = 10,
            },
            .{},
        },
    };
    var frame = model.Frame{ .players = .{
        .{ .hit_lines = .fromArray(.{model.HitLine{ .line = .{ .point_1 = .fill(1), .point_2 = .fill(2) } }}) },
        .{},
    } };
    hit_lines.processFrame(&settings, &frame);
    frame.players[0].hit_lines = .empty;

    ui.testing_shapes.clear();
    hit_lines.draw(&shapes, &settings, &frame);
    try testing.expectEqual(2, ui.testing_shapes.getAll().len);
    var pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.r(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.g(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.b(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.a(), 0.0001);
    try testing.expectEqual(1, pair.?.thinner.thickness);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.r(), 0.0001);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.g(), 0.0001);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.b(), 0.0001);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.a(), 0.0001);
    try testing.expectEqual(5, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    hit_lines.update(8);
    hit_lines.draw(&shapes, &settings, &frame);
    try testing.expectEqual(2, ui.testing_shapes.getAll().len);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.r(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.g(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thinner.color.b(), 0.0001);
    try testing.expectApproxEqAbs(0.05, pair.?.thinner.color.a(), 0.04);
    try testing.expectEqual(1, pair.?.thinner.thickness);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.r(), 0.0001);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.g(), 0.0001);
    try testing.expectApproxEqAbs(0.2, pair.?.thicker.color.b(), 0.0001);
    try testing.expectApproxEqAbs(0.1, pair.?.thicker.color.a(), 0.08);
    try testing.expectEqual(5, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    hit_lines.update(3);
    hit_lines.draw(&shapes, &settings, &frame);
    try testing.expectEqual(0, ui.testing_shapes.getAll().len);
}

test "should not draw lines for the player disabled in settings" {
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();

    var hit_lines: HitLines = .{};
    const shapes = ui.Shapes{ ._void = .{} };
    const settings = model.PlayerSettings(model.HitLinesSettings){
        .mode = .id_separated,
        .players = .{
            .{ .enabled = true },
            .{ .enabled = false },
        },
    };
    var frame = model.Frame{ .players = .{
        .{ .hit_lines = .fromArray(.{
            model.HitLine{ .line = .{ .point_1 = .fill(1), .point_2 = .fill(2) } },
            model.HitLine{ .line = .{ .point_1 = .fill(3), .point_2 = .fill(4) } },
        }) },
        .{ .hit_lines = .fromArray(.{
            model.HitLine{ .line = .{ .point_1 = .fill(-1), .point_2 = .fill(-2) } },
            model.HitLine{ .line = .{ .point_1 = .fill(-3), .point_2 = .fill(-4) } },
        }) },
    } };

    ui.testing_shapes.clear();
    hit_lines.draw(&shapes, &settings, &frame);
    try testing.expectEqual(4, ui.testing_shapes.getAll().len);
    try testing.expect(ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001) != null);
    try testing.expect(ui.testing_shapes.findLinePairWithWorldPoints(.fill(3), .fill(4), 0.0001) != null);
    try testing.expectEqual(null, ui.testing_shapes.findLinePairWithWorldPoints(.fill(-1), .fill(-2), 0.0001));
    try testing.expectEqual(null, ui.testing_shapes.findLinePairWithWorldPoints(.fill(-3), .fill(-4), 0.0001));

    ui.testing_shapes.clear();
    hit_lines.processFrame(&settings, &frame);
    frame.players[0].hit_lines.len = 0;
    hit_lines.draw(&shapes, &settings, &frame);
    try testing.expectEqual(4, ui.testing_shapes.getAll().len);
    try testing.expect(ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001) != null);
    try testing.expect(ui.testing_shapes.findLinePairWithWorldPoints(.fill(3), .fill(4), 0.0001) != null);
    try testing.expectEqual(null, ui.testing_shapes.findLinePairWithWorldPoints(.fill(-1), .fill(-2), 0.0001));
    try testing.expectEqual(null, ui.testing_shapes.findLinePairWithWorldPoints(.fill(-3), .fill(-4), 0.0001));
}

test "should draw with correct color and thickness depending on attack type, inactivity and crushing" {
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();

    var hit_lines: HitLines = .{};
    const shapes = ui.Shapes{ ._void = .{} };
    const settings = model.PlayerSettings(model.HitLinesSettings){
        .mode = .id_separated,
        .players = .{
            .{
                .enabled = true,
                .normal = .{
                    .enabled = true,
                    .fill = .{
                        .colors = .init(.{
                            .not_attack = .fill(0.01),
                            .high = .fill(0.02),
                            .mid = .fill(0.03),
                            .low = .fill(0.04),
                            .special_low = .fill(0.05),
                            .unblockable_high = .fill(0.06),
                            .unblockable_mid = .fill(0.07),
                            .unblockable_low = .fill(0.08),
                            .throw = .fill(0.09),
                            .projectile = .fill(0.10),
                            .antiair_only = .fill(0.11),
                        }),
                        .thickness = 1,
                    },
                    .outline = .{
                        .colors = .init(.{
                            .not_attack = .fill(0.12),
                            .high = .fill(0.13),
                            .mid = .fill(0.14),
                            .low = .fill(0.15),
                            .special_low = .fill(0.16),
                            .unblockable_high = .fill(0.17),
                            .unblockable_mid = .fill(0.18),
                            .unblockable_low = .fill(0.19),
                            .throw = .fill(0.20),
                            .projectile = .fill(0.21),
                            .antiair_only = .fill(0.22),
                        }),
                        .thickness = 2,
                    },
                },
                .inactive_or_crushed = .{
                    .enabled = true,
                    .fill = .{
                        .colors = .init(.{
                            .not_attack = .fill(0.23),
                            .high = .fill(0.24),
                            .mid = .fill(0.25),
                            .low = .fill(0.26),
                            .special_low = .fill(0.27),
                            .unblockable_high = .fill(0.28),
                            .unblockable_mid = .fill(0.29),
                            .unblockable_low = .fill(0.30),
                            .throw = .fill(0.31),
                            .projectile = .fill(0.32),
                            .antiair_only = .fill(0.33),
                        }),
                        .thickness = 3,
                    },
                    .outline = .{
                        .colors = .init(.{
                            .not_attack = .fill(0.34),
                            .high = .fill(0.35),
                            .mid = .fill(0.36),
                            .low = .fill(0.37),
                            .special_low = .fill(0.38),
                            .unblockable_high = .fill(0.39),
                            .unblockable_mid = .fill(0.40),
                            .unblockable_low = .fill(0.41),
                            .throw = .fill(0.42),
                            .projectile = .fill(0.43),
                            .antiair_only = .fill(0.44),
                        }),
                        .thickness = 4,
                    },
                },
                .duration = 10,
            },
            .{},
        },
    };
    var frame = model.Frame{ .players = .{
        .{ .hit_lines = .fromArray(.{model.HitLine{ .line = .{ .point_1 = .fill(1), .point_2 = .fill(2) } }}) },
        .{},
    } };

    ui.testing_shapes.clear();
    frame.players[0].attack_type = .mid;
    hit_lines.draw(&shapes, &settings, &frame);
    var pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.03), pair.?.thinner.color);
    try testing.expectEqual(1, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.14), pair.?.thicker.color);
    try testing.expectEqual(5, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    frame.players[0].hit_lines.asSlice()[0].flags.is_inactive = true;
    hit_lines.draw(&shapes, &settings, &frame);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.25), pair.?.thinner.color);
    try testing.expectEqual(3, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.36), pair.?.thicker.color);
    try testing.expectEqual(11, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    frame.players[0].attack_type = .high;
    hit_lines.draw(&shapes, &settings, &frame);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.24), pair.?.thinner.color);
    try testing.expectEqual(3, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.35), pair.?.thicker.color);
    try testing.expectEqual(11, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    frame.players[0].hit_lines.buffer[0].flags.is_inactive = false;
    hit_lines.draw(&shapes, &settings, &frame);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.02), pair.?.thinner.color);
    try testing.expectEqual(1, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.13), pair.?.thicker.color);
    try testing.expectEqual(5, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    frame.players[0].attack_type = .low;
    frame.players[0].hit_lines.len = 1;
    hit_lines.processFrame(&settings, &frame);
    frame.players[0].hit_lines.len = 0;
    hit_lines.draw(&shapes, &settings, &frame);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.04), pair.?.thinner.color);
    try testing.expectEqual(1, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.15), pair.?.thicker.color);
    try testing.expectEqual(5, pair.?.thicker.thickness);

    ui.testing_shapes.clear();
    hit_lines.update(100);
    frame.players[0].hit_lines.buffer[0].flags.is_crushed = true;
    frame.players[0].hit_lines.len = 1;
    hit_lines.processFrame(&settings, &frame);
    frame.players[0].hit_lines.len = 0;
    hit_lines.draw(&shapes, &settings, &frame);
    pair = ui.testing_shapes.findLinePairWithWorldPoints(.fill(1), .fill(2), 0.0001);
    try testing.expect(pair != null);
    try testing.expectEqual(sdk.math.Vec4.fill(0.26), pair.?.thinner.color);
    try testing.expectEqual(3, pair.?.thinner.thickness);
    try testing.expectEqual(sdk.math.Vec4.fill(0.37), pair.?.thicker.color);
    try testing.expectEqual(11, pair.?.thicker.thickness);
}
