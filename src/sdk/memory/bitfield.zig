const std = @import("std");

pub fn BitfieldMember(comptime BackingInt: type) type {
    return struct {
        name: [:0]const u8,
        backing_value: BackingInt,
        default_value: bool = false,
    };
}

pub fn Bitfield(comptime BackingInt: type, comptime members: []const BitfieldMember(BackingInt)) type {
    @setEvalBranchQuota(3000);

    const number_of_bits = @bitSizeOf(BackingInt);
    var fields: [number_of_bits]std.builtin.Type.StructField = undefined;
    var next_member_index: usize = 0;
    var padding_field_name_buffer: [8]u8 = undefined;
    padding_field_name_buffer[0] = '_';

    for (&fields, 0..) |*field, bit_index| {
        const backing_value = 1 << bit_index;
        const next_member: ?*const BitfieldMember(BackingInt) = switch (next_member_index < members.len) {
            true => &members[next_member_index],
            else => null,
        };
        if (next_member) |member| {
            if (member.backing_value == backing_value) {
                field.* = .{
                    .name = member.name,
                    .type = bool,
                    .default_value_ptr = if (member.default_value == true) &true else &false,
                    .is_comptime = false,
                    .alignment = 0,
                };
                next_member_index += 1;
                continue;
            } else if (member.backing_value < backing_value) {
                if (std.math.isPowerOfTwo(next_member.?.backing_value)) {
                    @compileError(std.fmt.comptimePrint(
                        "Failed to create a bitfield type. Member \"{s}\" is out of order.",
                        .{member.name},
                    ));
                } else {
                    @compileError(std.fmt.comptimePrint(
                        "Failed to create a bitfield type. Member \"{s}\" has non power of two backing value: {}",
                        .{ member.name, member.backing_value },
                    ));
                }
            }
        }
        const int_len = std.fmt.printInt(padding_field_name_buffer[1..], bit_index, 10, .lower, .{});
        padding_field_name_buffer[int_len + 1] = 0;
        const name_final = padding_field_name_buffer[0..(int_len + 1) :0].*;
        field.* = .{
            .name = &name_final,
            .type = bool,
            .default_value_ptr = &false,
            .is_comptime = false,
            .alignment = 0,
        };
    }

    return @Type(.{ .@"struct" = .{
        .layout = .@"packed",
        .backing_integer = BackingInt,
        .fields = &fields,
        .decls = &.{},
        .is_tuple = false,
    } });
}

const testing = std.testing;

test "should have same size as the backing integer" {
    try testing.expectEqual(@sizeOf(u8), @sizeOf(Bitfield(u8, &.{})));
    try testing.expectEqual(@sizeOf(u16), @sizeOf(Bitfield(u16, &.{})));
    try testing.expectEqual(@sizeOf(u32), @sizeOf(Bitfield(u32, &.{})));
    try testing.expectEqual(@sizeOf(u64), @sizeOf(Bitfield(u64, &.{})));
}

test "should place members at correct bits" {
    const Bits = Bitfield(u16, &.{
        .{ .name = "bit_3", .backing_value = 8 },
        .{ .name = "bit_6", .backing_value = 64 },
        .{ .name = "bit_10", .backing_value = 1024 },
    });
    const bit_3: u16 = @bitCast(Bits{ .bit_3 = true });
    const bit_6: u16 = @bitCast(Bits{ .bit_6 = true });
    const bit_10: u16 = @bitCast(Bits{ .bit_10 = true });
    try testing.expectEqual(8, bit_3);
    try testing.expectEqual(64, bit_6);
    try testing.expectEqual(1024, bit_10);
}

test "should have correctly working default member values" {
    const Bits = Bitfield(u16, &.{
        .{ .name = "bit_3", .backing_value = 8, .default_value = false },
        .{ .name = "bit_6", .backing_value = 64 },
        .{ .name = "bit_10", .backing_value = 1024, .default_value = true },
    });
    const default_value: u16 = @bitCast(Bits{});
    try testing.expectEqual(1024, default_value);
}
