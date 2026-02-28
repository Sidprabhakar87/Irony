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

pub const FloorGimmicks = struct {
    buffer: [max_len]FloorGimmick = std.mem.zeroes([max_len]FloorGimmick),
    len: usize = 0,

    const Self = @This();

    pub const max_len = 5;

    pub fn asSlice(self: anytype) sdk.misc.SelfBasedSlice(@TypeOf(self), Self, FloorGimmick) {
        return self.buffer[0..self.len];
    }
};

const testing = std.testing;

test "FloorGimmicks.asSlice should return correct value" {
    const gimmick_1 = FloorGimmick{
        .rectangle = .{ .center = .fromArray(.{ 1, 2 }), .half_size = .fromArray(.{ 3, 4 }), .rotation = 5 },
        .properties = .{ .type = .floor_break },
    };
    const gimmick_2 = FloorGimmick{
        .rectangle = .{ .center = .fromArray(.{ 5, 6 }), .half_size = .fromArray(.{ 7, 8 }), .rotation = 9 },
        .properties = .{ .type = .floor_blast },
    };
    var gimmicks = FloorGimmicks{};
    gimmicks.buffer[0] = gimmick_1;
    gimmicks.buffer[1] = gimmick_2;
    gimmicks.len = 2;
    try testing.expectEqualSlices(FloorGimmick, &.{ gimmick_1, gimmick_2 }, gimmicks.asSlice());
}
