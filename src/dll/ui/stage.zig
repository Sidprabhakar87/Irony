const std = @import("std");
const builtin = @import("builtin");
const imgui = @import("imgui");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const ui = @import("../ui/root.zig");

pub fn drawStage(
    settings: *const model.StageSettings,
    frame: *const model.Frame,
    direction: ui.ViewDirection,
    matrix: sdk.math.Mat4,
    inverse_matrix: sdk.math.Mat4,
) void {
    if (!settings.enabled) {
        return;
    }
    switch (direction) {
        .top => drawStageFromTop(settings, frame, matrix),
        .front, .side => drawStageFromSide(settings, frame, matrix, inverse_matrix),
    }
}

fn drawStageFromTop(settings: *const model.StageSettings, frame: *const model.Frame, matrix: sdk.math.Mat4) void {
    const floor_z = frame.floor_z orelse 0;
    const walls: []const model.Wall = frame.walls.asSlice();
    for (walls) |*wall| {
        if (wall.edge_2_index >= walls.len) {
            continue;
        }
        const line = sdk.math.LineSegment3{
            .point_1 = wall.edge_1.extend(floor_z),
            .point_2 = walls[wall.edge_2_index].edge_1.extend(floor_z),
        };
        drawWall(settings, &wall.properties, line, matrix);
    }
}

fn drawStageFromSide(
    settings: *const model.StageSettings,
    frame: *const model.Frame,
    matrix: sdk.math.Mat4,
    inverse_matrix: sdk.math.Mat4,
) void {
    const walls: []const model.Wall = frame.walls.asSlice();
    const floor_z = frame.floor_z orelse return;

    var window_pos: sdk.math.Vec2 = undefined;
    imgui.igGetCursorScreenPos(window_pos.asImVec());
    var window_size: sdk.math.Vec2 = undefined;
    imgui.igGetContentRegionAvail(window_size.asImVec());
    const top_left = window_pos.extend(0).pointTransform(inverse_matrix);
    const bottom_right = window_pos.add(window_size).extend(0).pointTransform(inverse_matrix);

    if (walls.len == 0) {
        const line = sdk.math.LineSegment3{
            .point_1 = top_left.swizzle("xy").extend(floor_z),
            .point_2 = bottom_right.swizzle("xy").extend(floor_z),
        };
        ui.drawLine(line, settings.foreground.color, settings.foreground.thickness, 0, matrix);
        return;
    }

    const midpoint = getPlayersMidpoint(frame) orelse top_left.add(bottom_right).scale(0.5).swizzle("xy");
    const midpoint_depth = midpoint.extend(floor_z).pointTransform(matrix).z();

    const Edge = struct {
        world_position: sdk.math.Vec3,
        screen_position: sdk.math.Vec3,
    };
    var min_edge: ?Edge = null;
    var max_edge: ?Edge = null;
    for (walls, 0..) |*wall, index| {
        const edge = Edge{
            .world_position = wall.edge_1.extend(floor_z),
            .screen_position = wall.edge_1.extend(floor_z).pointTransform(matrix),
        };
        if (edge.screen_position.z() < midpoint_depth) {
            continue;
        }
        if (min_edge == null or edge.screen_position.x() < min_edge.?.screen_position.x()) {
            min_edge = edge;
        }
        if (max_edge == null or edge.screen_position.x() > max_edge.?.screen_position.x()) {
            max_edge = edge;
        }
        const line = sdk.math.LineSegment3{
            .point_1 = edge.world_position,
            .point_2 = edge.world_position.swizzle("xy").extend(top_left.z()),
        };
        const style = switch (wall.properties.flags.broken) {
            false => for (walls) |*w| {
                if (w.properties.flags.broken and w.edge_2_index == index) {
                    break &settings.broken;
                }
            } else &settings.background,
            true => &settings.broken,
        };
        ui.drawLine(line, style.color, style.thickness, 0, matrix);
    }
    if (min_edge) |min| {
        if (max_edge) |max| {
            const line = sdk.math.LineSegment3{
                .point_1 = min.world_position,
                .point_2 = max.world_position,
            };
            ui.drawLine(line, settings.background.color, settings.background.thickness, 0, matrix);
        }
    }

    const ray = sdk.math.Ray2{
        .origin = midpoint,
        .direction = sdk.math.Vec3.plus_x.directionTransform(inverse_matrix).swizzle("xy"),
    };
    var min_hit: ?sdk.math.RaycastLineSegmentResult.Hit = null;
    var max_hit: ?sdk.math.RaycastLineSegmentResult.Hit = null;
    for (walls) |*wall| {
        if (wall.edge_2_index >= walls.len) {
            continue;
        }
        const wall_line = sdk.math.LineSegment2{
            .point_1 = wall.edge_1,
            .point_2 = walls[wall.edge_2_index].edge_1,
        };
        const hit = switch (sdk.math.raycastLineSegment(ray, wall_line)) {
            .hit => |hit| hit,
            .overlap, .miss => continue,
        };
        if (min_hit == null or hit.t < min_hit.?.t) {
            min_hit = hit;
        }
        if (max_hit == null or hit.t > max_hit.?.t) {
            max_hit = hit;
        }
        const line = switch (hit.t < 0) {
            true => sdk.math.LineSegment3{
                .point_1 = hit.position.extend(floor_z),
                .point_2 = hit.position.extend(top_left.z()),
            },
            false => sdk.math.LineSegment3{
                .point_1 = hit.position.extend(top_left.z()),
                .point_2 = hit.position.extend(floor_z),
            },
        };
        drawWall(settings, &wall.properties, line, matrix);
    }
    if (min_hit) |min| {
        if (max_hit) |max| {
            const line = sdk.math.LineSegment3{
                .point_1 = min.position.extend(floor_z),
                .point_2 = max.position.extend(floor_z),
            };
            ui.drawLine(line, settings.foreground.color, settings.foreground.thickness, 0, matrix);
        }
    }
}

fn getPlayersMidpoint(frame: *const model.Frame) ?sdk.math.Vec2 {
    const player_1_pos = frame.players[0].getPosition();
    const player_2_pos = frame.players[1].getPosition();
    if (player_1_pos) |p1| {
        if (player_2_pos) |p2| {
            return p1.swizzle("xy").add(p2.swizzle("xy")).scale(0.5);
        } else {
            return p1.swizzle("xy");
        }
    } else if (player_2_pos) |p2| {
        return p2.swizzle("xy");
    } else {
        return null;
    }
}

fn drawWall(
    settings: *const model.StageSettings,
    wall_properties: *const model.WallProperties,
    line: sdk.math.LineSegment3,
    matrix: sdk.math.Mat4,
) void {
    const flags = wall_properties.flags;
    if (flags.broken) {
        ui.drawLine(line, settings.broken.color, settings.broken.thickness, 0, matrix);
        return;
    }
    const active_gimmick = switch (flags.gimmick_used_up) {
        true => model.WallGimmick.none,
        false => wall_properties.gimmick,
    };
    const gimmick = settings.wall_gimmicks.getPtrConst(active_gimmick);
    const foreground = &settings.foreground;
    const gimmick_offset = switch (flags.hard and !flags.damaged) {
        false => -0.5 * gimmick.thickness,
        true => (-0.5 * gimmick.thickness) + (-4 * foreground.thickness),
    };
    ui.drawLine(line, gimmick.color, gimmick.thickness, gimmick_offset, matrix);
    ui.drawLine(line, foreground.color, foreground.thickness, 0, matrix);
    if (flags.hard and !flags.damaged) {
        ui.drawLine(line, foreground.color, foreground.thickness, -4 * foreground.thickness, matrix);
    }
}

const testing = std.testing;

fn makeWalls(array: anytype) model.Walls {
    if (@typeInfo(@TypeOf(array)) != .array) {
        const coerced: [array.len]model.Wall = array;
        return makeWalls(coerced);
    }
    if (array.len > model.Walls.max_len) {
        @compileError("Array length exceeds maximum allowed number of walls.");
    }
    var buffer: [model.Walls.max_len]model.Wall = undefined;
    for (array, 0..) |wall, index| {
        buffer[index] = wall;
    }
    return .{ .buffer = buffer, .len = array.len };
}

test "should draw correct lines when direction is top" {
    const Test = struct {
        const settings = model.StageSettings{
            .enabled = true,
            .foreground = .{
                .color = .fromArray(.{ 1, 1, 1, 1 }),
                .thickness = 1,
            },
            .broken = .{
                .color = .fromArray(.{ 0.5, 0.5, 0.5, 0.5 }),
                .thickness = 0.5,
            },
            .wall_gimmicks = .init(.{
                .none = .{
                    .color = .fromArray(.{ 1, 0, 0, 0.5 }),
                    .thickness = 100,
                },
                .wall_break = .{
                    .color = .fromArray(.{ 1, 1, 0, 0.5 }),
                    .thickness = 100,
                },
                .balcony_break = .{
                    .color = .fromArray(.{ 0, 1, 0, 0.5 }),
                    .thickness = 100,
                },
                .wall_blast = .{
                    .color = .fromArray(.{ 0, 1, 1, 0.5 }),
                    .thickness = 100,
                },
                .wall_bound = .{
                    .color = .fromArray(.{ 0, 0, 1, 0.5 }),
                    .thickness = 100,
                },
            }),
        };
        const frame = model.Frame{
            .walls = makeWalls(.{
                model.Wall{
                    .edge_1 = .fromArray(.{ 900, 500 }),
                    .edge_2_index = 1,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 900, 900 }),
                    .edge_2_index = 2,
                    .properties = .{
                        .gimmick = .wall_break,
                        .flags = .{ .broken = true, .damaged = true, .gimmick_used_up = true },
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 100, 900 }),
                    .edge_2_index = 3,
                    .properties = .{
                        .gimmick = .balcony_break,
                        .flags = .{ .hard = true },
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 100, 100 }),
                    .edge_2_index = 4,
                    .properties = .{
                        .gimmick = .wall_blast,
                        .flags = .{ .hard = true, .damaged = true },
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 900, 100 }),
                    .edge_2_index = 0,
                    .properties = .{
                        .gimmick = .wall_blast,
                        .flags = .{ .hard = true, .damaged = true, .gimmick_used_up = true },
                    },
                },
            }),
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            drawStage(&settings, &frame, .top, .identity, .identity);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(10, ui.testing_shapes.getAll().len);

            const wall_1 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 900, 500 }),
                .fromArray(.{ 900, 900 }),
                0.001,
            );
            try testing.expect(wall_1 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), wall_1.?.color);
            try testing.expectEqual(1, wall_1.?.thickness);

            const gimmick_1 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 950, 500 }),
                .fromArray(.{ 950, 900 }),
                0.001,
            );
            try testing.expect(gimmick_1 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 0, 0, 0.5 }), gimmick_1.?.color);
            try testing.expectEqual(100, gimmick_1.?.thickness);

            const wall_2 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 900, 900 }),
                .fromArray(.{ 100, 900 }),
                0.001,
            );
            try testing.expect(wall_2 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0.5, 0.5, 0.5, 0.5 }), wall_2.?.color);
            try testing.expectEqual(0.5, wall_2.?.thickness);

            const wall_3 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 100, 900 }),
                .fromArray(.{ 100, 100 }),
                0.001,
            );
            try testing.expect(wall_3 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), wall_3.?.color);
            try testing.expectEqual(1, wall_3.?.thickness);

            const hard_3 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 96, 900 }),
                .fromArray(.{ 96, 100 }),
                0.001,
            );
            try testing.expect(hard_3 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), hard_3.?.color);
            try testing.expectEqual(1, hard_3.?.thickness);

            const gimmick_3 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 46, 900 }),
                .fromArray(.{ 46, 100 }),
                0.001,
            );
            try testing.expect(gimmick_3 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0, 1, 0, 0.5 }), gimmick_3.?.color);
            try testing.expectEqual(100, gimmick_3.?.thickness);

            const wall_4 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 100, 100 }),
                .fromArray(.{ 900, 100 }),
                0.001,
            );
            try testing.expect(wall_4 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), wall_4.?.color);
            try testing.expectEqual(1, wall_4.?.thickness);

            const gimmick_4 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 100, 50 }),
                .fromArray(.{ 900, 50 }),
                0.001,
            );
            try testing.expect(gimmick_4 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0, 1, 1, 0.5 }), gimmick_4.?.color);
            try testing.expectEqual(100, gimmick_4.?.thickness);

            const wall_5 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 900, 100 }),
                .fromArray(.{ 900, 500 }),
                0.001,
            );
            try testing.expect(wall_5 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), wall_5.?.color);
            try testing.expectEqual(1, wall_5.?.thickness);

            const gimmick_5 = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 950, 100 }),
                .fromArray(.{ 950, 500 }),
                0.001,
            );
            try testing.expect(gimmick_5 != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 0, 0, 0.5 }), gimmick_5.?.color);
            try testing.expectEqual(100, gimmick_5.?.thickness);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should draw correct lines when direction is not top" {
    const Test = struct {
        const settings = model.StageSettings{
            .enabled = true,
            .foreground = .{
                .color = .fromArray(.{ 1, 1, 1, 1 }),
                .thickness = 1,
            },
            .background = .{
                .color = .fromArray(.{ 1, 1, 1, 0.5 }),
                .thickness = 2,
            },
            .broken = .{
                .color = .fromArray(.{ 0.5, 0.5, 0.5, 0.5 }),
                .thickness = 3,
            },
            .wall_gimmicks = .init(.{
                .none = .{
                    .color = .fromArray(.{ 1, 0, 0, 0.5 }),
                    .thickness = 100,
                },
                .wall_break = .{
                    .color = .fromArray(.{ 1, 1, 0, 0.5 }),
                    .thickness = 100,
                },
                .balcony_break = .{
                    .color = .fromArray(.{ 0, 1, 0, 0.5 }),
                    .thickness = 100,
                },
                .wall_blast = .{
                    .color = .fromArray(.{ 0, 1, 1, 0.5 }),
                    .thickness = 100,
                },
                .wall_bound = .{
                    .color = .fromArray(.{ 0, 0, 1, 0.5 }),
                    .thickness = 100,
                },
            }),
        };
        const frame = model.Frame{
            .floor_z = 500,
            .players = .{
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 900, 500, 0 }), .radius = 0 }) },
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 1100, 500, 0 }), .radius = 0 }) },
            },
            .walls = makeWalls(.{
                model.Wall{
                    .edge_1 = .fromArray(.{ 1900, 700 }),
                    .edge_2_index = 1,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 1700, 900 }),
                    .edge_2_index = 2,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 1400, 900 }),
                    .edge_2_index = 3,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 400, 900 }),
                    .edge_2_index = 4,
                    .properties = .{
                        .gimmick = .wall_blast,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 100, 300 }),
                    .edge_2_index = 5,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 300, 100 }),
                    .edge_2_index = 6,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 600, 100 }),
                    .edge_2_index = 7,
                    .properties = .{
                        .gimmick = .none,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 1600, 100 }),
                    .edge_2_index = 0,
                    .properties = .{
                        .gimmick = .wall_bound,
                        .flags = .{},
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 800, 900 }),
                    .edge_2_index = 6,
                    .properties = .{
                        .gimmick = .wall_break,
                        .flags = .{ .hard = true },
                    },
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 1200, 100 }),
                    .edge_2_index = 2,
                    .properties = .{
                        .gimmick = .wall_break,
                        .flags = .{ .broken = true, .damaged = true, .gimmick_used_up = true },
                    },
                },
            }),
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();

            const window_flags = imgui.ImGuiWindowFlags_NoMove |
                imgui.ImGuiWindowFlags_NoResize |
                imgui.ImGuiWindowFlags_NoDecoration |
                imgui.ImGuiWindowFlags_NoSavedSettings;
            imgui.igPushStyleVar_Vec2(imgui.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
            imgui.igPushStyleVar_Vec2(imgui.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
            defer imgui.igPopStyleVar(2);
            imgui.igSetNextWindowPos(.{ .x = 0, .y = 0 }, imgui.ImGuiCond_Always, .{});
            imgui.igSetNextWindowSize(.{ .x = 2000, .y = 1000 }, imgui.ImGuiCond_Always);
            _ = imgui.igBegin("Window", null, window_flags);
            defer imgui.igEnd();

            const matrix = sdk.math.Mat4.fromLookAt(.zero, .plus_y, .plus_z)
                .scale(.fromArray(.{ 1, -1, 1 }))
                .translate(.fromArray(.{ 0, 1000, 0 }));
            const inverse_matrix = matrix.inverse() orelse @panic("Failed to inverse matrix.");

            drawStage(&settings, &frame, .front, matrix, inverse_matrix);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(15, ui.testing_shapes.getAll().len);

            const foreground_floor = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 200, 500 }),
                .fromArray(.{ 1800, 500 }),
                0.001,
            );
            try testing.expect(foreground_floor != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), foreground_floor.?.color);
            try testing.expectEqual(1, foreground_floor.?.thickness);

            const background_floor = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 400, 500 }),
                .fromArray(.{ 1900, 500 }),
                0.001,
            );
            try testing.expect(background_floor != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 0.5 }), background_floor.?.color);
            try testing.expectEqual(2, background_floor.?.thickness);

            const left_foreground_wall = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 200, 0 }),
                .fromArray(.{ 200, 500 }),
                0.001,
            );
            try testing.expect(left_foreground_wall != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), left_foreground_wall.?.color);
            try testing.expectEqual(1, left_foreground_wall.?.thickness);

            const left_gimmick = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 150, 0 }),
                .fromArray(.{ 150, 500 }),
                0.001,
            );
            try testing.expect(left_gimmick != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0, 1, 1, 0.5 }), left_gimmick.?.color);
            try testing.expectEqual(100, left_gimmick.?.thickness);

            const left_background_edge = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 400, 0 }),
                .fromArray(.{ 400, 500 }),
                0.001,
            );
            try testing.expect(left_background_edge != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 0.5 }), left_background_edge.?.color);
            try testing.expectEqual(2, left_background_edge.?.thickness);

            const hard_wall = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 700, 0 }),
                .fromArray(.{ 700, 500 }),
                0.001,
            );
            try testing.expect(hard_wall != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), hard_wall.?.color);
            try testing.expectEqual(1, hard_wall.?.thickness);

            const hard_double = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 696, 0 }),
                .fromArray(.{ 696, 500 }),
                0.001,
            );
            try testing.expect(hard_double != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), hard_double.?.color);
            try testing.expectEqual(1, hard_double.?.thickness);

            const hard_gimmick = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 646, 0 }),
                .fromArray(.{ 646, 500 }),
                0.001,
            );
            try testing.expect(hard_gimmick != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 0, 0.5 }), hard_gimmick.?.color);
            try testing.expectEqual(100, hard_gimmick.?.thickness);

            const hard_background_edge = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 800, 0 }),
                .fromArray(.{ 800, 500 }),
                0.001,
            );
            try testing.expect(hard_background_edge != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 0.5 }), hard_background_edge.?.color);
            try testing.expectEqual(2, hard_background_edge.?.thickness);

            const broken_wall = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1300, 0 }),
                .fromArray(.{ 1300, 500 }),
                0.001,
            );
            try testing.expect(broken_wall != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0.5, 0.5, 0.5, 0.5 }), broken_wall.?.color);
            try testing.expectEqual(3, broken_wall.?.thickness);

            const broken_background_edge = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1400, 0 }),
                .fromArray(.{ 1400, 500 }),
                0.001,
            );
            try testing.expect(broken_background_edge != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0.5, 0.5, 0.5, 0.5 }), broken_background_edge.?.color);
            try testing.expectEqual(3, broken_background_edge.?.thickness);

            const right_background_edge = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1700, 0 }),
                .fromArray(.{ 1700, 500 }),
                0.001,
            );
            try testing.expect(right_background_edge != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 0.5 }), right_background_edge.?.color);
            try testing.expectEqual(2, right_background_edge.?.thickness);

            const right_wall = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1800, 0 }),
                .fromArray(.{ 1800, 500 }),
                0.001,
            );
            try testing.expect(right_wall != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 1 }), right_wall.?.color);
            try testing.expectEqual(1, right_wall.?.thickness);

            const right_gimmick = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1850, 0 }),
                .fromArray(.{ 1850, 500 }),
                0.001,
            );
            try testing.expect(right_gimmick != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0, 0, 1, 0.5 }), right_gimmick.?.color);
            try testing.expectEqual(100, right_gimmick.?.thickness);

            const outside_background_edge = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 1900, 0 }),
                .fromArray(.{ 1900, 500 }),
                0.001,
            );
            try testing.expect(outside_background_edge != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 1, 1, 1, 0.5 }), outside_background_edge.?.color);
            try testing.expectEqual(2, outside_background_edge.?.thickness);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should draw nothing when disabled in settings" {
    const Test = struct {
        const settings = model.StageSettings{ .enabled = false };
        const frame = model.Frame{
            .floor_z = 0,
            .players = .{
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 0, 0, 0 }), .radius = 0 }) },
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 0, 0, 0 }), .radius = 0 }) },
            },
            .walls = makeWalls(.{
                model.Wall{
                    .edge_1 = .fromArray(.{ 0, 0 }),
                    .edge_2_index = 1,
                },
                model.Wall{
                    .edge_1 = .fromArray(.{ 1, 1 }),
                    .edge_2_index = 0,
                },
            }),
        };
        var direction = ui.ViewDirection.top;

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            drawStage(&settings, &frame, direction, .identity, .identity);
        }

        fn testFunction(ctx: sdk.ui.TestContext) !void {
            direction = .top;
            ctx.yield(1);
            try testing.expectEqual(0, ui.testing_shapes.getAll().len);

            direction = .front;
            ctx.yield(1);
            try testing.expectEqual(0, ui.testing_shapes.getAll().len);

            direction = .side;
            ctx.yield(1);
            try testing.expectEqual(0, ui.testing_shapes.getAll().len);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}

test "should draw nothing when no walls and direction is top" {
    const Test = struct {
        const settings = model.StageSettings{ .enabled = true };
        const frame = model.Frame{
            .floor_z = 0,
            .players = .{
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 0, 0, 0 }), .radius = 0 }) },
                .{ .collision_spheres = .initFill(.{ .center = .fromArray(.{ 0, 0, 0 }), .radius = 0 }) },
            },
            .walls = makeWalls(.{}),
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();
            _ = imgui.igBegin("Window", null, 0);
            defer imgui.igEnd();
            drawStage(&settings, &frame, .top, .identity, .identity);
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

test "should draw infinite floor line when no walls and direction is not top" {
    const Test = struct {
        const settings = model.StageSettings{
            .enabled = true,
            .foreground = .{
                .color = .fromArray(.{ 0.1, 0.2, 0.3, 0.4 }),
                .thickness = 1,
            },
        };
        const frame = model.Frame{
            .floor_z = 500,
            .walls = makeWalls(.{}),
        };

        fn guiFunction(_: sdk.ui.TestContext) !void {
            ui.testing_shapes.clear();

            const window_flags = imgui.ImGuiWindowFlags_NoMove |
                imgui.ImGuiWindowFlags_NoResize |
                imgui.ImGuiWindowFlags_NoDecoration |
                imgui.ImGuiWindowFlags_NoSavedSettings;
            imgui.igPushStyleVar_Vec2(imgui.ImGuiStyleVar_WindowPadding, .{ .x = 0, .y = 0 });
            imgui.igPushStyleVar_Vec2(imgui.ImGuiStyleVar_FramePadding, .{ .x = 0, .y = 0 });
            defer imgui.igPopStyleVar(2);
            imgui.igSetNextWindowPos(.{ .x = 0, .y = 0 }, imgui.ImGuiCond_Always, .{});
            imgui.igSetNextWindowSize(.{ .x = 2000, .y = 1000 }, imgui.ImGuiCond_Always);
            _ = imgui.igBegin("Window", null, window_flags);
            defer imgui.igEnd();

            const matrix = sdk.math.Mat4.fromLookAt(.zero, .plus_y, .plus_z)
                .scale(.fromArray(.{ 1, -1, 1 }))
                .translate(.fromArray(.{ 0, 1000, 0 }));
            const inverse_matrix = matrix.inverse() orelse @panic("Failed to inverse matrix.");

            drawStage(&settings, &frame, .front, matrix, inverse_matrix);
        }

        fn testFunction(_: sdk.ui.TestContext) !void {
            try testing.expectEqual(1, ui.testing_shapes.getAll().len);

            const line = ui.testing_shapes.findLineWithScreenPoints(
                .fromArray(.{ 0, 500 }),
                .fromArray(.{ 2000, 500 }),
                0.001,
            );
            try testing.expect(line != null);
            try testing.expectEqual(sdk.math.Vec4.fromArray(.{ 0.1, 0.2, 0.3, 0.4 }), line.?.color);
            try testing.expectEqual(1, line.?.thickness);
        }
    };
    ui.testing_shapes.begin(testing.allocator);
    defer ui.testing_shapes.end();
    const context = try sdk.ui.getTestingContext();
    try context.runTest(.{}, Test.guiFunction, Test.testFunction);
}
