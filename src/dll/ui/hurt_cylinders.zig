const std = @import("std");
const imgui = @import("imgui");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const ui = @import("../ui/root.zig");

pub const HurtCylinders = struct {
    connected_remaining_time: std.EnumArray(model.PlayerId, std.EnumArray(model.HurtCylinderId, f32)) = .initFill(
        .initFill(0),
    ),
    lingering: sdk.misc.CircularBuffer(32, LingeringCylinder) = .{},

    const Self = @This();
    pub const LingeringCylinder = struct {
        cylinder: sdk.math.Cylinder,
        player_id: model.PlayerId,
        remaining_time: f32,
    };

    pub fn processFrame(
        self: *Self,
        settings: *const model.PlayerSettings(model.HurtCylindersSettings),
        frame: *const model.Frame,
    ) void {
        for (model.PlayerId.all) |player_id| {
            const player_settings = settings.getById(frame, player_id);
            if (!player_settings.enabled) {
                continue;
            }
            const player = frame.getPlayerById(player_id);
            const cylinders: *const model.HurtCylinders = if (player.hurt_cylinders) |*c| c else return;
            for (&cylinders.values, 0..) |*hurt_cylinder, index| {
                if (!hurt_cylinder.flags.is_connected) {
                    continue;
                }
                const cylinder_id = model.HurtCylinders.Indexer.keyForIndex(index);
                const connected_remaining_time = self.connected_remaining_time.getPtr(player_id).getPtr(cylinder_id);
                if (player_settings.connected.enabled) {
                    connected_remaining_time.* = player_settings.connected.duration;
                }
                if (player_settings.lingering.enabled) {
                    _ = self.lingering.addToBack(.{
                        .cylinder = hurt_cylinder.cylinder,
                        .player_id = player_id,
                        .remaining_time = player_settings.lingering.duration,
                    });
                }
            }
        }
    }

    pub fn update(self: *Self, delta_time: f32) void {
        self.updateRegular(delta_time);
        self.updateLingering(delta_time);
    }

    fn updateRegular(self: *Self, delta_time: f32) void {
        for (&self.connected_remaining_time.values) |*player_cylinders| {
            for (&player_cylinders.values) |*remaining_time| {
                remaining_time.* -= delta_time;
            }
        }
    }

    fn updateLingering(self: *Self, delta_time: f32) void {
        for (0..self.lingering.len) |index| {
            const cylinder = self.lingering.get(index) catch unreachable;
            cylinder.remaining_time -= delta_time;
        }
        while (self.lingering.getFirst() catch null) |cylinder| {
            if (cylinder.remaining_time > 0) {
                break;
            }
            _ = self.lingering.removeFirst() catch unreachable;
        }
    }

    pub fn draw(
        self: *const Self,
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HurtCylindersSettings),
        frame: *const model.Frame,
    ) void {
        self.drawLingering(shapes, settings, frame);
        self.drawRegular(shapes, settings, frame);
    }

    fn drawRegular(
        self: *const Self,
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HurtCylindersSettings),
        frame: *const model.Frame,
    ) void {
        for (model.PlayerId.all) |player_id| {
            const player_settings = settings.getById(frame, player_id);
            if (!player_settings.enabled) {
                continue;
            }

            const player = frame.getPlayerById(player_id);
            const crushing = player.crushing orelse model.Crushing{};

            const ps = if (crushing.power_crushing) block: {
                if (player_settings.power_crushing.enabled) {
                    break :block &player_settings.power_crushing;
                } else {
                    break :block &player_settings.normal;
                }
            } else block: {
                if (!player_settings.normal.enabled) {
                    continue;
                }
                break :block &player_settings.normal;
            };
            const base_settings = if (crushing.invincibility) block: {
                break :block &ps.invincible;
            } else if (crushing.high_crushing) block: {
                break :block &ps.high_crushing;
            } else if (crushing.low_crushing) block: {
                break :block &ps.low_crushing;
            } else block: {
                break :block &ps.normal;
            };

            const cylinders: *const model.HurtCylinders = if (player.hurt_cylinders) |*c| c else continue;
            for (cylinders.values, 0..) |hurt_cylinder, index| {
                const cylinder = hurt_cylinder.cylinder;
                const cylinder_id = model.HurtCylinders.Indexer.keyForIndex(index);

                const remaining_time = self.connected_remaining_time.getPtrConst(player_id).get(cylinder_id);
                const duration = player_settings.connected.duration;
                const completion: f32 = if (!player_settings.connected.enabled) block: {
                    break :block 1.0;
                } else if (hurt_cylinder.flags.is_connected) block: {
                    break :block 0.0;
                } else block: {
                    break :block std.math.clamp(1.0 - (remaining_time / duration), 0.0, 1.0);
                };
                const t = completion * completion * completion * completion;
                const color = sdk.math.Vec4.lerpElements(player_settings.connected.color, base_settings.color, t);
                const thickness = std.math.lerp(player_settings.connected.thickness, base_settings.thickness, t);

                shapes.drawCylinder(cylinder, color, thickness);
            }
        }
    }

    fn drawLingering(
        self: *const Self,
        shapes: *const ui.Shapes,
        settings: *const model.PlayerSettings(model.HurtCylindersSettings),
        frame: *const model.Frame,
    ) void {
        for (0..self.lingering.len) |index| {
            const hurt_cylinder = self.lingering.get(index) catch unreachable;
            const player_settings = settings.getById(frame, hurt_cylinder.player_id);
            if (!player_settings.enabled or !player_settings.lingering.enabled) {
                continue;
            }
            const cylinder = hurt_cylinder.cylinder;

            const duration = player_settings.lingering.duration;
            const completion = 1.0 - (hurt_cylinder.remaining_time / duration);
            var color = player_settings.lingering.color;
            color.asColor().a *= 1.0 - (completion * completion * completion * completion);
            const thickness = player_settings.lingering.thickness;

            shapes.drawCylinder(cylinder, color, thickness);
        }
    }
};

const testing = std.testing;

test "should draw cylinders correctly" {
    const Test = struct {
        var hurt_cylinders: HurtCylinders = .{};
        const settings = model.PlayerSettings(model.HurtCylindersSettings){
            .mode = .id_separated,
            .players = .{
                .{
                    .enabled = true,
                    .normal = .{
                        .enabled = true,
                        .normal = .{ .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), .thickness = 1 },
                        .high_crushing = .{ .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), .thickness = 1 },
                        .low_crushing = .{ .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), .thickness = 1 },
                        .invincible = .{ .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), .thickness = 1 },
                    },
                },
                .{
                    .enabled = true,
                    .normal = .{
                        .enabled = true,
                        .normal = .{ .color = .fromArray(.{ 0.5, 0.6, 0.7, 0.8 }), .thickness = 2 },
                        .high_crushing = .{ .color = .fromArray(.{ 0.5, 0.6, 0.7, 0.8 }), .thickness = 2 },
                        .low_crushing = .{ .color = .fromArray(.{ 0.5, 0.6, 0.7, 0.8 }), .thickness = 2 },
                        .invincible = .{ .color = .fromArray(.{ 0.5, 0.6, 0.7, 0.8 }), .thickness = 2 },
                    },
                },
            },
        };
        const frame = model.Frame{ .players = .{
            .{
                .hurt_cylinders = .init(.{
                    .left_ankle = .{ .cylinder = .{ .center = .fill(1), .radius = 1.1, .half_height = 1.2 } },
                    .right_ankle = .{ .cylinder = .{ .center = .fill(2), .radius = 2.1, .half_height = 2.2 } },
                    .left_hand = .{ .cylinder = .{ .center = .fill(3), .radius = 3.1, .half_height = 3.2 } },
                    .right_hand = .{ .cylinder = .{ .center = .fill(4), .radius = 4.1, .half_height = 4.2 } },
                    .left_knee = .{ .cylinder = .{ .center = .fill(5), .radius = 5.1, .half_height = 5.2 } },
                    .right_knee = .{ .cylinder = .{ .center = .fill(6), .radius = 6.1, .half_height = 6.2 } },
                    .left_elbow = .{ .cylinder = .{ .center = .fill(7), .radius = 7.1, .half_height = 7.2 } },
                    .right_elbow = .{ .cylinder = .{ .center = .fill(8), .radius = 8.1, .half_height = 8.2 } },
                    .head = .{ .cylinder = .{ .center = .fill(9), .radius = 9.1, .half_height = 9.2 } },
                    .left_shoulder = .{ .cylinder = .{ .center = .fill(10), .radius = 10.1, .half_height = 10.2 } },
                    .right_shoulder = .{ .cylinder = .{ .center = .fill(11), .radius = 11.1, .half_height = 11.2 } },
                    .upper_torso = .{ .cylinder = .{ .center = .fill(12), .radius = 12.1, .half_height = 12.2 } },
                    .left_pelvis = .{ .cylinder = .{ .center = .fill(13), .radius = 13.1, .half_height = 13.2 } },
                    .right_pelvis = .{ .cylinder = .{ .center = .fill(14), .radius = 14.1, .half_height = 14.2 } },
                }),
            },
            .{
                .hurt_cylinders = .init(.{
                    .left_ankle = .{ .cylinder = .{ .center = .fill(-1), .radius = 1.1, .half_height = 1.2 } },
                    .right_ankle = .{ .cylinder = .{ .center = .fill(-2), .radius = 2.1, .half_height = 2.2 } },
                    .left_hand = .{ .cylinder = .{ .center = .fill(-3), .radius = 3.1, .half_height = 3.2 } },
                    .right_hand = .{ .cylinder = .{ .center = .fill(-4), .radius = 4.1, .half_height = 4.2 } },
                    .left_knee = .{ .cylinder = .{ .center = .fill(-5), .radius = 5.1, .half_height = 5.2 } },
                    .right_knee = .{ .cylinder = .{ .center = .fill(-6), .radius = 6.1, .half_height = 6.2 } },
                    .left_elbow = .{ .cylinder = .{ .center = .fill(-7), .radius = 7.1, .half_height = 7.2 } },
                    .right_elbow = .{ .cylinder = .{ .center = .fill(-8), .radius = 8.1, .half_height = 8.2 } },
                    .head = .{ .cylinder = .{ .center = .fill(-9), .radius = 9.1, .half_height = 9.2 } },
                    .left_shoulder = .{ .cylinder = .{ .center = .fill(-10), .radius = 10.1, .half_height = 10.2 } },
                    .right_shoulder = .{ .cylinder = .{ .center = .fill(-11), .radius = 11.1, .half_height = 11.2 } },
                    .upper_torso = .{ .cylinder = .{ .center = .fill(-12), .radius = 12.1, .half_height = 12.2 } },
                    .left_pelvis = .{ .cylinder = .{ .center = .fill(-13), .radius = 13.1, .half_height = 13.2 } },
                    .right_pelvis = .{ .cylinder = .{ .center = .fill(-14), .radius = 14.1, .half_height = 14.2 } },
                }),
            },
        } };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .front,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            hurt_cylinders.draw(&shapes, &settings, &frame);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(28, ui.testing_shapes.getAll().len);
            const cylinders = [28]?*const ui.TestingShapes.Cylinder{
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(2), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(3), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(4), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(5), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(6), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(7), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(8), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(9), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(10), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(11), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(13), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(14), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-2), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-3), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-4), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-5), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-6), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-7), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-8), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-9), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-10), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-11), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-12), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-13), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-14), 0.0001),
            };
            for (cylinders, 0..) |cylinder, index| {
                try testing.expect(cylinder != null);
                if (index < 14) {
                    try testing.expectApproxEqAbs(0.1, cylinder.?.color.r(), 0.0001);
                    try testing.expectApproxEqAbs(0.2, cylinder.?.color.g(), 0.0001);
                    try testing.expectApproxEqAbs(0.3, cylinder.?.color.b(), 0.0001);
                    try testing.expectApproxEqAbs(0.4, cylinder.?.color.a(), 0.0001);
                    try testing.expectEqual(1, cylinder.?.thickness);
                    const f_index: f32 = @floatFromInt(index);
                    try testing.expectEqual(f_index + 1.1, cylinder.?.world_cylinder.radius);
                    try testing.expectEqual(f_index + 1.2, cylinder.?.world_cylinder.half_height);
                } else {
                    try testing.expectApproxEqAbs(0.5, cylinder.?.color.r(), 0.0001);
                    try testing.expectApproxEqAbs(0.6, cylinder.?.color.g(), 0.0001);
                    try testing.expectApproxEqAbs(0.7, cylinder.?.color.b(), 0.0001);
                    try testing.expectApproxEqAbs(0.8, cylinder.?.color.a(), 0.0001);
                    try testing.expectEqual(2, cylinder.?.thickness);
                    const f_index: f32 = @floatFromInt(index - 14);
                    try testing.expectEqual(f_index + 1.1, cylinder.?.world_cylinder.radius);
                    try testing.expectEqual(f_index + 1.2, cylinder.?.world_cylinder.half_height);
                }
            }
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should not draw cylinders for the player disabled in settings" {
    const Test = struct {
        var hurt_cylinders: HurtCylinders = .{};
        const settings = model.PlayerSettings(model.HurtCylindersSettings){
            .mode = .id_separated,
            .players = .{ .{ .enabled = true }, .{ .enabled = false } },
        };
        const frame = model.Frame{ .players = .{
            .{
                .hurt_cylinders = .init(.{
                    .left_ankle = .{ .cylinder = .{ .center = .fill(1), .radius = 1.1, .half_height = 1.2 } },
                    .right_ankle = .{ .cylinder = .{ .center = .fill(2), .radius = 2.1, .half_height = 2.2 } },
                    .left_hand = .{ .cylinder = .{ .center = .fill(3), .radius = 3.1, .half_height = 3.2 } },
                    .right_hand = .{ .cylinder = .{ .center = .fill(4), .radius = 4.1, .half_height = 4.2 } },
                    .left_knee = .{ .cylinder = .{ .center = .fill(5), .radius = 5.1, .half_height = 5.2 } },
                    .right_knee = .{ .cylinder = .{ .center = .fill(6), .radius = 6.1, .half_height = 6.2 } },
                    .left_elbow = .{ .cylinder = .{ .center = .fill(7), .radius = 7.1, .half_height = 7.2 } },
                    .right_elbow = .{ .cylinder = .{ .center = .fill(8), .radius = 8.1, .half_height = 8.2 } },
                    .head = .{ .cylinder = .{ .center = .fill(9), .radius = 9.1, .half_height = 9.2 } },
                    .left_shoulder = .{ .cylinder = .{ .center = .fill(10), .radius = 10.1, .half_height = 10.2 } },
                    .right_shoulder = .{ .cylinder = .{ .center = .fill(11), .radius = 11.1, .half_height = 11.2 } },
                    .upper_torso = .{ .cylinder = .{ .center = .fill(12), .radius = 12.1, .half_height = 12.2 } },
                    .left_pelvis = .{ .cylinder = .{ .center = .fill(13), .radius = 13.1, .half_height = 13.2 } },
                    .right_pelvis = .{ .cylinder = .{ .center = .fill(14), .radius = 14.1, .half_height = 14.2 } },
                }),
            },
            .{
                .hurt_cylinders = .init(.{
                    .left_ankle = .{ .cylinder = .{ .center = .fill(-1), .radius = 1.1, .half_height = 1.2 } },
                    .right_ankle = .{ .cylinder = .{ .center = .fill(-2), .radius = 2.1, .half_height = 2.2 } },
                    .left_hand = .{ .cylinder = .{ .center = .fill(-3), .radius = 3.1, .half_height = 3.2 } },
                    .right_hand = .{ .cylinder = .{ .center = .fill(-4), .radius = 4.1, .half_height = 4.2 } },
                    .left_knee = .{ .cylinder = .{ .center = .fill(-5), .radius = 5.1, .half_height = 5.2 } },
                    .right_knee = .{ .cylinder = .{ .center = .fill(-6), .radius = 6.1, .half_height = 6.2 } },
                    .left_elbow = .{ .cylinder = .{ .center = .fill(-7), .radius = 7.1, .half_height = 7.2 } },
                    .right_elbow = .{ .cylinder = .{ .center = .fill(-8), .radius = 8.1, .half_height = 8.2 } },
                    .head = .{ .cylinder = .{ .center = .fill(-9), .radius = 9.1, .half_height = 9.2 } },
                    .left_shoulder = .{ .cylinder = .{ .center = .fill(-10), .radius = 10.1, .half_height = 10.2 } },
                    .right_shoulder = .{ .cylinder = .{ .center = .fill(-11), .radius = 11.1, .half_height = 11.2 } },
                    .upper_torso = .{ .cylinder = .{ .center = .fill(-12), .radius = 12.1, .half_height = 12.2 } },
                    .left_pelvis = .{ .cylinder = .{ .center = .fill(-13), .radius = 13.1, .half_height = 13.2 } },
                    .right_pelvis = .{ .cylinder = .{ .center = .fill(-14), .radius = 14.1, .half_height = 14.2 } },
                }),
            },
        } };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .front,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            hurt_cylinders.draw(&shapes, &settings, &frame);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(14, ui.testing_shapes.getAll().len);
            const enabled_cylinders = [14]?*const ui.TestingShapes.Cylinder{
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(2), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(3), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(4), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(5), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(6), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(7), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(8), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(9), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(10), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(11), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(13), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(14), 0.0001),
            };
            const disabled_cylinders = [14]?*const ui.TestingShapes.Cylinder{
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-2), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-3), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-4), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-5), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-6), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-7), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-8), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-9), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-10), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-11), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-12), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-13), 0.0001),
                ui.testing_shapes.findCylinderWithWorldCenter(.fill(-14), 0.0001),
            };
            for (enabled_cylinders) |cylinder| {
                try testing.expect(cylinder != null);
            }
            for (disabled_cylinders) |cylinder| {
                try testing.expectEqual(null, cylinder);
            }
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should draw with correct color and thickness depending on crushing" {
    const Test = struct {
        var hurt_cylinders: HurtCylinders = .{};
        const settings = model.PlayerSettings(model.HurtCylindersSettings){
            .mode = .id_separated,
            .players = .{
                .{
                    .enabled = true,
                    .normal = .{
                        .enabled = true,
                        .normal = .{ .color = .fill(0.01), .thickness = 1 },
                        .high_crushing = .{ .color = .fill(0.02), .thickness = 2 },
                        .low_crushing = .{ .color = .fill(0.03), .thickness = 3 },
                        .invincible = .{ .color = .fill(0.04), .thickness = 4 },
                    },
                    .power_crushing = .{
                        .enabled = true,
                        .normal = .{ .color = .fill(0.05), .thickness = 5 },
                        .high_crushing = .{ .color = .fill(0.06), .thickness = 6 },
                        .low_crushing = .{ .color = .fill(0.07), .thickness = 7 },
                        .invincible = .{ .color = .fill(0.08), .thickness = 8 },
                    },
                },
                .{
                    .enabled = true,
                    .normal = .{
                        .enabled = true,
                        .normal = .{ .color = .fill(0.09), .thickness = 9 },
                        .high_crushing = .{ .color = .fill(0.10), .thickness = 10 },
                        .low_crushing = .{ .color = .fill(0.11), .thickness = 11 },
                        .invincible = .{ .color = .fill(0.12), .thickness = 12 },
                    },
                    .power_crushing = .{
                        .enabled = true,
                        .normal = .{ .color = .fill(0.13), .thickness = 13 },
                        .high_crushing = .{ .color = .fill(0.14), .thickness = 14 },
                        .low_crushing = .{ .color = .fill(0.15), .thickness = 15 },
                        .invincible = .{ .color = .fill(0.16), .thickness = 16 },
                    },
                },
            },
        };
        var frame = model.Frame{ .players = .{
            .{
                .hurt_cylinders = .initFill(.{
                    .cylinder = .{ .center = .fill(1), .radius = 1.1, .half_height = 1.2 },
                }),
            },
            .{
                .hurt_cylinders = .initFill(.{
                    .cylinder = .{ .center = .fill(-1), .radius = 1.1, .half_height = 1.2 },
                }),
            },
        } };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .front,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            hurt_cylinders.draw(&shapes, &settings, &frame);
        }

        fn testFunction(ctx: sdk.ui.TestContext) !void {
            frame.players[0].crushing = .{ .power_crushing = false };
            frame.players[1].crushing = .{ .power_crushing = true };
            ctx.yield(1);
            var player_1_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001);
            var player_2_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001);
            try testing.expect(player_1_cylinder != null);
            try testing.expect(player_2_cylinder != null);
            try testing.expectApproxEqAbs(0.01, player_1_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.01, player_1_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.01, player_1_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.01, player_1_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(1, player_1_cylinder.?.thickness);
            try testing.expectApproxEqAbs(0.13, player_2_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.13, player_2_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.13, player_2_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.13, player_2_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(13, player_2_cylinder.?.thickness);

            frame.players[0].crushing = .{ .high_crushing = true, .power_crushing = false };
            frame.players[1].crushing = .{ .high_crushing = true, .power_crushing = true };
            ctx.yield(1);
            player_1_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001);
            player_2_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001);
            try testing.expect(player_1_cylinder != null);
            try testing.expect(player_2_cylinder != null);
            try testing.expectApproxEqAbs(0.02, player_1_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.02, player_1_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.02, player_1_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.02, player_1_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(2, player_1_cylinder.?.thickness);
            try testing.expectApproxEqAbs(0.14, player_2_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.14, player_2_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.14, player_2_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.14, player_2_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(14, player_2_cylinder.?.thickness);

            frame.players[0].crushing = .{ .low_crushing = true, .power_crushing = false };
            frame.players[1].crushing = .{ .low_crushing = true, .power_crushing = true };
            ctx.yield(1);
            player_1_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001);
            player_2_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001);
            try testing.expect(player_1_cylinder != null);
            try testing.expect(player_2_cylinder != null);
            try testing.expectApproxEqAbs(0.03, player_1_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.03, player_1_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.03, player_1_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.03, player_1_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(3, player_1_cylinder.?.thickness);
            try testing.expectApproxEqAbs(0.15, player_2_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.15, player_2_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.15, player_2_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.15, player_2_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(15, player_2_cylinder.?.thickness);

            frame.players[0].crushing = .{ .invincibility = true, .power_crushing = false };
            frame.players[1].crushing = .{ .invincibility = true, .power_crushing = true };
            ctx.yield(1);
            player_1_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(1), 0.0001);
            player_2_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(-1), 0.0001);
            try testing.expect(player_1_cylinder != null);
            try testing.expect(player_2_cylinder != null);
            try testing.expectApproxEqAbs(0.04, player_1_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.04, player_1_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.04, player_1_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.04, player_1_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(4, player_1_cylinder.?.thickness);
            try testing.expectApproxEqAbs(0.16, player_2_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(0.16, player_2_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(0.16, player_2_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(0.16, player_2_cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(16, player_2_cylinder.?.thickness);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should draw connected and lingering cylinders correctly" {
    const Test = struct {
        var hurt_cylinders: HurtCylinders = .{};
        var frame = model.Frame{ .players = .{ .{
            .hurt_cylinders = .init(.{
                .left_ankle = .{ .cylinder = .{ .center = .fill(1), .radius = 0, .half_height = 0 } },
                .right_ankle = .{ .cylinder = .{ .center = .fill(2), .radius = 0, .half_height = 0 } },
                .left_hand = .{ .cylinder = .{ .center = .fill(3), .radius = 0, .half_height = 0 } },
                .right_hand = .{ .cylinder = .{ .center = .fill(4), .radius = 0, .half_height = 0 } },
                .left_knee = .{ .cylinder = .{ .center = .fill(5), .radius = 0, .half_height = 0 } },
                .right_knee = .{ .cylinder = .{ .center = .fill(6), .radius = 0, .half_height = 0 } },
                .left_elbow = .{ .cylinder = .{ .center = .fill(7), .radius = 0, .half_height = 0 } },
                .right_elbow = .{ .cylinder = .{ .center = .fill(8), .radius = 0, .half_height = 0 } },
                .head = .{ .cylinder = .{ .center = .fill(9), .radius = 0, .half_height = 0 } },
                .left_shoulder = .{ .cylinder = .{ .center = .fill(10), .radius = 0, .half_height = 0 } },
                .right_shoulder = .{ .cylinder = .{ .center = .fill(11), .radius = 0, .half_height = 0 } },
                .upper_torso = .{ .cylinder = .{ .center = .fill(12), .radius = 0, .half_height = 0 } },
                .left_pelvis = .{ .cylinder = .{ .center = .fill(13), .radius = 0, .half_height = 0 } },
                .right_pelvis = .{ .cylinder = .{ .center = .fill(14), .radius = 0, .half_height = 0 } },
            }),
        }, .{} } };
        const settings = model.PlayerSettings(model.HurtCylindersSettings){
            .mode = .id_separated,
            .players = .{ .{
                .enabled = true,
                .normal = .{
                    .enabled = true,
                    .normal = .{ .color = .fill(1), .thickness = 1 },
                    .high_crushing = .{ .color = .fill(1), .thickness = 1 },
                    .low_crushing = .{ .color = .fill(1), .thickness = 1 },
                    .invincible = .{ .color = .fill(1), .thickness = 1 },
                },
                .connected = .{ .enabled = true, .color = .fill(2), .thickness = 2, .duration = 10 },
                .lingering = .{ .enabled = true, .color = .fill(3), .thickness = 3, .duration = 20 },
            }, .{} },
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .front,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            hurt_cylinders.draw(&shapes, &settings, &frame);
        }

        fn testFunction(ctx: sdk.ui.TestContext) !void {
            try testing.expectEqual(14, ui.testing_shapes.getAll().len);
            const cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001);
            try testing.expect(cylinder != null);
            try testing.expectApproxEqAbs(1, cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(1, cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(1, cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(1, cylinder.?.color.a(), 0.0001);
            try testing.expectEqual(1, cylinder.?.thickness);

            frame.players[0].hurt_cylinders.?.getPtr(.upper_torso).flags.is_connected = true;
            hurt_cylinders.processFrame(&settings, &frame);
            frame.players[0].hurt_cylinders.?.getPtr(.upper_torso).cylinder.center = .fill(12.5);
            ctx.yield(1);
            try testing.expectEqual(15, ui.testing_shapes.getAll().len);
            var connected_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12.5), 0.0001);
            var lingering_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001);
            try testing.expect(connected_cylinder != null);
            try testing.expect(lingering_cylinder != null);
            try testing.expectApproxEqAbs(2, connected_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(2, connected_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(2, connected_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(2, connected_cylinder.?.color.a(), 0.0001);
            try testing.expectApproxEqAbs(2, connected_cylinder.?.thickness, 0.0001);
            try testing.expectApproxEqAbs(3, lingering_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(3, lingering_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(3, lingering_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(3, lingering_cylinder.?.color.a(), 0.0001);
            try testing.expectApproxEqAbs(3, lingering_cylinder.?.thickness, 0.0001);

            frame.players[0].hurt_cylinders.?.getPtr(.upper_torso).flags.is_connected = false;
            hurt_cylinders.update(8);
            ctx.yield(1);
            try testing.expectEqual(15, ui.testing_shapes.getAll().len);
            connected_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12.5), 0.0001);
            lingering_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001);
            try testing.expect(connected_cylinder != null);
            try testing.expect(lingering_cylinder != null);
            try testing.expectApproxEqAbs(1.5, connected_cylinder.?.color.r(), 0.4);
            try testing.expectApproxEqAbs(1.5, connected_cylinder.?.color.g(), 0.4);
            try testing.expectApproxEqAbs(1.5, connected_cylinder.?.color.b(), 0.4);
            try testing.expectApproxEqAbs(1.5, connected_cylinder.?.color.a(), 0.4);
            try testing.expectApproxEqAbs(1.5, connected_cylinder.?.thickness, 0.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.r(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.g(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.b(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.a(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.thickness, 1.4);

            hurt_cylinders.update(10);
            ctx.yield(1);
            try testing.expectEqual(15, ui.testing_shapes.getAll().len);
            connected_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12.5), 0.0001);
            lingering_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001);
            try testing.expect(connected_cylinder != null);
            try testing.expect(lingering_cylinder != null);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.a(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.thickness, 0.0001);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.r(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.g(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.b(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.color.a(), 1.4);
            try testing.expectApproxEqAbs(2, lingering_cylinder.?.thickness, 1.4);

            hurt_cylinders.update(10);
            ctx.yield(1);
            try testing.expectEqual(14, ui.testing_shapes.getAll().len);
            connected_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12.5), 0.0001);
            lingering_cylinder = ui.testing_shapes.findCylinderWithWorldCenter(.fill(12), 0.0001);
            try testing.expect(connected_cylinder != null);
            try testing.expectEqual(null, lingering_cylinder);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.r(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.g(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.b(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.color.a(), 0.0001);
            try testing.expectApproxEqAbs(1, connected_cylinder.?.thickness, 0.0001);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}
