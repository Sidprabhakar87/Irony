const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const sdk = @import("../../sdk/root.zig");
const game = @import("root.zig");

pub fn Hooks(comptime game_id: build_info.Game, comptime onTick: *const fn () void) type {
    return struct {
        var tick_hook: ?TickHook = null;
        var active_hook_calls = std.atomic.Value(u8).init(0);

        const TickHook = sdk.memory.Hook(game.TickFunction(game_id));

        pub fn init(game_functions: *const game.Memory(game_id).Functions) void {
            std.log.debug("Creating tick hook...", .{});
            if (game_functions.tick) |function| {
                const detour = switch (game_id) {
                    .t7 => onT7Tick,
                    .t8 => onT8Tick,
                };
                if (TickHook.create(function, detour)) |hook| {
                    tick_hook = hook;
                    std.log.info("Tick hook created.", .{});
                } else |err| {
                    if (!builtin.is_test) {
                        sdk.misc.error_context.append("Failed to create tick hook.", .{});
                        sdk.misc.error_context.logError(err);
                    }
                }
            } else if (!builtin.is_test) {
                sdk.misc.error_context.new("Tick function not found.", .{});
                sdk.misc.error_context.append("Failed to create tick hook.", .{});
                sdk.misc.error_context.logError(error.NotFound);
            }

            if (tick_hook) |*hook| {
                std.log.debug("Enabling tick hook...", .{});
                if (hook.enable()) {
                    std.log.info("Tick hook enabled.", .{});
                } else |err| {
                    sdk.misc.error_context.append("Failed to enable tick hook.", .{});
                    sdk.misc.error_context.logError(err);
                }
            }
        }

        pub fn deinit() void {
            std.log.debug("Destroying tick hook...", .{});
            if (tick_hook) |*hook| {
                if (hook.destroy()) {
                    std.log.info("Tick hook destroyed.", .{});
                    tick_hook = null;
                } else |err| {
                    sdk.misc.error_context.append("Failed to destroy tick hook.", .{});
                    sdk.misc.error_context.logError(err);
                }
            } else {
                std.log.debug("Nothing to destroy.", .{});
            }

            while (active_hook_calls.load(.seq_cst) > 0) {
                std.Thread.sleep(10 * std.time.ns_per_ms);
            }
        }

        fn onT7Tick(param_1: u8, param_2: u32) callconv(.c) void {
            _ = active_hook_calls.fetchAdd(1, .seq_cst);
            defer _ = active_hook_calls.fetchSub(1, .seq_cst);
            tick_hook.?.original(param_1, param_2);
            onTick();
        }

        fn onT8Tick(param_1: u64, param_2: u8, param_3: u8, param_4: u8) callconv(.c) void {
            _ = active_hook_calls.fetchAdd(1, .seq_cst);
            defer _ = active_hook_calls.fetchSub(1, .seq_cst);
            tick_hook.?.original(param_1, param_2, param_3, param_4);
            onTick();
        }
    };
}

const testing = std.testing;

test "should call onTick and original when tick function is called in T7" {
    const Tick = struct {
        var times_called: usize = 0;
        var last_param_1: ?u8 = null;
        var last_param_2: ?u32 = null;
        fn call(param_1: u8, param_2: u32) callconv(.c) void {
            times_called += 1;
            last_param_1 = param_1;
            last_param_2 = param_2;
        }
    };
    const OnTick = struct {
        var times_called: usize = 0;
        fn call() void {
            times_called += 1;
        }
    };
    const hooks = Hooks(.t7, OnTick.call);

    try sdk.memory.hooking.init();
    defer sdk.memory.hooking.deinit() catch @panic("Failed to de-initialize hooking.");
    hooks.init(&.{ .tick = Tick.call });
    defer hooks.deinit();

    try testing.expectEqual(0, Tick.times_called);
    try testing.expectEqual(0, OnTick.times_called);
    Tick.call(123, 456);
    try testing.expectEqual(1, Tick.times_called);
    try testing.expectEqual(123, Tick.last_param_1);
    try testing.expectEqual(456, Tick.last_param_2);
    try testing.expectEqual(1, OnTick.times_called);
}

test "should call onTick and original when tick function is called in T8" {
    const Tick = struct {
        var times_called: usize = 0;
        var last_param_1: ?u64 = null;
        var last_param_2: ?u8 = null;
        var last_param_3: ?u8 = null;
        var last_param_4: ?u8 = null;
        fn call(param_1: u64, param_2: u8, param_3: u8, param_4: u8) callconv(.c) void {
            times_called += 1;
            last_param_1 = param_1;
            last_param_2 = param_2;
            last_param_3 = param_3;
            last_param_4 = param_4;
        }
    };
    const OnTick = struct {
        var times_called: usize = 0;
        fn call() void {
            times_called += 1;
        }
    };
    const hooks = Hooks(.t8, OnTick.call);

    try sdk.memory.hooking.init();
    defer sdk.memory.hooking.deinit() catch @panic("Failed to de-initialize hooking.");
    hooks.init(&.{ .tick = Tick.call });
    defer hooks.deinit();

    try testing.expectEqual(0, Tick.times_called);
    try testing.expectEqual(0, OnTick.times_called);
    Tick.call(2, 3, 4, 5);
    try testing.expectEqual(1, Tick.times_called);
    try testing.expectEqual(2, Tick.last_param_1);
    try testing.expectEqual(3, Tick.last_param_2);
    try testing.expectEqual(4, Tick.last_param_3);
    try testing.expectEqual(5, Tick.last_param_4);
    try testing.expectEqual(1, OnTick.times_called);
}
