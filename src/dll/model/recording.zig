const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("root.zig");

pub const Recording = std.ArrayList(model.Frame);

pub const RecordingFormat = enum {
    irony,
    json,
    json_xz,

    const Self = @This();

    pub fn getFileExtension(self: Self) [:0]const u8 {
        return switch (self) {
            .irony => ".irony",
            .json => ".json",
            .json_xz => ".json.xz",
        };
    }

    pub fn fromFilePath(path: []const u8) ?Self {
        for (std.meta.tags(Self)) |self| {
            const extension = self.getFileExtension();
            if (std.ascii.endsWithIgnoreCase(path, extension)) {
                return self;
            }
        }
        return null;
    }
};

const irony_format_config = sdk.io.IronyFormatConfig{
    .atomic_types = &.{
        ?bool,
        ?u32,
        ?f32,
        ?model.MovePhase,
        ?model.AttackType,
        ?model.HitOutcome,
        ?model.Posture,
        ?model.Blocking,
        ?model.Crushing,
        ?model.Input,
        ?model.Rage,
        sdk.math.Vec3,
        model.HitLine,
        model.Wall,
        model.FloorGimmick,
    },
};
const buffer_size = 4096;

pub fn saveRecording(
    allocator: std.mem.Allocator,
    frames: []const model.Frame,
    file_path: []const u8,
    format: RecordingFormat,
) !void {
    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        sdk.misc.error_context.new("Failed to create or open file: {s}", .{file_path});
        return err;
    };
    defer file.close();
    var buffer: [buffer_size]u8 = undefined;
    var writer = file.writer(&buffer);

    switch (format) {
        .irony => {
            sdk.io.writeIronyFormat(
                model.Frame,
                allocator,
                frames,
                &writer.interface,
                &irony_format_config,
            ) catch |err| {
                sdk.misc.error_context.append("Failed write recording content in Irony format.", .{});
                return err;
            };
        },
        .json => {
            sdk.io.writeLargeJsonArray(model.Frame, frames, &writer.interface) catch |err| {
                sdk.misc.error_context.append("Failed write recording content in JSON format.", .{});
                return err;
            };
        },
        .json_xz => {
            errdefer sdk.misc.error_context.append("Failed write recording content in JSON XZ format.", .{});
            var encoder = sdk.io.XzEncoder.init(allocator, &writer.interface, .default) catch |err| {
                sdk.misc.error_context.append("Failed to initialize XZ encoder.", .{});
                return err;
            };
            defer encoder.deinit();
            var encoded_buffer: [buffer_size]u8 = undefined;
            var encoder_writer = encoder.writer(&encoded_buffer);
            sdk.io.writeLargeJsonArray(model.Frame, frames, &encoder_writer) catch |err| {
                sdk.misc.error_context.append("Failed write recording content in JSON format.", .{});
                return err;
            };
            encoder_writer.flush() catch |err| {
                sdk.misc.error_context.append("Failed to flush XZ encoder.", .{});
                return err;
            };
        },
    }

    writer.end() catch |err| {
        sdk.misc.error_context.new("Failed to end file writing.", .{});
        return err;
    };
}

pub fn loadRecording(allocator: std.mem.Allocator, file_path: []const u8, format: RecordingFormat) !Recording {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        sdk.misc.error_context.new("Failed to open file: {s}", .{file_path});
        return err;
    };
    defer file.close();
    var buffer: [buffer_size]u8 = undefined;
    var reader = file.reader(&buffer);

    switch (format) {
        .irony => {
            const slice = sdk.io.readIronyFormat(
                model.Frame,
                allocator,
                &reader.interface,
                &irony_format_config,
            ) catch |err| {
                sdk.misc.error_context.append("Failed read recording content from Irony format.", .{});
                return err;
            };
            return .fromOwnedSlice(slice);
        },
        .json => {
            return sdk.io.readLargeJsonArray(model.Frame, allocator, &reader.interface, &.{}) catch |err| {
                sdk.misc.error_context.append("Failed read recording content from JSON format.", .{});
                return err;
            };
        },
        .json_xz => {
            errdefer sdk.misc.error_context.append("Failed read recording content from JSON XZ format.", .{});
            var decoder = sdk.io.XzDecoder.init(allocator, &reader.interface) catch |err| {
                sdk.misc.error_context.append("Failed to initialize XZ decoder.", .{});
                return err;
            };
            defer decoder.deinit();
            var decoder_buffer: [buffer_size]u8 = undefined;
            var decoder_reader = decoder.reader(&decoder_buffer);
            return sdk.io.readLargeJsonArray(model.Frame, allocator, &decoder_reader, &.{}) catch |err| {
                sdk.misc.error_context.append("Failed read recording content from JSON format.", .{});
                return err;
            };
        },
    }
}

const testing = std.testing;

test "RecordingFormat.getFileExtension should return correct value" {
    try testing.expectEqualStrings(".irony", RecordingFormat.irony.getFileExtension());
    try testing.expectEqualStrings(".json", RecordingFormat.json.getFileExtension());
    try testing.expectEqualStrings(".json.xz", RecordingFormat.json_xz.getFileExtension());
}

test "RecordingFormat.fromFilePath should return correct value" {
    try testing.expectEqual(RecordingFormat.irony, RecordingFormat.fromFilePath("test.iRoNy"));
    try testing.expectEqual(RecordingFormat.json, RecordingFormat.fromFilePath("test.JsOn"));
    try testing.expectEqual(RecordingFormat.json_xz, RecordingFormat.fromFilePath("test.jSoN.xZ"));
    try testing.expectEqual(null, RecordingFormat.fromFilePath("test.txt"));
}

test "loadRecording should load the same frames that the saveRecording saved when format is irony" {
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    try saveRecording(testing.allocator, &frames, "./test_assets/recording.irony", .irony);
    defer std.fs.cwd().deleteFile("./test_assets/recording.irony") catch @panic("Failed to cleanup test file.");
    var recording = try loadRecording(testing.allocator, "./test_assets/recording.irony", .irony);
    defer recording.deinit(testing.allocator);
    try testing.expectEqualSlices(model.Frame, &frames, recording.items);
}

test "loadRecording should load the same frames that the saveRecording saved when format is json" {
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    try saveRecording(testing.allocator, &frames, "./test_assets/recording.json", .json);
    defer std.fs.cwd().deleteFile("./test_assets/recording.json") catch @panic("Failed to cleanup test file.");
    var recording = try loadRecording(testing.allocator, "./test_assets/recording.json", .json);
    defer recording.deinit(testing.allocator);
    try testing.expectEqualSlices(model.Frame, &frames, recording.items);
}

test "loadRecording should load the same frames that the saveRecording saved when format is json xz" {
    errdefer |err| sdk.misc.error_context.logError(err);
    const frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    try saveRecording(testing.allocator, &frames, "./test_assets/recording.json.xz", .json_xz);
    defer std.fs.cwd().deleteFile("./test_assets/recording.json.xz") catch @panic("Failed to cleanup test file.");
    var recording = try loadRecording(testing.allocator, "./test_assets/recording.json.xz", .json_xz);
    defer recording.deinit(testing.allocator);
    try testing.expectEqualSlices(model.Frame, &frames, recording.items);
}

test "saveRecording should overwrite the file if it already exists" {
    try saveRecording(testing.allocator, &.{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    }, "./test_assets/recording.irony", .irony);
    defer std.fs.cwd().deleteFile("./test_assets/recording.irony") catch @panic("Failed to cleanup test file.");
    try saveRecording(testing.allocator, &.{
        .{ .frames_since_round_start = 4 },
        .{ .frames_since_round_start = 5 },
        .{ .frames_since_round_start = 6 },
    }, "./test_assets/recording.irony", .irony);
    var recording = try loadRecording(testing.allocator, "./test_assets/recording.irony", .irony);
    defer recording.deinit(testing.allocator);
    try testing.expectEqualSlices(model.Frame, &.{
        .{ .frames_since_round_start = 4 },
        .{ .frames_since_round_start = 5 },
        .{ .frames_since_round_start = 6 },
    }, recording.items);
}
