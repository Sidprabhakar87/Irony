const std = @import("std");
const misc = @import("root.zig");

pub const bounded_array_tag = opaque {};

pub fn BoundedArray(
    comptime capacity: usize,
    comptime Element: type,
    comptime empty_element: Element,
) type {
    return struct {
        buffer: [capacity]Element,
        len: usize,

        const Self = @This();
        pub const Child = Element;

        pub const max_len = capacity;
        pub const empty = Self{
            .buffer = [1]Element{empty_element} ** capacity,
            .len = 0,
        };
        pub const tag = bounded_array_tag;

        pub fn fromArray(array: anytype) Self {
            if (@typeInfo(@TypeOf(array)) != .array) {
                const coerced: [array.len]Element = array;
                return fromArray(coerced);
            }
            if (array.len > capacity) {
                @compileError(std.fmt.comptimePrint(
                    "The provided array with length {} is larger then capacity: {}",
                    .{ array.len, capacity },
                ));
            }
            var buffer = Self.empty.buffer;
            for (array, 0..) |element, index| {
                buffer[index] = element;
            }
            return .{ .buffer = buffer, .len = array.len };
        }

        pub fn fromSlice(slice: []const Element) !Self {
            if (slice.len > capacity) {
                misc.error_context.new(
                    "The provided slice with length {} is larger then capacity: {}",
                    .{ slice.len, capacity },
                );
                return error.NoSpaceLeft;
            }
            var buffer = Self.empty.buffer;
            for (slice, 0..) |element, index| {
                buffer[index] = element;
            }
            return .{ .buffer = buffer, .len = slice.len };
        }

        pub fn fromSliceTrimmed(slice: []const Element) Self {
            var buffer = Self.empty.buffer;
            var len: usize = 0;
            for (slice) |element| {
                if (len >= capacity) {
                    break;
                }
                buffer[len] = element;
                len += 1;
            }
            return .{ .buffer = buffer, .len = len };
        }

        pub fn append(self: *Self, element: Element) !void {
            if (self.len >= capacity) {
                misc.error_context.new("The bounded array buffer is full.", .{});
                return error.NoSpaceLeft;
            }
            self.buffer[self.len] = element;
            self.len += 1;
        }

        pub fn asSlice(self: anytype) misc.SelfBasedSlice(@TypeOf(self), Self, Element) {
            return self.buffer[0..@min(self.len, self.buffer.len)];
        }
    };
}

const testing = std.testing;

test "empty should contain a buffer with empty elements and have 0 length" {
    const array = BoundedArray(3, u8, 123).empty;
    try testing.expectEqual([3]u8{ 123, 123, 123 }, array.buffer);
    try testing.expectEqual(0, array.len);
}

test "fromArray should return a bounded array with elements from provided array" {
    const array = BoundedArray(4, u8, 123).fromArray(.{ 1, 2 });
    try testing.expectEqual([4]u8{ 1, 2, 123, 123 }, array.buffer);
    try testing.expectEqual(2, array.len);
}

test "fromSlice should return a bounded array with elements from provided slice" {
    const array = try BoundedArray(4, u8, 123).fromSlice(&.{ 1, 2 });
    try testing.expectEqual([4]u8{ 1, 2, 123, 123 }, array.buffer);
    try testing.expectEqual(2, array.len);
}

test "fromSlice should error when slice length exceeds bounded array capacity" {
    try testing.expectError(error.NoSpaceLeft, BoundedArray(2, u8, 123).fromSlice(&.{ 1, 2, 3, 4 }));
}

test "fromSliceTrimmed should return a bounded array with elements from provided slice trimmed to capacity if exceeded" {
    const array_1 = BoundedArray(4, u8, 123).fromSliceTrimmed(&.{ 1, 2 });
    try testing.expectEqual([4]u8{ 1, 2, 123, 123 }, array_1.buffer);
    try testing.expectEqual(2, array_1.len);
    const array_2 = BoundedArray(4, u8, 123).fromSliceTrimmed(&.{ 1, 2, 3, 4, 5, 6 });
    try testing.expectEqual([4]u8{ 1, 2, 3, 4 }, array_2.buffer);
    try testing.expectEqual(4, array_2.len);
}

test "append should add a element to the end of the bounded array when it's not full" {
    var array = BoundedArray(3, u8, 123).empty;
    try testing.expectEqual([3]u8{ 123, 123, 123 }, array.buffer);
    try testing.expectEqual(0, array.len);
    try array.append(1);
    try testing.expectEqual([3]u8{ 1, 123, 123 }, array.buffer);
    try testing.expectEqual(1, array.len);
    try array.append(2);
    try testing.expectEqual([3]u8{ 1, 2, 123 }, array.buffer);
    try testing.expectEqual(2, array.len);
    try array.append(3);
    try testing.expectEqual([3]u8{ 1, 2, 3 }, array.buffer);
    try testing.expectEqual(3, array.len);
}

test "append should error when bounded array is full" {
    var array = BoundedArray(4, u8, 123).fromArray(.{ 1, 2, 3, 4 });
    try testing.expectError(error.NoSpaceLeft, array.append(5));
}

test "asSlice should return slice that point to the non empty elements inside the buffer" {
    const array = BoundedArray(4, u8, 123).fromArray(.{ 1, 2 });
    try testing.expectEqual(array.buffer[0..2], array.asSlice());
}

test "asSlice should return a slice to entire buffer when the bounded array length exceeds its capacity" {
    const array = BoundedArray(4, u8, 123){
        .buffer = .{ 1, 2, 3, 4 },
        .len = 8,
    };
    try testing.expectEqual(array.buffer[0..4], array.asSlice());
}
