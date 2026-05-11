const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const build_info = @import("build_info");

const source_code = @embedFile("lines.hlsl");

pub fn Lines(comptime rendering_api: build_info.RenderingApi) type {
    const dx = switch (rendering_api) {
        .dx11 => sdk.dx11,
        .dx12 => sdk.dx12,
    };
    return struct {
        shader: ?Shader,
        vertices: sdk.misc.BoundedArray(256, Vertex, undefined, false),

        const Self = @This();
        const Shader = dx.Shader(Vertex, void, Constants);
        const Vertex = extern struct {
            position: sdk.math.Vec3,
            _padding: f32 = 0,
            color: sdk.math.Vec4,
        };
        const Constants = extern struct {
            world_to_clip: sdk.math.Mat4,
        };

        pub fn init(context_maybe: ?*const dx.Context) Self {
            const shader = if (context_maybe) |context| Shader.init(context, &.{
                .source_code = source_code,
                .primitive_topology = .line_list,
            }) catch |err| block: {
                sdk.misc.error_context.append("Failed to initialize line rendering shader.", .{});
                sdk.misc.error_context.logError(err);
                break :block null;
            } else null;
            return .{
                .shader = shader,
                .vertices = .empty,
            };
        }

        pub fn deinit(self: *Self, context_maybe: ?*const dx.Context) void {
            if (context_maybe) |context| {
                if (self.shader) |*shader| {
                    shader.deinit(context);
                }
            }
        }

        pub fn add(self: *Self, line: *const sdk.math.LineSegment3, color: sdk.math.Vec4) void {
            self.vertices.append(.{ .position = line.point_1, .color = color }) catch |err| {
                sdk.misc.error_context.append("Failed to append point 1 vertex to array.", .{});
                sdk.misc.error_context.append("Failed to add a line to line renderer.", .{});
                sdk.misc.error_context.logError(err);
                return;
            };
            self.vertices.append(.{ .position = line.point_2, .color = color }) catch |err| {
                sdk.misc.error_context.append("Failed to append point 2 vertex to array.", .{});
                sdk.misc.error_context.append("Failed to add a line to line renderer.", .{});
                sdk.misc.error_context.logError(err);
                return;
            };
        }

        pub fn clear(self: *Self) void {
            self.vertices.len = 0;
        }

        pub fn render(
            self: *Self,
            context: *const dx.Context,
            buffer_context: *const dx.BufferContext,
            world_to_clip: sdk.math.Mat4,
        ) void {
            const shader: *Shader = if (self.shader) |*s| s else return;
            shader.setVertices(context, self.vertices.asSlice()) catch |err| {
                sdk.misc.error_context.append("Failed to set shader vertices.", .{});
                sdk.misc.error_context.append("Failed to render lines.", .{});
                sdk.misc.error_context.logError(err);
                return;
            };
            shader.setConstants(context, &.{ .world_to_clip = world_to_clip }) catch |err| {
                sdk.misc.error_context.append("Failed to set shader constants.", .{});
                sdk.misc.error_context.append("Failed to render lines.", .{});
                sdk.misc.error_context.logError(err);
                return;
            };
            shader.draw(context, buffer_context) catch |err| {
                sdk.misc.error_context.append("Failed to execute shader draw.", .{});
                sdk.misc.error_context.append("Failed to render lines.", .{});
                sdk.misc.error_context.logError(err);
                return;
            };
        }
    };
}
