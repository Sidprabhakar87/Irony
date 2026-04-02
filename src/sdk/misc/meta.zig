const std = @import("std");

pub fn SelfBasedPointer(comptime SelfPointer: type, comptime Self: type, comptime Type: type) type {
    return switch (SelfPointer) {
        *Self => *Type,
        *const Self => *const Type,
        else => @compileError(
            "Expected self to be of type \"" ++
                @typeName(*const Self) ++
                "\" or \"" ++
                @typeName(*Self) ++
                "\" but got: " ++
                @typeName(SelfPointer),
        ),
    };
}

pub fn SelfBasedSlice(comptime SelfPointer: type, comptime Self: type, comptime Element: type) type {
    return switch (SelfPointer) {
        *Self => []Element,
        *const Self => []const Element,
        else => @compileError(
            "Expected self to be of type \"" ++
                @typeName(*const Self) ++
                "\" or \"" ++
                @typeName(*Self) ++
                "\" but got: " ++
                @typeName(SelfPointer),
        ),
    };
}

pub fn SelfBasedSentinelSlice(
    comptime SelfPointer: type,
    comptime Self: type,
    comptime Element: type,
    comptime sentinel: Element,
) type {
    return switch (SelfPointer) {
        *Self => [:sentinel]Element,
        *const Self => [:sentinel]const Element,
        else => @compileError(
            "Expected self to be of type \"" ++
                @typeName(*const Self) ++
                "\" or \"" ++
                @typeName(*Self) ++
                "\" but got: " ++
                @typeName(SelfPointer),
        ),
    };
}

pub fn Partial(comptime Struct: type) type {
    const fields: []const std.builtin.Type.StructField = switch (@typeInfo(Struct)) {
        .@"struct" => |info| info.fields,
        else => @compileError("Partial expects a struct type as argument."),
    };
    var partial_fields: [fields.len]std.builtin.Type.StructField = undefined;
    for (fields, 0..) |*field, index| {
        const optional = std.builtin.Type.Optional{ .child = field.type };
        const OptionalType = @Type(.{ .optional = optional });
        partial_fields[index] = .{
            .name = field.name,
            .type = OptionalType,
            .default_value_ptr = &@as(OptionalType, null),
            .is_comptime = field.is_comptime,
            .alignment = @alignOf(OptionalType),
        };
    }
    const partial_struct = std.builtin.Type.Struct{
        .layout = .auto,
        .backing_integer = null,
        .fields = &partial_fields,
        .decls = &.{},
        .is_tuple = false,
    };
    return @Type(.{ .@"struct" = partial_struct });
}

pub fn FieldMap(
    comptime KeysStruct: type,
    comptime Value: type,
    comptime default_value_ptr: ?*const Value,
) type {
    const key_fields: []const std.builtin.Type.StructField = switch (@typeInfo(KeysStruct)) {
        .@"struct" => |info| info.fields,
        else => @compileError("FieldMap expects a struct type as argument."),
    };
    var map_fields: [key_fields.len]std.builtin.Type.StructField = undefined;
    for (key_fields, 0..) |*field, index| {
        map_fields[index] = .{
            .name = field.name,
            .type = Value,
            .default_value_ptr = default_value_ptr,
            .is_comptime = false,
            .alignment = @alignOf(Value),
        };
    }
    const map_struct = std.builtin.Type.Struct{
        .layout = .auto,
        .backing_integer = null,
        .fields = &map_fields,
        .decls = &.{},
        .is_tuple = false,
    };
    return @Type(.{ .@"struct" = map_struct });
}

pub fn areAllFieldsNull(struct_pointer: anytype) bool {
    const Struct = switch (@typeInfo(@TypeOf(struct_pointer))) {
        .pointer => |pointer| pointer.child,
        else => @compileError(
            "The areAllFieldsNull function expects a pointer to struct but provided value is of type: " ++
                @typeName(@TypeOf(struct_pointer)),
        ),
    };
    const fields: []const std.builtin.Type.StructField = switch (@typeInfo(Struct)) {
        .@"struct" => |info| info.fields,
        else => @compileError(
            "The areAllFieldsNull function expects a pointer to struct but provided value is of type: " ++
                @typeName(@TypeOf(struct_pointer)),
        ),
    };
    inline for (fields) |*field| {
        if (@field(struct_pointer, field.name) != null) {
            return false;
        }
    }
    return true;
}

pub fn enumArrayToEnumFieldStruct(
    comptime Enum: type,
    comptime Value: type,
    array: *const std.EnumArray(Enum, Value),
) std.enums.EnumFieldStruct(Enum, Value, null) {
    const enum_info: std.builtin.Type = @typeInfo(Enum);
    const fields = switch (enum_info) {
        .@"enum" => |e| e.fields,
        else => @compileError("Expected Enum to be a enum type but got: " ++ @typeName(Enum)),
    };
    var field_struct: std.enums.EnumFieldStruct(Enum, Value, null) = undefined;
    inline for (fields) |*field| {
        @field(field_struct, field.name) = array.get(@enumFromInt(field.value));
    }
    return field_struct;
}

const testing = std.testing;

test "SelfBasedPointer should return a pointer type with same mutability as SelfPointer" {
    try testing.expect(SelfBasedPointer(*const u64, u64, f32) == *const f32);
    try testing.expect(SelfBasedPointer(*u64, u64, f32) == *f32);
}

test "SelfBasedSlice should return a slice type with same mutability as SelfPointer" {
    try testing.expect(SelfBasedSlice(*const u64, u64, f32) == []const f32);
    try testing.expect(SelfBasedSlice(*u64, u64, f32) == []f32);
}

test "SelfBasedSentinelSlice should return a slice type with same mutability as SelfPointer" {
    try testing.expect(SelfBasedSentinelSlice(*const u64, u64, f32, 0) == [:0]const f32);
    try testing.expect(SelfBasedSentinelSlice(*u64, u64, f32, 0) == [:0]f32);
}

test "FieldMap should make every field typed with the specified type" {
    const Struct = struct {
        field_1: u8,
        field_2: u16,
        field_3: u32,
    };
    const Map = FieldMap(Struct, usize, null);
    try testing.expect(@FieldType(Map, "field_1") == usize);
    try testing.expect(@FieldType(Map, "field_2") == usize);
    try testing.expect(@FieldType(Map, "field_3") == usize);
}

test "FieldMap should have correct default values when provided" {
    const Struct = struct {
        field_1: u8,
        field_2: u16,
        field_3: u32,
    };
    const Map = FieldMap(Struct, usize, &123);
    const map = Map{};
    try testing.expectEqual(123, map.field_1);
    try testing.expectEqual(123, map.field_2);
    try testing.expectEqual(123, map.field_3);
}

test "Partial should make every field optional" {
    const Struct = struct {
        field_1: u8,
        field_2: u16,
        field_3: u32,
    };
    const PartialStruct = Partial(Struct);
    try testing.expect(@FieldType(PartialStruct, "field_1") == ?u8);
    try testing.expect(@FieldType(PartialStruct, "field_2") == ?u16);
    try testing.expect(@FieldType(PartialStruct, "field_3") == ?u32);
}

test "Partial should make every field's default value null" {
    const Struct = struct {
        field_1: u8,
        field_2: u16,
        field_3: u32,
    };
    const partial: Partial(Struct) = .{};
    try testing.expectEqual(null, partial.field_1);
    try testing.expectEqual(null, partial.field_2);
    try testing.expectEqual(null, partial.field_3);
}

test "areAllFieldsNull should return null only if all fields of provided struct are null" {
    const Struct = struct {
        field_1: ?u8,
        field_2: ?u16,
        field_3: ?u32,
    };
    const struct_1 = Struct{
        .field_1 = null,
        .field_2 = null,
        .field_3 = null,
    };
    const struct_2 = Struct{
        .field_1 = null,
        .field_2 = 0,
        .field_3 = null,
    };
    try testing.expectEqual(true, areAllFieldsNull(&struct_1));
    try testing.expectEqual(false, areAllFieldsNull(&struct_2));
}

test "enumArrayToEnumFieldStruct should return correct value" {
    const Enum = enum { a, b, c };
    const expected = std.enums.EnumFieldStruct(Enum, u8, null){
        .a = 1,
        .b = 2,
        .c = 3,
    };
    const array = std.EnumArray(Enum, u8).init(expected);
    const actual = enumArrayToEnumFieldStruct(Enum, u8, &array);
    try testing.expectEqual(expected, actual);
}
