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

pub const Walls = sdk.misc.BoundedArray(24, Wall, .{
    .edge_1 = .zero,
    .edge_2_index = 0,
});
