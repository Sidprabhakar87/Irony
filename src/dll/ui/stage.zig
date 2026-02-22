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
    const midpoint = getPlayersMidpoint(frame) orelse return;
    const midpoint_depth = midpoint.extend(floor_z).pointTransform(matrix).z();

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
