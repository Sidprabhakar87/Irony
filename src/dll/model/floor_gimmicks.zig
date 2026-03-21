const std = @import("std");
const sdk = @import("../../sdk/root.zig");

pub const FloorGimmick = struct {
    rectangle: sdk.math.Rectangle,
    properties: FloorGimmickProperties,
};

pub const FloorGimmickProperties = struct {
    type: FloorGimmickType,
    flags: FloorGimmickFlags = .{},
};

pub const FloorGimmickType = enum(u1) {
    floor_break = 0,
    floor_blast = 1,
};

pub const FloorGimmickFlags = packed struct(u3) {
    hard: bool = false,
    damaged: bool = false,
    used_up: bool = false,
};

pub const FloorGimmicks = sdk.misc.BoundedArray(5, FloorGimmick, .{
    .rectangle = .{ .center = .zero, .half_size = .zero, .rotation = 0 },
    .properties = .{ .type = .floor_break },
});
