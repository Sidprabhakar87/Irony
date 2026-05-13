const std = @import("std");
const imgui = @import("imgui");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const ui = @import("../ui/root.zig");

pub fn drawForwardDirections(
    shapes: *const ui.Shapes,
    settings: *const model.PlayerSettings(model.ForwardDirectionSettings),
    frame: *const model.Frame,
) void {
    if (shapes.* == ._2d and shapes._2d.direction != .top) {
        return;
    }
    for (model.PlayerId.all) |player_id| {
        const player_settings = settings.getById(frame, player_id);
        if (!player_settings.enabled) {
            continue;
        }
        const player = frame.getPlayerById(player_id);
        const position = player.getPosition() orelse continue;
        const rotation = player.rotation orelse continue;
        const floor_z = frame.floor_z orelse position.z();
        const floor_position = position.swizzle("xy").extend(floor_z);
        const delta = sdk.math.Vec3.plus_x.scale(player_settings.length).rotateZ(rotation);
        const line = sdk.math.LineSegment3{
            .point_1 = floor_position,
            .point_2 = floor_position.add(delta),
        };
        shapes.drawLine(line, player_settings.color, player_settings.thickness, 0);
    }
}

const testing = std.testing;

test "should draw lines correctly when direction is top" {
    const Test = struct {
        const settings = model.PlayerSettings(model.ForwardDirectionSettings){
            .mode = .id_separated,
            .players = .{
                .{ .enabled = true, .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), .length = 1, .thickness = 2 },
                .{ .enabled = true, .color = .fromArray(.{ 0.5, 0.6, 0.7, 0.8 }), .length = 3, .thickness = 4 },
            },
        };
        const frame = model.Frame{
            .floor_z = -1,
            .players = .{
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 1, 2, 3 }), .radius = 0 }),
                    .rotation = 0,
                },
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 4, 5, 6 }), .radius = 0 }),
                    .rotation = 0.5 * std.math.pi,
                },
            },
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .top,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            drawForwardDirections(&shapes, &settings, &frame);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(2, ui.testing_shapes.getAll().len);
            const line_1 = ui.testing_shapes.findLineWithWorldPoints(
                .fromArray(.{ 1, 2, -1 }),
                .fromArray(.{ 2, 2, -1 }),
                0.0001,
            );
            const line_2 = ui.testing_shapes.findLineWithWorldPoints(
                .fromArray(.{ 4, 5, -1 }),
                .fromArray(.{ 4, 8, -1 }),
                0.0001,
            );
            try testing.expect(line_1 != null);
            try testing.expect(line_2 != null);
            try testing.expectEqual(.{ 0.1, 0.2, 0.3, 0.4 }, line_1.?.color.array);
            try testing.expectEqual(.{ 0.5, 0.6, 0.7, 0.8 }, line_2.?.color.array);
            try testing.expectEqual(2, line_1.?.thickness);
            try testing.expectEqual(4, line_2.?.thickness);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should not draw anything when direction is not top" {
    const Test = struct {
        const settings = model.PlayerSettings(model.ForwardDirectionSettings){
            .mode = .id_separated,
            .players = .{ .{}, .{} },
        };
        const frame = model.Frame{
            .floor_z = -1,
            .players = .{
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 1, 2, 3 }), .radius = 0 }),
                    .rotation = 0,
                },
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 4, 5, 6 }), .radius = 0 }),
                    .rotation = 0,
                },
            },
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const front_shapes = ui.Shapes{ ._2d = .{
                .direction = .front,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            drawForwardDirections(&front_shapes, &settings, &frame);
            const side_shapes = ui.Shapes{ ._2d = .{
                .direction = .side,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            drawForwardDirections(&side_shapes, &settings, &frame);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(0, ui.testing_shapes.getAll().len);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should not draw the line for the player disabled in settings" {
    const Test = struct {
        const settings = model.PlayerSettings(model.ForwardDirectionSettings){
            .mode = .id_separated,
            .players = .{ .{ .enabled = true, .length = 1 }, .{ .enabled = false, .length = 1 } },
        };
        const frame = model.Frame{
            .floor_z = -1,
            .players = .{
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 1, 2, 3 }), .radius = 0 }),
                    .rotation = 0,
                },
                .{
                    .collision_spheres = .initFill(.{ .center = .fromArray(.{ 4, 5, 6 }), .radius = 0 }),
                    .rotation = 0,
                },
            },
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            const shapes = ui.Shapes{ ._2d = .{
                .direction = .top,
                .matrix = .identity,
                .inverse_matrix = .identity,
            } };
            drawForwardDirections(&shapes, &settings, &frame);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(1, ui.testing_shapes.getAll().len);
            const line_1 = ui.testing_shapes.findLineWithWorldPoints(
                .fromArray(.{ 1, 2, -1 }),
                .fromArray(.{ 2, 2, -1 }),
                0.0001,
            );
            const line_2 = ui.testing_shapes.findLineWithWorldPoints(
                .fromArray(.{ 4, 5, -1 }),
                .fromArray(.{ 5, 5, -1 }),
                0.0001,
            );
            try testing.expect(line_1 != null);
            try testing.expectEqual(null, line_2);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}
