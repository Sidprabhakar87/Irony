const std = @import("std");
const builtin = @import("builtin");
const misc = @import("../misc/root.zig");

const buffer_size = 1024;
const indentation_string = "  ";

pub fn writeJson(comptime Type: type, value: *const Type, writer: *std.io.Writer) !void {
    return writeValue(writer, value, 0) catch |err| {
        misc.error_context.append("Failed to write root value.", .{});
        return err;
    };
}

pub fn readJson(comptime Type: type, reader: *std.io.Reader, default: ?Type) !Type {
    var buffer: [buffer_size]u8 = undefined;
    var allocator = std.heap.FixedBufferAllocator.init(&buffer);
    var json_reader = std.json.Reader.init(allocator.allocator(), reader);
    defer json_reader.deinit();
    return readValue(Type, &json_reader, allocator.allocator(), default) catch |err| {
        misc.error_context.append("Failed to read root value.", .{});
        return err;
    };
}

fn writeValue(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    const Type = switch (@typeInfo(@TypeOf(value_pointer))) {
        .pointer => |info| info.child,
        else => @compileError("Expected value_pointer to be a pointer but got: " ++ @typeName(@TypeOf(value_pointer))),
    };
    if (hasTag(Type, misc.bounded_array_tag)) {
        try writeBoundedArray(writer, value_pointer, indentation);
    } else switch (@typeInfo(Type)) {
        .bool => try writeBool(writer, value_pointer.*),
        .int => try writeInt(writer, value_pointer.*),
        .float => try writeFloat(writer, value_pointer.*),
        .@"enum" => try writeEnum(writer, value_pointer.*),
        .optional => try writeOptional(writer, value_pointer, indentation),
        .array => try writeArray(writer, value_pointer, indentation),
        .@"struct" => |*info| switch (info.is_tuple) {
            true => try writeTuple(writer, value_pointer, indentation),
            false => try writeStruct(writer, value_pointer, indentation),
        },
        .@"union" => try writeUnion(writer, value_pointer, indentation),
        else => @compileError("Unsupported type: " ++ @typeName(Type)),
    }
}

fn readValue(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const start_height = reader.stackHeight();
    const value_or_error = if (hasTag(Type, misc.bounded_array_tag)) block: {
        break :block readBoundedArray(Type, reader, allocator, default);
    } else switch (@typeInfo(Type)) {
        .bool => readBool(reader),
        .int => readInt(Type, reader, allocator),
        .float => readFloat(Type, reader, allocator),
        .@"enum" => readEnum(Type, reader, allocator),
        .optional => readOptional(Type, reader, allocator, default),
        .array => readArray(Type, reader, allocator, default),
        .@"struct" => |*info| switch (info.is_tuple) {
            true => readTuple(Type, reader, allocator, default),
            false => readStruct(Type, reader, allocator, default),
        },
        .@"union" => readUnion(Type, reader, allocator, default),
        else => @compileError("Unsupported type: " ++ @typeName(Type)),
    };
    return value_or_error catch |err_1| {
        if (reader.stackHeight() != start_height) {
            reader.skipUntilStackHeight(start_height) catch |err_2| {
                misc.error_context.append("Failed to skip the invalid value.", .{});
                return err_2;
            };
        }
        if (default) |default_value| {
            misc.error_context.append("Falling back to default value.", .{});
            if (!builtin.is_test) {
                misc.error_context.logWarning(err_1);
            }
            return default_value;
        } else {
            misc.error_context.append("No default value to fall back to.", .{});
            return err_1;
        }
    };
}

fn writeBool(writer: *std.io.Writer, value: bool) !void {
    const string = if (value) "true" else "false";
    writer.writeAll(string) catch |err| {
        misc.error_context.new("Failed to write boolean value: {s}", .{string});
        return err;
    };
}

fn readBool(reader: *std.json.Reader) !bool {
    const token = reader.next() catch |err| {
        misc.error_context.new("Failed to read bool token.", .{});
        return err;
    };
    switch (token) {
        .false => return false,
        .true => return true,
        else => {
            misc.error_context.new("No default value to fall back to.", .{});
            return error.UnexpectedToken;
        },
    }
}

fn writeInt(writer: *std.io.Writer, value: anytype) !void {
    writer.print("{}", .{value}) catch |err| {
        misc.error_context.new("Failed to write int value: {}", .{value});
        return err;
    };
}

fn readInt(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator) !Type {
    const token = reader.nextAllocMax(allocator, .alloc_always, buffer_size) catch |err| {
        misc.error_context.new("Failed to read int token.", .{});
        return err;
    };
    defer freeIfAllocated(allocator, token);
    const string = switch (token) {
        .allocated_number => |string| string,
        else => {
            misc.error_context.new("Expected a number token but got: {s}", .{@tagName(token)});
            return error.UnexpectedToken;
        },
    };
    return std.fmt.parseInt(Type, string, 10) catch |err| {
        misc.error_context.new("Failed to parse string as integer: {s}", .{string});
        return err;
    };
}

fn writeFloat(writer: *std.io.Writer, value: anytype) !void {
    writer.print("{}", .{value}) catch |err| {
        misc.error_context.new("Failed to write float value: {}", .{value});
        return err;
    };
}

fn readFloat(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator) !Type {
    const token = reader.nextAllocMax(allocator, .alloc_always, buffer_size) catch |err| {
        misc.error_context.new("Failed to read float token.", .{});
        return err;
    };
    defer freeIfAllocated(allocator, token);
    const string = switch (token) {
        .allocated_number => |string| string,
        else => {
            misc.error_context.new("Expected a number token but got: {s}", .{@tagName(token)});
            return error.UnexpectedToken;
        },
    };
    return std.fmt.parseFloat(Type, string) catch |err| {
        misc.error_context.new("Failed to parse string as float: {s}", .{string});
        return err;
    };
}

fn writeEnum(writer: *std.io.Writer, value: anytype) !void {
    const Type = @TypeOf(value);
    const info = &@typeInfo(Type).@"enum";
    if (!info.is_exhaustive) {
        @compileError("Enum " ++ @typeName(Type) ++ " is not exhaustive and therefor not supported.");
    }
    const tag_name = @tagName(value);
    writer.print("\"{s}\"", .{tag_name}) catch |err| {
        misc.error_context.new("Failed to write enum value: {s}", .{tag_name});
        return err;
    };
}

fn readEnum(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator) !Type {
    const info = &@typeInfo(Type).@"enum";
    if (!info.is_exhaustive) {
        @compileError("Enum " ++ @typeName(Type) ++ " is not exhaustive and therefor not supported.");
    }
    const token = reader.nextAllocMax(allocator, .alloc_always, buffer_size) catch |err| {
        misc.error_context.new("Failed to read enum token.", .{});
        return err;
    };
    defer freeIfAllocated(allocator, token);
    const string = switch (token) {
        .allocated_string => |string| string,
        else => {
            misc.error_context.new("Expected a string token but got: {s}", .{@tagName(token)});
            return error.UnexpectedToken;
        },
    };
    inline for (info.fields) |*field| {
        if (std.mem.eql(u8, field.name, string)) {
            return @enumFromInt(field.value);
        }
    }
    misc.error_context.new("Invalid enum value: {s}", .{string});
    return error.InvalidEnumValue;
}

fn writeOptional(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    if (value_pointer.*) |*child_pointer| {
        writeValue(writer, child_pointer, indentation) catch |err| {
            misc.error_context.append("Failed to write optional's payload.", .{});
            return err;
        };
    } else {
        writer.writeAll("null") catch |err| {
            misc.error_context.new("Failed to write optional's null value.", .{});
            return err;
        };
    }
}

fn readOptional(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const info = &@typeInfo(Type).optional;
    const Payload = info.child;
    const token_type = reader.peekNextTokenType() catch |err| {
        misc.error_context.new("Failed to peek optional token type.", .{});
        return err;
    };
    switch (token_type) {
        .null => {
            reader.skipValue() catch |err| {
                misc.error_context.new("Failed to skip null token.", .{});
                return err;
            };
            return null;
        },
        else => {
            const default_payload = if (default) |d| block: {
                break :block if (d) |payload| payload else null;
            } else null;
            return readValue(Payload, reader, allocator, default_payload) catch |err| {
                misc.error_context.append("Failed to read optional's payload.", .{});
                return err;
            };
        },
    }
}

fn writeArray(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    writer.writeByte('[') catch |err| {
        misc.error_context.new("Failed to write array start.", .{});
        return err;
    };
    writeNewLine(writer, indentation + 1) catch |err| {
        misc.error_context.append("Failed to write new line after array start.", .{});
        return err;
    };
    for (value_pointer, 0..) |*element_pointer, index| {
        writeValue(writer, element_pointer, indentation + 1) catch |err| {
            misc.error_context.append("Failed to write array element at index: {}", .{index});
            return err;
        };
        if (index < value_pointer.len - 1) {
            writer.writeByte(',') catch |err| {
                misc.error_context.new("Failed to write array element separator after element: {}", .{index});
                return err;
            };
            writeNewLine(writer, indentation + 1) catch |err| {
                misc.error_context.append("Failed to write new line after array element: {}", .{index});
                return err;
            };
        }
    }
    writeNewLine(writer, indentation) catch |err| {
        misc.error_context.append("Failed to write new line after last array element.", .{});
        return err;
    };
    writer.writeByte(']') catch |err| {
        misc.error_context.new("Failed to write array end.", .{});
        return err;
    };
}

fn readArray(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const info = &@typeInfo(Type).array;
    const Element = info.child;
    const begin_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read array begin token.", .{});
        return err;
    };
    if (begin_token != .array_begin) {
        misc.error_context.new("Expected array begin token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    var array: Type = default orelse undefined;
    var index: usize = 0;
    while (true) {
        const peek_token = reader.peekNextTokenType() catch |err| {
            misc.error_context.new("Failed to peek next array token at index: {}", .{index});
            return err;
        };
        if (peek_token == .array_end) {
            break;
        }
        if (index < array.len) {
            const default_element = if (default) |d| d[index] else null;
            array[index] = readValue(Element, reader, allocator, default_element) catch |err| {
                misc.error_context.append("Failed to read array element at index: {}", .{index});
                return err;
            };
        } else {
            reader.skipValue() catch |err| {
                misc.error_context.new("Failed to skip array element: {}", .{index});
                return err;
            };
        }
        index += 1;
    }
    _ = reader.next() catch |err| {
        misc.error_context.new("Failed to read array end token.", .{});
        return err;
    };
    if (default == null and (index + 1) < array.len) {
        misc.error_context.new("JSON array ended early with length: {}", .{index});
        return error.EarlyEnd;
    }
    return array;
}

fn writeTuple(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    const info = @typeInfo(@TypeOf(value_pointer.*)).@"struct";
    writer.writeByte('[') catch |err| {
        misc.error_context.new("Failed to write tuple start.", .{});
        return err;
    };
    writeNewLine(writer, indentation + 1) catch |err| {
        misc.error_context.append("Failed to write new line after tuple start.", .{});
        return err;
    };
    inline for (0..info.fields.len) |index| {
        const field_pointer = &value_pointer[index];
        writeValue(writer, field_pointer, indentation + 1) catch |err| {
            misc.error_context.append("Failed to write tuple field: {}", .{index});
            return err;
        };
        if (index < value_pointer.len - 1) {
            writer.writeByte(',') catch |err| {
                misc.error_context.new("Failed to write tuple field separator field: {}", .{index});
                return err;
            };
            writeNewLine(writer, indentation + 1) catch |err| {
                misc.error_context.append("Failed to write new line after tuple field: {}", .{index});
                return err;
            };
        }
    }
    writeNewLine(writer, indentation) catch |err| {
        misc.error_context.append("Failed to write new line after last tuple field.", .{});
        return err;
    };
    writer.writeByte(']') catch |err| {
        misc.error_context.new("Failed to write tuple end.", .{});
        return err;
    };
}

fn readTuple(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const info = @typeInfo(Type).@"struct";
    const begin_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read tuple begin token.", .{});
        return err;
    };
    if (begin_token != .array_begin) {
        misc.error_context.new("Expected array begin token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    var tuple: Type = default orelse undefined;
    var index: usize = 0;
    inline for (info.fields) |*field| {
        const peek_token = reader.peekNextTokenType() catch |err| {
            misc.error_context.new("Failed to peek next tuple token at index: {}", .{index});
            return err;
        };
        if (peek_token == .array_end) {
            break;
        }
        const Field = field.type;
        const default_field = if (default) |d| @field(d, field.name) else null;
        @field(tuple, field.name) = readValue(Field, reader, allocator, default_field) catch |err| {
            misc.error_context.append("Failed to read tuple field at index: {}", .{index});
            return err;
        };
        index += 1;
    }
    while (true) {
        const peek_token = reader.peekNextTokenType() catch |err| {
            misc.error_context.new("Failed to peek next tuple token at index: {}", .{index});
            return err;
        };
        if (peek_token == .array_end) {
            break;
        }
        reader.skipValue() catch |err| {
            misc.error_context.new("Failed to skip tuple field: {}", .{index});
            return err;
        };
        index += 1;
    }
    _ = reader.next() catch |err| {
        misc.error_context.new("Failed to read tuple end token.", .{});
        return err;
    };
    if (default == null and (index + 1) < info.fields.len) {
        misc.error_context.new("JSON array ended early with length: {}", .{index});
        return error.EarlyEnd;
    }
    return tuple;
}

fn writeStruct(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    const info = @typeInfo(@TypeOf(value_pointer.*)).@"struct";
    writer.writeByte('{') catch |err| {
        misc.error_context.new("Failed to write object start.", .{});
        return err;
    };
    writeNewLine(writer, indentation + 1) catch |err| {
        misc.error_context.append("Failed to write new line after object start.", .{});
        return err;
    };
    inline for (info.fields, 0..) |*field, index| {
        writer.print("\"{s}\": ", .{field.name}) catch |err| {
            misc.error_context.new("Failed to write struct field name: {s}", .{field.name});
            return err;
        };
        const field_pointer = &@field(value_pointer, field.name);
        writeValue(writer, field_pointer, indentation + 1) catch |err| {
            misc.error_context.append("Failed to write struct field: {s}", .{field.name});
            return err;
        };
        if (index < info.fields.len - 1) {
            writer.writeByte(',') catch |err| {
                misc.error_context.new("Failed to struct field separator after field: {s}", .{field.name});
                return err;
            };
            writeNewLine(writer, indentation + 1) catch |err| {
                misc.error_context.append("Failed to write new line after struct field: {s}", .{field.name});
                return err;
            };
        }
    }
    writeNewLine(writer, indentation) catch |err| {
        misc.error_context.append("Failed to write new line after last struct field.", .{});
        return err;
    };
    writer.writeByte('}') catch |err| {
        misc.error_context.new("Failed to write object end.", .{});
        return err;
    };
}

fn readStruct(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const info = @typeInfo(Type).@"struct";
    const begin_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read struct begin token.", .{});
        return err;
    };
    if (begin_token != .object_begin) {
        misc.error_context.new("Expected object begin token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    var structure: Type = default orelse undefined;
    var found_fields = [1]bool{default != null} ** info.fields.len;
    while (true) {
        const token = reader.nextAllocMax(allocator, .alloc_always, buffer_size) catch |err| {
            misc.error_context.new("Failed to read next struct token.", .{});
            return err;
        };
        var is_token_freed = false;
        defer if (!is_token_freed) {
            freeIfAllocated(allocator, token);
            is_token_freed = true;
        };
        const field_name = switch (token) {
            .allocated_string => |string| string,
            .object_end => break,
            else => {
                misc.error_context.new("Expected string or object end token but got: {s}", .{@tagName(begin_token)});
                return error.UnexpectedToken;
            },
        };
        var field_found = false;
        inline for (info.fields, 0..) |*field, index| {
            if (std.mem.eql(u8, field.name, field_name)) {
                if (!is_token_freed) { // Field name is not needed while parsing the field value.
                    freeIfAllocated(allocator, token);
                    is_token_freed = true;
                }
                const Field = field.type;
                const default_field = if (default) |d| @field(d, field.name) else null;
                @field(structure, field.name) = readValue(Field, reader, allocator, default_field) catch |err| {
                    misc.error_context.append("Failed to read struct field: {s}", .{field.name});
                    return err;
                };
                field_found = true;
                found_fields[index] = true;
                break;
            }
        }
        if (!field_found) {
            reader.skipValue() catch |err| {
                misc.error_context.new("Failed to skip field value: {s}", .{field_name});
                return err;
            };
        }
    }
    inline for (info.fields, found_fields) |*field, found| {
        if (!found) {
            misc.error_context.new("Failed to find struct field inside JSON object: {s}", .{field.name});
            return error.FieldNotFound;
        }
    }
    return structure;
}

fn writeUnion(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    const Type = @TypeOf(value_pointer.*);
    const info = @typeInfo(Type).@"union";
    if (info.tag_type == null) {
        @compileError("Union " ++ @typeName(Type) ++ " is not tagged and therefor not serializable.");
    }
    const tag_name = @tagName(value_pointer.*);
    writer.writeAll("{ ") catch |err| {
        misc.error_context.new("Failed to write union start.", .{});
        return err;
    };
    writer.print("\"{s}\": ", .{tag_name}) catch |err| {
        misc.error_context.new("Failed to write union's tag: {s}", .{tag_name});
        return err;
    };
    switch (value_pointer.*) {
        inline else => |*payload_pointer| {
            writeValue(writer, payload_pointer, indentation) catch |err| {
                misc.error_context.append("Failed to write union's payload: {s}", .{tag_name});
                return err;
            };
        },
    }
    writer.writeAll(" }") catch |err| {
        misc.error_context.new("Failed to write union end.", .{});
        return err;
    };
}

fn readUnion(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const info = @typeInfo(Type).@"union";
    const Tag = info.tag_type orelse {
        @compileError("Union " ++ @typeName(Type) ++ " is not tagged and therefor not serializable.");
    };
    const begin_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read union begin token.", .{});
        return err;
    };
    if (begin_token != .object_begin) {
        misc.error_context.new("Expected object begin token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    const tagged_union: Type = block: {
        const default_tag = if (default) |d| std.meta.activeTag(d) else null;
        const tag = readValue(Tag, reader, allocator, default_tag) catch |err| {
            misc.error_context.append("Failed to read union's tag. ({s})", .{@typeName(Tag)});
            return err;
        };
        inline for (info.fields) |*field| {
            if (@field(Tag, field.name) == tag) {
                const Payload = field.type;
                const default_payload = if (tag == default_tag) @field(default.?, field.name) else null;
                const payload = readValue(Payload, reader, allocator, default_payload) catch |err| {
                    misc.error_context.append("Failed to read union's payload.", .{});
                    return err;
                };
                break :block @unionInit(Type, field.name, payload);
            }
        }
        unreachable;
    };
    const end_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read union end token.", .{});
        return err;
    };
    if (end_token != .object_end) {
        misc.error_context.new("Expected object end token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    return tagged_union;
}

fn writeBoundedArray(writer: *std.io.Writer, value_pointer: anytype, indentation: usize) !void {
    const slice = value_pointer.asSlice();
    const Element = @TypeOf(value_pointer.*).Child;
    if (Element == u8) {
        writer.print("\"{s}\"", .{slice}) catch |err| {
            misc.error_context.new("Failed to write enum value: {s}", .{slice});
            return err;
        };
        return;
    }
    writer.writeByte('[') catch |err| {
        misc.error_context.new("Failed to write array start.", .{});
        return err;
    };
    writeNewLine(writer, indentation + 1) catch |err| {
        misc.error_context.append("Failed to write new line after array start.", .{});
        return err;
    };
    for (slice, 0..) |*element_pointer, index| {
        writeValue(writer, element_pointer, indentation + 1) catch |err| {
            misc.error_context.append("Failed to write array element at index: {}", .{index});
            return err;
        };
        if (index < slice.len - 1) {
            writer.writeByte(',') catch |err| {
                misc.error_context.new("Failed to write array element separator after element: {}", .{index});
                return err;
            };
            writeNewLine(writer, indentation + 1) catch |err| {
                misc.error_context.append("Failed to write new line after array element: {}", .{index});
                return err;
            };
        }
    }
    writeNewLine(writer, indentation) catch |err| {
        misc.error_context.append("Failed to write new line after last array element.", .{});
        return err;
    };
    writer.writeByte(']') catch |err| {
        misc.error_context.new("Failed to write array end.", .{});
        return err;
    };
}

fn readBoundedArray(comptime Type: type, reader: *std.json.Reader, allocator: std.mem.Allocator, default: ?Type) !Type {
    const Element = Type.Child;
    if (Element == u8) {
        const token = reader.nextAllocMax(allocator, .alloc_always, buffer_size) catch |err| {
            misc.error_context.new("Failed to read enum token.", .{});
            return err;
        };
        defer freeIfAllocated(allocator, token);
        const string = switch (token) {
            .allocated_string => |string| string,
            else => {
                misc.error_context.new("Expected a string token but got: {s}", .{@tagName(token)});
                return error.UnexpectedToken;
            },
        };
        return .fromSliceTrimmed(string);
    }
    const begin_token = reader.next() catch |err| {
        misc.error_context.new("Failed to read bounded array begin token.", .{});
        return err;
    };
    if (begin_token != .array_begin) {
        misc.error_context.new("Expected array begin token but got: {s}", .{@tagName(begin_token)});
        return error.UnexpectedToken;
    }
    const default_slice = if (default) |d| d.asSlice() else &.{};
    var array: Type = .empty;
    var index: usize = 0;
    while (true) {
        const peek_token = reader.peekNextTokenType() catch |err| {
            misc.error_context.new("Failed to peek next bounded array token at index: {}", .{index});
            return err;
        };
        if (peek_token == .array_end) {
            break;
        }
        if (array.len < array.buffer.len) {
            const default_element = if (index < default_slice.len) default_slice[index] else null;
            array.buffer[array.len] = readValue(Element, reader, allocator, default_element) catch |err| {
                misc.error_context.append("Failed to read bounded array element at index: {}", .{index});
                return err;
            };
            array.len += 1;
        } else {
            reader.skipValue() catch |err| {
                misc.error_context.new("Failed to skip bounded array element: {}", .{index});
                return err;
            };
        }
        index += 1;
    }
    _ = reader.next() catch |err| {
        misc.error_context.new("Failed to read bounded array end token.", .{});
        return err;
    };
    return array;
}

fn writeNewLine(writer: *std.io.Writer, indentation: usize) !void {
    writer.writeByte('\n') catch |err| {
        misc.error_context.new("Failed to write new line character.", .{});
        return err;
    };
    for (0..indentation) |index| {
        writer.writeAll(indentation_string) catch |err| {
            misc.error_context.new("Failed to write indentation: {}", .{index});
            return err;
        };
    }
}

fn freeIfAllocated(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_number, .allocated_string => |slice| {
            allocator.free(slice);
        },
        else => {},
    }
}

inline fn hasTag(comptime Type: type, comptime tag: type) bool {
    comptime {
        const info = @typeInfo(Type);
        if (info != .@"struct" and info != .@"enum" and info != .@"union") return false;
        if (!@hasDecl(Type, "tag")) return false;
        if (@TypeOf(Type.tag) != type) return false;
        return Type.tag == tag;
    }
}

const testing = std.testing;

test "readJson should read the same value that writeJson saved" {
    const Value = struct {
        bool: bool = false,
        u8: u8 = 0,
        u16: u16 = 0,
        u32: u32 = 0,
        u64: u64 = 0,
        i8: i8 = 0,
        i16: i16 = 0,
        i32: i32 = 0,
        i64: i64 = 0,
        f32: f32 = 0,
        f64: f64 = 0,
        optional_1: ?i32 = 0,
        optional_2: ?f32 = 0,
        @"enum": enum { a, b } = .a,
        @"struct": struct { a: f32 = 0, b: f32 = 0 } = .{},
        packed_struct: packed struct { a: u18 = 0, b: u14 = 0 } = .{},
        tuple: struct { f32, f32 } = .{ 0, 0 },
        array: [2]f32 = .{ 0, 0 },
        tagged_union: union(enum) { i: i32, f: f32 } = .{ .i = 0 },
        array_of_struct: [2]struct { a: f32 = 0, b: f32 = 0 } = .{ .{}, .{} },
        struct_of_array: struct { a: [2]f32 = .{ 0, 0 }, b: [2]f32 = .{ 0, 0 } } = .{},
        bounded_array: misc.BoundedArray(4, f32, 0) = .empty,
        bounded_string: misc.BoundedArray(4, u8, 0) = .empty,
    };
    const write_value = Value{
        .bool = false,
        .u8 = 1,
        .u16 = 2,
        .u32 = 3,
        .u64 = 4,
        .i8 = -1,
        .i16 = -2,
        .i32 = -3,
        .i64 = -4,
        .f32 = 0.1,
        .f64 = 0.2,
        .optional_1 = null,
        .optional_2 = 0.3,
        .@"enum" = .b,
        .@"struct" = .{ .a = 1, .b = 2 },
        .packed_struct = .{ .a = 3, .b = 4 },
        .tuple = .{ 5, 6 },
        .array = .{ 7, 8 },
        .tagged_union = .{ .i = 9 },
        .array_of_struct = .{ .{ .a = 10, .b = 11 }, .{ .a = 12, .b = 13 } },
        .struct_of_array = .{ .a = .{ 14, 15 }, .b = .{ 16, 17 } },
        .bounded_array = .fromArray(.{ 18, 19 }),
        .bounded_string = .fromArray("123".*),
    };
    var buffer: [1024]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeJson(Value, &write_value, &writer);
    var reader = std.Io.Reader.fixed(buffer[0..writer.end]);
    const read_value = try readJson(Value, &reader, .{});
    try testing.expectEqual(write_value, read_value);
}

test "readJson should succeed when json has more values then expected" {
    const Value = struct {
        a: f32,
        d: struct { d1: f32 },
        e: [2]f32,
        f: [2]f32,
        g: misc.BoundedArray(2, f32, 0),
        h: misc.BoundedArray(2, u8, 0),
    };
    var reader = std.Io.Reader.fixed(
        \\{
        \\  "a": 1,
        \\  "b": 2,
        \\  "c": {"c1": 3},
        \\  "d": {"d1": 4, "d2": 5},
        \\  "e": [6, 7, 8],
        \\  "f": [9, 10, 11],
        \\  "g": [12, 13, 14],
        \\  "h": "abc"
        \\}
    );
    const value = try readJson(Value, &reader, null);
    try testing.expectEqual(Value{
        .a = 1,
        .d = .{ .d1 = 4 },
        .e = .{ 6, 7 },
        .f = .{ 9, 10 },
        .g = .fromArray(.{ 12, 13 }),
        .h = .fromArray("ab".*),
    }, value);
}

test "readJson should use default value when encountering missing value and default exists" {
    const Value = struct {
        a: f32 = -1,
        b: f32 = -2,
        c: struct { c1: f32 = -3, c2: f32 = -4 } = .{ .c1 = -5, .c2 = -6 },
        d: struct { d1: f32 = -7, d2: f32 = -8 } = .{ .d1 = -9, .d2 = -10 },
        e: [3]f32 = .{ -11, -12, -13 },
        f: struct { f32, f32, f32 } = .{ -14, -15, -16 },
        g: ?struct { g1: f32 = -17, g2: f32 = -18 } = .{ .g1 = -19, .g2 = -20 },
        h: ?struct { h1: f32 = -21, h2: f32 = -22 } = null,
    };
    var reader = std.Io.Reader.fixed(
        \\{
        \\  "a": 1,
        \\  "d": { "d1": 2 },
        \\  "e": [3, 4],
        \\  "f": [5, 6],
        \\  "g": { "g1": 7 },
        \\  "h": { "h1": 8 }
        \\}
    );
    const value = try readJson(Value, &reader, .{});
    try testing.expectEqual(Value{
        .a = 1,
        .b = -2,
        .c = .{ .c1 = -5, .c2 = -6 },
        .d = .{ .d1 = 2, .d2 = -10 },
        .e = .{ 3, 4, -13 },
        .f = .{ 5, 6, -16 },
        .g = .{ .g1 = 7, .g2 = -20 },
        .h = null,
    }, value);
}

test "readJson should use default value when encountering invalid value and default exists" {
    const Value = struct {
        a: f32 = -1,
        b: f32 = -2,
        c: struct { c1: f32 = -3, c2: f32 = -4 } = .{ .c1 = -5, .c2 = -6 },
        d: struct { d1: f32 = -7, d2: f32 = -8 } = .{ .d1 = -9, .d2 = -10 },
        e: [3]f32 = .{ -11, -12, -13 },
        f: struct { f32, f32, f32 } = .{ -14, -15, -16 },
        g: ?struct { g1: f32 = -17, g2: f32 = -18 } = .{ .g1 = -19, .g2 = -20 },
        h: ?struct { h1: f32 = -21, h2: f32 = -22 } = null,
        i: misc.BoundedArray(4, f32, 0) = .fromArray(.{ -23, -24 }),
        j: misc.BoundedArray(4, u8, 0) = .fromArray("ab".*),
    };
    var reader = std.Io.Reader.fixed(
        \\{
        \\  "a": 1,
        \\  "b": [false, false, false],
        \\  "c": false,
        \\  "d": { "d1": 2, "d2": false },
        \\  "e": [3, false, 4],
        \\  "f": [5, false, 6],
        \\  "g": { "g1": 7, "g2": false },
        \\  "h": { "h1": 8, "h2": false },
        \\  "i": [9, false, 10],
        \\  "j": false
        \\}
    );
    const value = try readJson(Value, &reader, .{});
    try testing.expectEqual(Value{
        .a = 1,
        .b = -2,
        .c = .{ .c1 = -5, .c2 = -6 },
        .d = .{ .d1 = 2, .d2 = -10 },
        .e = .{ 3, -12, 4 },
        .f = .{ 5, -15, 6 },
        .g = .{ .g1 = 7, .g2 = -20 },
        .h = null,
        .i = .fromArray(.{ 9, -24, 10 }),
        .j = .fromArray("ab".*),
    }, value);
}

test "readJson should resolve mixed field order in JSON objects" {
    const Value = struct {
        a: struct { a1: f32, a2: f32 },
        b: struct { b1: f32, b2: f32 },
        c: struct { c1: f32, c2: f32 },
        d: struct { d1: f32, d2: f32 },
    };
    var reader = std.Io.Reader.fixed(
        \\{
        \\  "a": { "a1": 1, "a2": 2 },
        \\  "d": { "d2": 8, "d1": 7 },
        \\  "c": { "c1": 5, "c2": 6 },
        \\  "b": { "b2": 4, "b1": 3 }
        \\}
    );
    const value = try readJson(Value, &reader, null);
    try testing.expectEqual(Value{
        .a = .{ .a1 = 1, .a2 = 2 },
        .b = .{ .b1 = 3, .b2 = 4 },
        .c = .{ .c1 = 5, .c2 = 6 },
        .d = .{ .d1 = 7, .d2 = 8 },
    }, value);
}
