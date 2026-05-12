const std = @import("std");
const build_info = @import("build_info");
const sdk = @import("../../sdk/root.zig");
const game = @import("../game/root.zig");
const rendering = @import("root.zig");

pub const Shapes = struct {
    array: sdk.misc.BoundedArray(64, Shape, undefined, false) = .empty,

    const Self = @This();
    pub const Shape = struct {
        geometry: Geometry,
        color: sdk.math.Vec4,
        thickness: f32,
    };
    pub const Geometry = union(enum) {
        point: sdk.math.Vec3,
        line: sdk.math.LineSegment3,
        sphere: sdk.math.Sphere,
        cylinder: sdk.math.Cylinder,
    };

    const circle_segments = 32;

    pub fn clear(self: *Self) void {
        self.array.len = 0;
    }

    pub fn addPoint(self: *Self, point: sdk.math.Vec3, color: sdk.math.Vec4, thickness: f32) void {
        self.add(.{
            .geometry = .{ .point = point },
            .color = color,
            .thickness = thickness,
        });
    }

    pub fn addLine(self: *Self, line: sdk.math.LineSegment3, color: sdk.math.Vec4, thickness: f32) void {
        self.add(.{
            .geometry = .{ .line = line },
            .color = color,
            .thickness = thickness,
        });
    }

    pub fn addSphere(self: *Self, sphere: sdk.math.Sphere, color: sdk.math.Vec4, thickness: f32) void {
        self.add(.{
            .geometry = .{ .sphere = sphere },
            .color = color,
            .thickness = thickness,
        });
    }

    pub fn addCylinder(self: *Self, cylinder: sdk.math.Cylinder, color: sdk.math.Vec4, thickness: f32) void {
        self.add(.{
            .geometry = .{ .cylinder = cylinder },
            .color = color,
            .thickness = thickness,
        });
    }

    fn add(self: *Self, shape: Shape) void {
        self.array.append(shape) catch |err| {
            sdk.misc.error_context.append("Failed to add the shape to bounded array.", .{});
            sdk.misc.error_context.append("Failed to add a shape to shape renderer.", .{});
            sdk.misc.error_context.logError(err);
            return;
        };
    }

    pub fn render(self: *const Self, lines: anytype, camera_position: sdk.math.Vec3) void {
        const shapes: []const Shape = self.array.asSlice();
        for (shapes) |*shape| {
            switch (shape.geometry) {
                .point => |point| renderPoint(point, shape.color, shape.thickness, lines),
                .line => |line| renderLine(line, shape.color, shape.thickness, lines),
                .sphere => |sphere| renderSphere(sphere, shape.color, shape.thickness, lines, camera_position),
                .cylinder => |cylinder| renderCylinder(cylinder, shape.color, shape.thickness, lines, camera_position),
            }
        }
    }

    fn renderPoint(
        point: sdk.math.Vec3,
        color: sdk.math.Vec4,
        thickness: f32,
        lines: anytype,
    ) void {
        const delta = sdk.math.Vec3.plus_x.scale(0.001);
        lines.add(.{ .point_1 = point.add(delta), .point_2 = point.subtract(delta) }, color, thickness);
    }

    fn renderLine(
        line: sdk.math.LineSegment3,
        color: sdk.math.Vec4,
        thickness: f32,
        lines: anytype,
    ) void {
        lines.add(line, color, thickness);
    }

    fn renderSphere(
        sphere: sdk.math.Sphere,
        color: sdk.math.Vec4,
        thickness: f32,
        lines: anytype,
        camera_position: sdk.math.Vec3,
    ) void {
        const camera_to_sphere = camera_position.distanceTo(sphere.center);
        if (camera_to_sphere < sphere.radius) {
            return; // Camera is inside the sphere.
        }
        const camera_to_edge = std.math.sqrt(
            (camera_to_sphere * camera_to_sphere) - (sphere.radius * sphere.radius),
        );
        const circle_radius = sphere.radius * camera_to_edge / camera_to_sphere;
        const camera_to_circle = circle_radius * camera_to_edge / sphere.radius;

        const forward = sphere.center.subtract(camera_position).normalize();
        const arbitrary: sdk.math.Vec3 = if (forward.z() < 0.999) .plus_z else .plus_x;
        const right = arbitrary.cross(forward).normalize();
        const up = forward.cross(right);
        const circle_center = camera_position.add(forward.scale(camera_to_circle));

        for (0..circle_segments) |index| {
            const i_1: f32 = @floatFromInt(index);
            const i_2: f32 = @floatFromInt(index + 1);
            const n: f32 = @floatFromInt(circle_segments);
            const angle_1 = 2 * std.math.pi * i_1 / n;
            const angle_2 = 2 * std.math.pi * i_2 / n;
            const point_1 = right.scale(std.math.cos(angle_1))
                .add(up.scale(std.math.sin(angle_1)))
                .scale(circle_radius)
                .add(circle_center);
            const point_2 = right.scale(std.math.cos(angle_2))
                .add(up.scale(std.math.sin(angle_2)))
                .scale(circle_radius)
                .add(circle_center);
            lines.add(.{ .point_1 = point_1, .point_2 = point_2 }, color, thickness);
        }
    }

    fn renderCylinder(
        cylinder: sdk.math.Cylinder,
        color: sdk.math.Vec4,
        thickness: f32,
        lines: anytype,
        camera_position: sdk.math.Vec3,
    ) void {
        const radius = cylinder.radius;
        const center = cylinder.center;
        const half_height = cylinder.half_height;

        const camera_to_center = camera_position.swizzle("xy").distanceTo(center.swizzle("xy"));
        if (camera_to_center > radius) {
            const camera_to_edge = std.math.sqrt(
                (camera_to_center * camera_to_center) - (radius * radius),
            );
            const edge_offset = radius * camera_to_edge / camera_to_center;
            const camera_to_edges_base = edge_offset * camera_to_edge / radius;

            const forward = center.swizzle("xy").subtract(camera_position.swizzle("xy")).normalize();
            const right = sdk.math.Vec2.fromArray(.{ -forward.y(), forward.x() });
            const base = camera_position.swizzle("xy").add(forward.scale(camera_to_edges_base));
            const offset = right.scale(edge_offset);

            const line_1 = sdk.math.LineSegment3{
                .point_1 = base.add(offset).extend(center.z() + half_height),
                .point_2 = base.add(offset).extend(center.z() - half_height),
            };
            const line_2 = sdk.math.LineSegment3{
                .point_1 = base.subtract(offset).extend(center.z() + half_height),
                .point_2 = base.subtract(offset).extend(center.z() - half_height),
            };
            lines.add(line_1, color, thickness);
            lines.add(line_2, color, thickness);
        }

        for (0..circle_segments) |index| {
            const i_1: f32 = @floatFromInt(index);
            const i_2: f32 = @floatFromInt(index + 1);
            const n: f32 = @floatFromInt(circle_segments);
            const angle_1 = 2 * std.math.pi * i_1 / n;
            const angle_2 = 2 * std.math.pi * i_2 / n;
            const line_1 = sdk.math.LineSegment3{
                .point_1 = center.add(.fromArray(.{
                    radius * std.math.cos(angle_1),
                    radius * std.math.sin(angle_1),
                    half_height,
                })),
                .point_2 = center.add(.fromArray(.{
                    radius * std.math.cos(angle_2),
                    radius * std.math.sin(angle_2),
                    half_height,
                })),
            };
            const line_2 = sdk.math.LineSegment3{
                .point_1 = center.add(.fromArray(.{
                    radius * std.math.cos(angle_1),
                    radius * std.math.sin(angle_1),
                    -half_height,
                })),
                .point_2 = center.add(.fromArray(.{
                    radius * std.math.cos(angle_2),
                    radius * std.math.sin(angle_2),
                    -half_height,
                })),
            };
            lines.add(line_1, color, thickness);
            lines.add(line_2, color, thickness);
        }
    }
};
