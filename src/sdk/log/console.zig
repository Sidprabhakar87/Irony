const std = @import("std");
const misc = @import("../misc/root.zig");

pub const ConsoleLoggerConfig = struct {
    level: std.log.Level = .debug,
    time_zone: misc.TimeZone = .local,
    buffer_size: usize = 4096,
    nanoTimestamp: *const fn () i128 = std.time.nanoTimestamp,
    lockStdErr: *const fn () void = std.debug.lockStdErr,
    unlockStdErr: *const fn () void = std.debug.unlockStdErr,
    testing_buffer: ?[]u8 = null,
};

pub fn ConsoleLogger(comptime config: ConsoleLoggerConfig) type {
    return struct {
        var log_writer: if (config.testing_buffer == null) ?std.fs.File.Writer else ?std.Io.Writer = null;
        var buffer: [config.buffer_size]u8 = [1]u8{0} ** config.buffer_size;

        pub fn logFn(
            comptime level: std.log.Level,
            comptime scope: @Type(.enum_literal),
            comptime format: []const u8,
            args: anytype,
        ) void {
            if (@intFromEnum(level) > @intFromEnum(config.level)) {
                return;
            }
            const timestamp = misc.Timestamp.fromNano(config.nanoTimestamp(), config.time_zone) catch null;
            const scope_prefix = if (scope != std.log.default_log_scope) "(" ++ @tagName(scope) ++ ") " else "";
            const level_prefix = "[" ++ comptime level.asText() ++ "] ";
            if (log_writer == null) {
                config.lockStdErr();
                defer config.unlockStdErr();
                if (config.testing_buffer) |testing_buffer| {
                    log_writer = std.Io.Writer.fixed(testing_buffer);
                } else {
                    log_writer = std.fs.File.stderr().writer(&buffer);
                }
            }
            const writer: *std.Io.Writer = if (config.testing_buffer == null) &log_writer.?.interface else &log_writer.?;
            config.lockStdErr();
            defer config.unlockStdErr();
            if (timestamp) |t| {
                writer.print("{f} " ++ level_prefix ++ scope_prefix ++ format ++ "\n", .{t} ++ args) catch return;
            } else {
                writer.print(level_prefix ++ scope_prefix ++ format ++ "\n", args) catch return;
            }
            writer.flush() catch return;
        }
    };
}

const testing = std.testing;

test "should format output correctly" {
    const nanoTimestamp = struct {
        fn call() i128 {
            return 1577934245123456789;
        }
    }.call;
    const doNothing = struct {
        fn call() void {}
    }.call;
    const TestBuffer = struct {
        var buffer = [1]u8{0} ** 512;
    };

    const logger = ConsoleLogger(.{
        .level = .debug,
        .time_zone = .utc,
        .nanoTimestamp = nanoTimestamp,
        .lockStdErr = doNothing,
        .unlockStdErr = doNothing,
        .testing_buffer = &TestBuffer.buffer,
    });

    logger.logFn(.debug, std.log.default_log_scope, "Message: {}", .{1});
    logger.logFn(.info, .scope_1, "Message: {}", .{2});
    logger.logFn(.warn, .scope_2, "Message: {}", .{3});
    logger.logFn(.err, .scope_3, "Message: {}", .{4});
    const expected =
        \\2020-01-02T03:04:05.123456789 [debug] Message: 1
        \\2020-01-02T03:04:05.123456789 [info] (scope_1) Message: 2
        \\2020-01-02T03:04:05.123456789 [warning] (scope_2) Message: 3
        \\2020-01-02T03:04:05.123456789 [error] (scope_3) Message: 4
        \\
    ;
    const actual = std.mem.sliceTo(&TestBuffer.buffer, 0);
    try testing.expectStringStartsWith(expected, actual);
}

test "should filter based on log level correctly" {
    const nanoTimestamp = struct {
        fn call() i128 {
            return 1577934245123456789;
        }
    }.call;
    const doNothing = struct {
        fn call() void {}
    }.call;
    const TestBuffer = struct {
        var buffer = [1]u8{0} ** 512;
    };

    const logger = ConsoleLogger(.{
        .level = .warn,
        .time_zone = .utc,
        .nanoTimestamp = nanoTimestamp,
        .lockStdErr = doNothing,
        .unlockStdErr = doNothing,
        .testing_buffer = &TestBuffer.buffer,
    });

    logger.logFn(.debug, std.log.default_log_scope, "Message: 1", .{});
    logger.logFn(.info, std.log.default_log_scope, "Message: 2", .{});
    logger.logFn(.warn, std.log.default_log_scope, "Message: 3", .{});
    logger.logFn(.err, std.log.default_log_scope, "Message: 4", .{});

    const expected =
        \\2020-01-02T03:04:05.123456789 [warning] Message: 3
        \\2020-01-02T03:04:05.123456789 [error] Message: 4
        \\
    ;
    const actual = std.mem.sliceTo(&TestBuffer.buffer, 0);
    try testing.expectEqualStrings(expected, actual);
}

test "should lock/unlock stderr correctly" {
    const nanoTimestamp = struct {
        fn call() i128 {
            return 1577934245123456789;
        }
    }.call;
    const Lock = struct {
        var locked: bool = false;
        var times_locked: usize = 0;
        fn lock() void {
            if (locked) {
                @panic("Already locked.");
            }
            locked = true;
            times_locked += 1;
        }
        fn unlock() void {
            if (!locked) {
                @panic("Already unlocked.");
            }
            locked = false;
        }
    };
    const TestBuffer = struct {
        var buffer = [1]u8{0} ** 512;
    };

    const logger = ConsoleLogger(.{
        .level = .debug,
        .time_zone = .utc,
        .nanoTimestamp = nanoTimestamp,
        .lockStdErr = Lock.lock,
        .unlockStdErr = Lock.unlock,
        .testing_buffer = &TestBuffer.buffer,
    });

    try testing.expect(!Lock.locked);
    try testing.expectEqual(0, Lock.times_locked);
    logger.logFn(.debug, std.log.default_log_scope, "Message: 1", .{});
    try testing.expect(!Lock.locked);
    try testing.expectEqual(2, Lock.times_locked);
    logger.logFn(.info, std.log.default_log_scope, "Message: 2", .{});
    try testing.expect(!Lock.locked);
    try testing.expectEqual(3, Lock.times_locked);
}
