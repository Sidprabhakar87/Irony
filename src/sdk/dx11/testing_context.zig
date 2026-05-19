const std = @import("std");
const builtin = @import("builtin");
const w32 = @import("win32").everything;
const misc = @import("../misc/root.zig");
const os = @import("../os/root.zig");
const dx11 = @import("root.zig");
const w = std.unicode.utf8ToUtf16LeStringLiteral;

pub const TestingContext = struct {
    window_class: w32.WNDCLASSEXW,
    window: w32.HWND,
    device: *w32.ID3D11Device,
    device_context: *w32.ID3D11DeviceContext,
    swap_chain: *w32.IDXGISwapChain,
    test_allocation: *u8,

    const Self = @This();

    pub fn init() !Self {
        if (!builtin.is_test) {
            @compileError("TestingContext is only allowed to be used in tests.");
        }

        const module = try os.Module.getMain();

        const window_class = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = .{
                .HREDRAW = 1,
                .VREDRAW = 1,
            },
            .lpfnWndProc = w32.DefWindowProcW,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = module.handle,
            .hIcon = null,
            .hCursor = null,
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = w("TestingWindowClass"),
            .hIconSm = null,
        };
        const register_success = w32.RegisterClassExW(&window_class);
        if (register_success == 0) {
            misc.error_context.new("{f}", .{os.Error.getLast()});
            misc.error_context.append("RegisterClassExW returned 0.", .{});
            return error.OsError;
        }
        errdefer _ = w32.UnregisterClassW(window_class.lpszClassName, window_class.hInstance);

        const window = w32.CreateWindowExW(
            .{},
            window_class.lpszClassName,
            w("TestingWindowClass"),
            w32.WS_OVERLAPPEDWINDOW,
            0,
            0,
            200,
            100,
            null,
            null,
            window_class.hInstance,
            null,
        ) orelse {
            misc.error_context.new("{f}", .{os.Error.getLast()});
            misc.error_context.append("CreateWindowExW returned 0.", .{});
            return error.OsError;
        };
        errdefer _ = w32.DestroyWindow(window);

        const feature_levels = [_]w32.D3D_FEATURE_LEVEL{.@"10_1"};
        const swap_chain_desc = w32.DXGI_SWAP_CHAIN_DESC{
            .BufferDesc = .{
                .Width = 200,
                .Height = 100,
                .RefreshRate = .{ .Numerator = 60, .Denominator = 1 },
                .Format = w32.DXGI_FORMAT_R8G8B8A8_UNORM,
                .ScanlineOrdering = w32.DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED,
                .Scaling = w32.DXGI_MODE_SCALING_UNSPECIFIED,
            },
            .SampleDesc = .{ .Count = 1, .Quality = 0 },
            .BufferUsage = w32.DXGI_USAGE_RENDER_TARGET_OUTPUT,
            .BufferCount = 2,
            .OutputWindow = window,
            .Windowed = 1,
            .SwapEffect = .DISCARD,
            .Flags = @intFromEnum(w32.DXGI_SWAP_CHAIN_FLAG.ALLOW_MODE_SWITCH) |
                @intFromEnum(w32.DXGI_SWAP_CHAIN_FLAG.ALLOW_TEARING),
        };
        var device: *w32.ID3D11Device = undefined;
        var swap_chain: *w32.IDXGISwapChain = undefined;
        const result = w32.D3D11CreateDeviceAndSwapChain(
            null,
            .WARP,
            null,
            .{},
            &feature_levels,
            feature_levels.len,
            w32.D3D11_SDK_VERSION,
            &swap_chain_desc,
            &swap_chain,
            &device,
            null,
            null,
        );
        if (dx11.Error.from(result)) |err| {
            misc.error_context.new("{f}", .{err});
            misc.error_context.append("D3D11CreateDeviceAndSwapChain returned a failure value.", .{});
            return error.Dx11Error;
        }
        errdefer _ = device.IUnknown.Release();
        errdefer _ = swap_chain.IUnknown.Release();

        var maybe_device_context: ?*w32.ID3D11DeviceContext = undefined;
        device.GetImmediateContext(&maybe_device_context);
        const device_context = maybe_device_context orelse {
            misc.error_context.new("ID3D11Device.GetImmediateContext returned a null value.", .{});
            return error.Dx11Error;
        };
        errdefer _ = device_context.IUnknown.Release();

        const test_allocation = try std.testing.allocator.create(u8);

        return .{
            .window_class = window_class,
            .window = window,
            .device = device,
            .device_context = device_context,
            .swap_chain = swap_chain,
            .test_allocation = test_allocation,
        };
    }

    pub fn deinit(self: *const Self) void {
        _ = self.device_context.IUnknown.Release();
        _ = self.swap_chain.IUnknown.Release();
        _ = self.device.IUnknown.Release();
        _ = w32.DestroyWindow(self.window);
        _ = w32.UnregisterClassW(self.window_class.lpszClassName, self.window_class.hInstance);
        std.testing.allocator.destroy(self.test_allocation);
    }

    pub fn present(self: *const Self) !void {
        const result = self.swap_chain.Present(0, w32.DXGI_PRESENT_ALLOW_TEARING);
        if (dx11.Error.from(result)) |err| {
            misc.error_context.new("{f}", .{err});
            misc.error_context.append("IDXGISwapChain.Present returned a failure value.", .{});
            return error.Dx11Error;
        }
    }

    pub fn getHostContext(self: *const Self) dx11.HostContext {
        return .{
            .window = self.window,
            .device = self.device,
            .device_context = self.device_context,
            .swap_chain = self.swap_chain,
        };
    }
};

const testing = std.testing;

test "should init without errors" {
    if (@import("config").skip_gpu) {
        return error.SkipZigTest;
    }
    const context = try TestingContext.init();
    defer context.deinit();
}

test "getHostContext should return correct value" {
    if (@import("config").skip_gpu) {
        return error.SkipZigTest;
    }
    const context = try TestingContext.init();
    defer context.deinit();
    try testing.expectEqual(dx11.HostContext{
        .window = context.window,
        .device = context.device,
        .device_context = context.device_context,
        .swap_chain = context.swap_chain,
    }, context.getHostContext());
}
