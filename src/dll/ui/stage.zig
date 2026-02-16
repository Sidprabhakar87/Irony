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
    const floor_z = frame.floor_z orelse return;
    const walls: []const model.Wall = frame.walls.asSlice();
    for (walls, 0..walls.len) |*wall, index| {
        const next_index = if (index + 1 < walls.len) index + 1 else 0;
        const next_wall = walls[next_index];
        const line = sdk.math.LineSegment3{
            .point_1 = wall.edge.extend(floor_z),
            .point_2 = next_wall.edge.extend(floor_z),
        };
        ui.drawLine(line, settings.foreground.color, settings.foreground.thickness, matrix);
    }
}

fn drawStageFromSide(
    settings: *const model.StageSettings,
    frame: *const model.Frame,
    matrix: sdk.math.Mat4,
    inverse_matrix: sdk.math.Mat4,
) void {
    const floor_z = frame.floor_z orelse return;
    const walls: []const model.Wall = frame.walls.asSlice();

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
        ui.drawLine(line, settings.foreground.color, settings.foreground.thickness, matrix);
        return;
    }

    for (walls) |*wall| {
        const world_position = wall.edge;
        const screen_position = world_position.extend(floor_z).pointTransform(matrix);
        if (screen_position.z() < 0.5) {
            continue;
        }
        const line = sdk.math.LineSegment3{
            .point_1 = world_position.extend(floor_z),
            .point_2 = world_position.extend(top_left.z()),
        };
        ui.drawLine(line, settings.background.color, settings.background.thickness, matrix);
    }
    if (findMinMaxEdges(walls, floor_z, matrix)) |edges| {
        const line = sdk.math.LineSegment3{
            .point_1 = edges.left_edge.extend(floor_z),
            .point_2 = edges.right_edge.extend(floor_z),
        };
        ui.drawLine(line, settings.background.color, settings.background.thickness, matrix);
    }

    const center = window_pos.add(window_size).scale(0.5).extend(0.5).pointTransform(inverse_matrix).swizzle("xy");
    const right_direction = sdk.math.Vec3.plus_x.directionTransform(inverse_matrix).swizzle("xy");
    if (findWallsCrossSection(walls, center, right_direction)) |cross_section| {
        const floor = sdk.math.LineSegment3{
            .point_1 = cross_section.left_edge.extend(floor_z),
            .point_2 = cross_section.right_edge.extend(floor_z),
        };
        const left_wall = sdk.math.LineSegment3{
            .point_1 = cross_section.left_edge.extend(floor_z),
            .point_2 = cross_section.left_edge.extend(top_left.z()),
        };
        const right_wall = sdk.math.LineSegment3{
            .point_1 = cross_section.right_edge.extend(floor_z),
            .point_2 = cross_section.right_edge.extend(top_left.z()),
        };
        ui.drawLine(floor, settings.foreground.color, settings.foreground.thickness, matrix);
        ui.drawLine(left_wall, settings.foreground.color, settings.foreground.thickness, matrix);
        ui.drawLine(right_wall, settings.foreground.color, settings.foreground.thickness, matrix);
    }
}

const LeftRightEdge = struct {
    left_edge: sdk.math.Vec2,
    right_edge: sdk.math.Vec2,
};

fn findMinMaxEdges(walls: []const model.Wall, floor_z: f32, matrix: sdk.math.Mat4) ?LeftRightEdge {
    const Edge = struct {
        world_position: sdk.math.Vec3,
        screen_position: sdk.math.Vec3,
    };

    var min_edge: ?Edge = null;
    var max_edge: ?Edge = null;
    for (walls) |*wall| {
        const edge = Edge{
            .world_position = wall.edge.extend(floor_z),
            .screen_position = wall.edge.extend(floor_z).pointTransform(matrix),
        };
        if (edge.screen_position.z() < 0.5) {
            continue;
        }
        if (min_edge == null or edge.screen_position.x() < min_edge.?.screen_position.x()) {
            min_edge = edge;
        }
        if (max_edge == null or edge.screen_position.x() > max_edge.?.screen_position.x()) {
            max_edge = edge;
        }
    }

    if (min_edge) |min| {
        if (max_edge) |max| {
            return .{
                .left_edge = min.world_position.swizzle("xy"),
                .right_edge = max.world_position.swizzle("xy"),
            };
        }
    }
    return null;
}

fn findWallsCrossSection(
    walls: []const model.Wall,
    origin: sdk.math.Vec2,
    right_direction: sdk.math.Vec2,
) ?LeftRightEdge {
    const ray = sdk.math.Ray2{ .origin = origin, .direction = right_direction };

    var min_hit: ?sdk.math.RaycastLineSegmentResult.Hit = null;
    var max_hit: ?sdk.math.RaycastLineSegmentResult.Hit = null;
    for (walls, 0..walls.len) |*wall, index| {
        const next_index = if (index + 1 < walls.len) index + 1 else 0;
        const next_wall = walls[next_index];
        const line = sdk.math.LineSegment2{ .point_1 = wall.edge, .point_2 = next_wall.edge };
        const hit = switch (sdk.math.raycastLineSegment(ray, line)) {
            .hit => |hit| hit,
            .overlap, .miss => continue,
        };
        if (min_hit == null or hit.t < min_hit.?.t) {
            min_hit = hit;
        }
        if (max_hit == null or hit.t > max_hit.?.t) {
            max_hit = hit;
        }
    }

    if (min_hit) |min| {
        if (max_hit) |max| {
            return .{
                .left_edge = min.position,
                .right_edge = max.position,
            };
        }
    }
    return null;
}
