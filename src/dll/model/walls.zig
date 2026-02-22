const std = @import("std");
const sdk = @import("../../sdk/root.zig");

pub const Wall = struct {
    edge_1: sdk.math.Vec2,
    edge_2_index: u8,
    properties: WallProperties = .{},
};

pub const WallProperties = struct {
    gimmick: WallGimmick = .none,
    flags: WallFlags = .{},
};

pub const WallGimmick = enum(u3) {
    none = 0,
    wall_break = 1,
    balcony_break = 2,
    wall_blast = 3,
    wall_bound = 4,
};

pub const WallFlags = packed struct(u4) {
    hard: bool = false,
    damaged: bool = false,
    gimmick_used_up: bool = false,
    broken: bool = false,
};

pub const Walls = struct {
    buffer: [max_len]Wall = std.mem.zeroes([max_len]Wall),
    len: usize = 0,

    const Self = @This();

    pub const max_len = 24;

    pub fn asSlice(self: anytype) sdk.misc.SelfBasedSlice(@TypeOf(self), Self, Wall) {
        return self.buffer[0..self.len];
    }
};

const testing = std.testing;

test "Walls.asSlice should return correct value" {
    const wall_1 = Wall{ .edge_1 = .fromArray(.{ 1, 2 }), .edge_2_index = 1 };
    const wall_2 = Wall{ .edge_1 = .fromArray(.{ 3, 4 }), .edge_2_index = 0 };
    var walls = Walls{};
    walls.buffer[0] = wall_1;
    walls.buffer[1] = wall_2;
    walls.len = 2;
    try testing.expectEqualSlices(Wall, &.{ wall_1, wall_2 }, walls.asSlice());
}
