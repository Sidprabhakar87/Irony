const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const model = @import("root.zig");

pub const Recording = std.ArrayList(model.Frame);

const serialization_config = sdk.io.RecordingConfig{
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

pub fn saveRecording(allocator: std.mem.Allocator, frames: []const model.Frame, file_path: []const u8) !void {
    const file = std.fs.cwd().createFile(file_path, .{}) catch |err| {
        sdk.misc.error_context.new("Failed to create or open file: {s}", .{file_path});
        return err;
    };
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    sdk.io.writeRecording(model.Frame, allocator, frames, &writer.interface, &serialization_config) catch |err| {
        sdk.misc.error_context.append("Failed write recording content.", .{});
        return err;
    };
    writer.end() catch |err| {
        sdk.misc.error_context.new("Failed to end file writing.", .{});
        return err;
    };
}

pub fn loadRecording(allocator: std.mem.Allocator, file_path: []const u8) ![]model.Frame {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        sdk.misc.error_context.new("Failed to open file: {s}", .{file_path});
        return err;
    };
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var reader = file.reader(&buffer);
    return sdk.io.readRecording(model.Frame, allocator, &reader.interface, &serialization_config) catch |err| {
        sdk.misc.error_context.append("Failed read recording content.", .{});
        return err;
    };
}

const testing = std.testing;

test "loadRecording should load the same frames that the saveRecording saved" {
    const saved_frames = [_]model.Frame{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    };
    try saveRecording(testing.allocator, &saved_frames, "./test_assets/recording.irony");
    defer std.fs.cwd().deleteFile("./test_assets/recording.irony") catch @panic("Failed to cleanup test file.");
    const loaded_frames = try loadRecording(testing.allocator, "./test_assets/recording.irony");
    defer testing.allocator.free(loaded_frames);
    try testing.expectEqualSlices(model.Frame, &saved_frames, loaded_frames);
}

test "saveRecording should overwrite the file if it already exists" {
    try saveRecording(testing.allocator, &.{
        .{ .frames_since_round_start = 1 },
        .{ .frames_since_round_start = 2 },
        .{ .frames_since_round_start = 3 },
    }, "./test_assets/recording.irony");
    defer std.fs.cwd().deleteFile("./test_assets/recording.irony") catch @panic("Failed to cleanup test file.");
    try saveRecording(testing.allocator, &.{
        .{ .frames_since_round_start = 4 },
        .{ .frames_since_round_start = 5 },
        .{ .frames_since_round_start = 6 },
    }, "./test_assets/recording.irony");
    const recording = try loadRecording(testing.allocator, "./test_assets/recording.irony");
    defer testing.allocator.free(recording);
    try testing.expectEqualSlices(model.Frame, &.{
        .{ .frames_since_round_start = 4 },
        .{ .frames_since_round_start = 5 },
        .{ .frames_since_round_start = 6 },
    }, recording);
}
