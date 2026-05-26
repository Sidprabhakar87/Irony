const std = @import("std");
const builtin = @import("builtin");
const build_info = @import("build_info");
const sdk = @import("../../sdk/root.zig");
const game = @import("root.zig");

pub fn Hooks(comptime game_id: build_info.Game, comptime onTick: *const fn () void) type {
    return struct {
        var tick_hook: ?TickHook = null;
        var render_targets_hook: ?RenderTargetsHook = null;
        var active_hook_calls = std.atomic.Value(u8).init(0);

        pub var depth_buffer_address: usize = 0;

        const TickHook = sdk.memory.Hook(game.TickFunction(game_id));
        const RenderTargetsHook = sdk.memory.Hook(game.SetRenderTargetsFunction);

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

            if (game_id == .t8) {
                std.log.debug("Creating render targets hook...", .{});
                if (game_functions.setRenderTargets) |function| {
                    const detour = onSetRenderTargets;
                    if (RenderTargetsHook.create(function, detour)) |hook| {
                        render_targets_hook = hook;
                        std.log.info("Render targets hook created.", .{});
                    } else |err| {
                        if (!builtin.is_test) {
                            sdk.misc.error_context.append("Failed to create render targets hook.", .{});
                            sdk.misc.error_context.logError(err);
                        }
                    }
                } else if (!builtin.is_test) {
                    sdk.misc.error_context.new("SetRenderTargets function not found.", .{});
                    sdk.misc.error_context.append("Failed to create render targets hook.", .{});
                    sdk.misc.error_context.logError(error.NotFound);
                }
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

            if (render_targets_hook) |*hook| {
                std.log.debug("Enabling render targets hook...", .{});
                if (hook.enable()) {
                    std.log.info("Render targets hook enabled.", .{});
                } else |err| {
                    sdk.misc.error_context.append("Failed to enable render targets hook.", .{});
                    sdk.misc.error_context.logError(err);
                }
            }
        }

        pub fn deinit() void {
            if (game_id == .t8) {
                std.log.debug("Destroying render targets hook...", .{});
                if (render_targets_hook) |*hook| {
                    if (hook.destroy()) {
                        std.log.info("Render targets hook destroyed.", .{});
                        render_targets_hook = null;
                    } else |err| {
                        sdk.misc.error_context.append("Failed to destroy render targets hook.", .{});
                        sdk.misc.error_context.logError(err);
                    }
                } else {
                    std.log.debug("Nothing to destroy.", .{});
                }
            }

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

        fn onSetRenderTargets(this: usize, param_1: usize, param_2: u32, param_3: usize) callconv(.c) void {
            _ = active_hook_calls.fetchAdd(1, .seq_cst);
            defer _ = active_hook_calls.fetchSub(1, .seq_cst);
            render_targets_hook.?.original(this, param_1, param_2, param_3);
            if (param_3 == 0) {
                return;
            }
            const trail = sdk.memory.PointerTrail.fromArray(.{ param_3 +| 0x48, 0x20, 0x0 });
            depth_buffer_address = trail.resolve() orelse 0;
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

test "should set depth_buffer_address to correct value and call original when setRenderTargets function is called in T8" {
    const SetRenderTargets = struct {
        var times_called: usize = 0;
        var last_this: ?usize = null;
        var last_param_1: ?usize = null;
        var last_param_2: ?u32 = null;
        var last_param_3: ?usize = null;
        fn call(this: usize, param_1: usize, param_2: u32, param_3: usize) callconv(.c) void {
            times_called += 1;
            last_this = this;
            last_param_1 = param_1;
            last_param_2 = param_2;
            last_param_3 = param_3;
        }
    };
    const OnTick = struct {
        fn call() void {}
    };
    const hooks = Hooks(.t8, OnTick.call);

    try sdk.memory.hooking.init();
    defer sdk.memory.hooking.deinit() catch @panic("Failed to de-initialize hooking.");
    hooks.init(&.{ .setRenderTargets = SetRenderTargets.call });
    defer hooks.deinit();

    const B = extern struct {
        _padding: [0x20]u8 = undefined,
        c: usize,
    };
    const A = extern struct {
        _padding: [0x48]u8 = undefined,
        b: *const B,
    };
    const a = &A{ .b = &.{ .c = 123 } };

    try testing.expectEqual(0, SetRenderTargets.times_called);

    SetRenderTargets.call(11, 12, 13, std.math.maxInt(usize));
    try testing.expectEqual(1, SetRenderTargets.times_called);
    try testing.expectEqual(11, SetRenderTargets.last_this);
    try testing.expectEqual(12, SetRenderTargets.last_param_1);
    try testing.expectEqual(13, SetRenderTargets.last_param_2);
    try testing.expectEqual(std.math.maxInt(usize), SetRenderTargets.last_param_3);
    try testing.expectEqual(0, hooks.depth_buffer_address);

    SetRenderTargets.call(11, 12, 13, @intFromPtr(a));
    try testing.expectEqual(2, SetRenderTargets.times_called);
    try testing.expectEqual(11, SetRenderTargets.last_this);
    try testing.expectEqual(12, SetRenderTargets.last_param_1);
    try testing.expectEqual(13, SetRenderTargets.last_param_2);
    try testing.expectEqual(@intFromPtr(a), SetRenderTargets.last_param_3);
    try testing.expectEqual(123, hooks.depth_buffer_address);

    SetRenderTargets.call(11, 12, 13, 0);
    try testing.expectEqual(3, SetRenderTargets.times_called);
    try testing.expectEqual(11, SetRenderTargets.last_this);
    try testing.expectEqual(12, SetRenderTargets.last_param_1);
    try testing.expectEqual(13, SetRenderTargets.last_param_2);
    try testing.expectEqual(0, SetRenderTargets.last_param_3);
    try testing.expectEqual(123, hooks.depth_buffer_address);
}
