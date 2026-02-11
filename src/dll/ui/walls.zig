const std = @import("std");
const imgui = @import("imgui");
const sdk = @import("../../sdk/root.zig");
const model = @import("../model/root.zig");
const ui = @import("../ui/root.zig");

pub fn drawWalls(frame: *const model.Frame, direction: ui.ViewDirection, matrix: sdk.math.Mat4) void {
    if (direction != .top) {
        return;
    }
    const color = sdk.math.Vec4.fromArray(.{ 0, 1, 0, 1 });
    const thickness = 1;
    const floor_z = frame.floor_z orelse 0;
    const walls: []const model.Wall = frame.walls.asSlice();
    for (walls, 0..walls.len) |*wall, index| {
        const next_index = if (index + 1 < walls.len) index + 1 else 0;
        const next_wall = walls[next_index];
        const line = sdk.math.LineSegment3{
            .point_1 = wall.edge.extend(floor_z),
            .point_2 = next_wall.edge.extend(floor_z),
        };
        ui.drawLine(line, color, thickness, matrix);
    }
}
