const std = @import("std");
const w32 = @import("win32").everything;
const sdk = @import("../../sdk/root.zig");

/// HTTP API client for communicating with the tournament SaaS platform.
/// Uses Win32 WinHTTP for network requests since we're running as a Windows DLL.
pub const ApiClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    pending_queue: std.ArrayList(PendingRequest),
    is_connected: bool = false,
    last_error: ?ApiError = null,

    const Self = @This();
    const max_retries: u32 = 3;
    const request_timeout_ms: u32 = 5000;

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, api_key: []const u8) Self {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .api_key = api_key,
            .pending_queue = std.ArrayList(PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_queue.deinit();
    }

    /// Authenticates with the tournament platform API.
    pub fn authenticate(self: *Self) !bool {
        const response = self.sendHttpRequest(.post, "/api/auth/verify", null) catch |err| {
            self.last_error = .{ .kind = .network_error, .message = "Authentication failed" };
            return err;
        };
        self.is_connected = (response.status >= 200 and response.status < 300);
        return self.is_connected;
    }

    /// Sends a heartbeat to maintain connection.
    pub fn heartbeat(self: *Self) !bool {
        if (!self.is_connected) {
            return self.authenticate();
        }

        const response = self.sendHttpRequest(.get, "/api/health", null) catch |err| {
            self.is_connected = false;
            self.last_error = .{ .kind = .network_error, .message = "Heartbeat failed" };
            return err;
        };

        self.is_connected = (response.status >= 200 and response.status < 300);
        return self.is_connected;
    }

    /// Sends a violation alert to the tournament platform (real-time).
    /// If the request fails, it's queued for retry.
    pub fn sendViolationAlert(self: *Self, violation_json: []const u8) !void {
        const response = self.sendHttpRequest(.post, "/api/violations", violation_json) catch |err| {
            self.queueRequest(.{
                .method = .post,
                .path = "/api/violations",
                .body = violation_json,
                .retry_count = 0,
                .created_at = std.time.timestamp(),
            });
            return err;
        };

        if (response.status >= 400) {
            self.last_error = .{ .kind = .server_error, .message = "Violation alert rejected" };
            return error.RequestFailed;
        }
    }

    /// Submits a coaching report to the tournament platform (post-match).
    pub fn submitCoachingReport(self: *Self, report_json: []const u8) !void {
        const response = self.sendHttpRequest(.post, "/api/coaching", report_json) catch |err| {
            self.queueRequest(.{
                .method = .post,
                .path = "/api/coaching",
                .body = report_json,
                .retry_count = 0,
                .created_at = std.time.timestamp(),
            });
            return err;
        };

        if (response.status >= 400) {
            self.last_error = .{ .kind = .server_error, .message = "Coaching report rejected" };
            return error.RequestFailed;
        }
    }

    /// Submits match result data.
    pub fn submitMatchResult(self: *Self, match_id: []const u8, result_json: []const u8) !void {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/matches/{s}/result", .{match_id}) catch return error.PathTooLong;

        const response = self.sendHttpRequest(.post, path, result_json) catch |err| {
            return err;
        };

        if (response.status >= 400) {
            return error.RequestFailed;
        }
    }

    /// Processes queued requests that previously failed.
    /// Returns the number of successfully processed requests.
    pub fn processPendingRequests(self: *Self) u32 {
        var processed: u32 = 0;
        var i: usize = 0;

        while (i < self.pending_queue.items.len) {
            var pending = &self.pending_queue.items[i];

            if (pending.retry_count >= max_retries) {
                // Remove after max retries exceeded
                _ = self.pending_queue.orderedRemove(i);
                continue;
            }

            const response = self.sendHttpRequest(pending.method, pending.path, pending.body) catch {
                pending.retry_count += 1;
                i += 1;
                continue;
            };

            if (response.status < 400) {
                processed += 1;
                _ = self.pending_queue.orderedRemove(i);
            } else {
                pending.retry_count += 1;
                i += 1;
            }
        }

        return processed;
    }

    /// Returns the number of pending (queued) requests.
    pub fn getPendingCount(self: *const Self) usize {
        return self.pending_queue.items.len;
    }

    /// Returns the last error, if any.
    pub fn getLastError(self: *const Self) ?ApiError {
        return self.last_error;
    }

    // ========================================================================
    // Internal HTTP implementation using Win32 WinHTTP
    // ========================================================================

    fn sendHttpRequest(self: *Self, method: HttpMethod, path: []const u8, body: ?[]const u8) !Response {
        // Parse endpoint URL to extract host and port
        const parsed = parseUrl(self.endpoint) orelse return error.InvalidUrl;

        // Convert strings to wide (UTF-16) for WinHTTP
        var host_wide: [256]u16 = undefined;
        const host_len = std.unicode.utf8ToUtf16Le(&host_wide, parsed.host) catch return error.InvalidUrl;
        host_wide[host_len] = 0;

        var path_wide: [512]u16 = undefined;
        const path_len = std.unicode.utf8ToUtf16Le(&path_wide, path) catch return error.InvalidUrl;
        path_wide[path_len] = 0;

        const method_str = switch (method) {
            .get => "GET",
            .post => "POST",
            .put => "PUT",
            .delete => "DELETE",
            .patch => "PATCH",
        };
        var method_wide: [16]u16 = undefined;
        const method_len = std.unicode.utf8ToUtf16Le(&method_wide, method_str) catch return error.InvalidUrl;
        method_wide[method_len] = 0;

        // WinHTTP session
        const user_agent = std.unicode.utf8ToUtf16LeStringLiteral("Irony-AI-Client/1.0");
        const h_session = w32.WinHttpOpen(
            user_agent,
            w32.WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
            null, // proxy
            null, // proxy bypass
            0, // flags
        ) orelse return error.SessionOpenFailed;
        defer _ = w32.WinHttpCloseHandle(h_session);

        // Connect to server
        const h_connect = w32.WinHttpConnect(
            h_session,
            @ptrCast(&host_wide),
            parsed.port,
            0, // reserved
        ) orelse return error.ConnectionFailed;
        defer _ = w32.WinHttpCloseHandle(h_connect);

        // Create request
        const flags: u32 = if (parsed.is_https) w32.WINHTTP_FLAG_SECURE else 0;
        const h_request = w32.WinHttpOpenRequest(
            h_connect,
            @ptrCast(&method_wide),
            @ptrCast(&path_wide),
            null, // version (HTTP/1.1)
            null, // referrer
            null, // accept types
            flags,
        ) orelse return error.RequestCreationFailed;
        defer _ = w32.WinHttpCloseHandle(h_request);

        // Set timeout
        _ = w32.WinHttpSetTimeouts(h_request, request_timeout_ms, request_timeout_ms, request_timeout_ms, request_timeout_ms);

        // Add authorization header
        var auth_header_buf: [512]u8 = undefined;
        const auth_header = std.fmt.bufPrint(&auth_header_buf, "Authorization: Bearer {s}\r\nContent-Type: application/json\r\n", .{self.api_key}) catch return error.HeaderTooLong;
        var auth_header_wide: [1024]u16 = undefined;
        const auth_header_len = std.unicode.utf8ToUtf16Le(&auth_header_wide, auth_header) catch return error.HeaderTooLong;
        auth_header_wide[auth_header_len] = 0;

        _ = w32.WinHttpAddRequestHeaders(
            h_request,
            @ptrCast(&auth_header_wide),
            @intCast(auth_header_len),
            w32.WINHTTP_ADDREQ_FLAG_ADD,
        );

        // Send request
        const body_ptr: ?*const anyopaque = if (body) |b| @ptrCast(b.ptr) else null;
        const body_len: u32 = if (body) |b| @intCast(b.len) else 0;

        if (w32.WinHttpSendRequest(
            h_request,
            null, // additional headers
            0, // additional headers length
            body_ptr,
            body_len,
            body_len,
            0, // context
        ) == 0) {
            return error.SendFailed;
        }

        // Receive response
        if (w32.WinHttpReceiveResponse(h_request, null) == 0) {
            return error.ReceiveFailed;
        }

        // Get status code
        var status_code: u32 = 0;
        var status_size: u32 = @sizeOf(u32);
        _ = w32.WinHttpQueryHeaders(
            h_request,
            w32.WINHTTP_QUERY_STATUS_CODE | w32.WINHTTP_QUERY_FLAG_NUMBER,
            null,
            @ptrCast(&status_code),
            &status_size,
            null,
        );

        // Read response body (up to 64KB)
        var response_body = std.ArrayList(u8).init(self.allocator);
        var bytes_available: u32 = 0;
        while (true) {
            _ = w32.WinHttpQueryDataAvailable(h_request, &bytes_available);
            if (bytes_available == 0) break;

            const read_size = @min(bytes_available, 8192);
            var read_buf: [8192]u8 = undefined;
            var bytes_read: u32 = 0;

            if (w32.WinHttpReadData(h_request, &read_buf, read_size, &bytes_read) == 0) break;
            if (bytes_read == 0) break;

            response_body.appendSlice(read_buf[0..bytes_read]) catch break;

            if (response_body.items.len > 65536) break; // Cap at 64KB
        }

        return Response{
            .status = @intCast(status_code),
            .body = response_body.toOwnedSlice() catch "",
        };
    }

    fn queueRequest(self: *Self, pending: PendingRequest) void {
        self.pending_queue.append(pending) catch {};
    }

    fn parseUrl(url: []const u8) ?ParsedUrl {
        var result = ParsedUrl{
            .host = "",
            .port = 443,
            .is_https = true,
        };

        var remaining = url;

        if (std.mem.startsWith(u8, remaining, "https://")) {
            remaining = remaining[8..];
            result.is_https = true;
            result.port = 443;
        } else if (std.mem.startsWith(u8, remaining, "http://")) {
            remaining = remaining[7..];
            result.is_https = false;
            result.port = 80;
        } else {
            return null;
        }

        // Find host (up to : or / or end)
        var host_end: usize = remaining.len;
        for (remaining, 0..) |c, i| {
            if (c == ':' or c == '/') {
                host_end = i;
                break;
            }
        }
        result.host = remaining[0..host_end];

        // Parse optional port
        if (host_end < remaining.len and remaining[host_end] == ':') {
            const port_start = host_end + 1;
            var port_end: usize = remaining.len;
            for (remaining[port_start..], 0..) |c, i| {
                if (c == '/') {
                    port_end = port_start + i;
                    break;
                }
            }
            result.port = std.fmt.parseInt(u16, remaining[port_start..port_end], 10) catch result.port;
        }

        if (result.host.len == 0) return null;
        return result;
    }
};

// ============================================================================
// Types
// ============================================================================

pub const HttpMethod = enum {
    get,
    post,
    put,
    delete,
    patch,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const PendingRequest = struct {
    method: HttpMethod,
    path: []const u8,
    body: ?[]const u8,
    retry_count: u32,
    created_at: i64,
};

pub const ApiError = struct {
    kind: ErrorKind,
    message: []const u8,
};

pub const ErrorKind = enum {
    network_error,
    server_error,
    timeout,
    authentication_failed,
};

const ParsedUrl = struct {
    host: []const u8,
    port: u16,
    is_https: bool,
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "ApiClient.init should initialize correctly" {
    var client = ApiClient.init(testing.allocator, "https://api.example.com", "test_key");
    defer client.deinit();
    try testing.expectEqualStrings("https://api.example.com", client.endpoint);
    try testing.expectEqualStrings("test_key", client.api_key);
    try testing.expectEqual(false, client.is_connected);
    try testing.expectEqual(@as(usize, 0), client.getPendingCount());
}

test "parseUrl should parse https URL correctly" {
    const result = ApiClient.parseUrl("https://api.gameparlour.com");
    try testing.expect(result != null);
    try testing.expectEqualStrings("api.gameparlour.com", result.?.host);
    try testing.expectEqual(@as(u16, 443), result.?.port);
    try testing.expectEqual(true, result.?.is_https);
}

test "parseUrl should parse http URL with port" {
    const result = ApiClient.parseUrl("http://localhost:8080/api");
    try testing.expect(result != null);
    try testing.expectEqualStrings("localhost", result.?.host);
    try testing.expectEqual(@as(u16, 8080), result.?.port);
    try testing.expectEqual(false, result.?.is_https);
}

test "parseUrl should handle invalid URL" {
    const result = ApiClient.parseUrl("not-a-url");
    try testing.expectEqual(@as(?ParsedUrl, null), result);
}

test "Response should store correct values" {
    const response = Response{
        .status = 200,
        .body = "OK",
    };
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("OK", response.body);
}

test "PendingRequest should store correct values" {
    const pending = PendingRequest{
        .method = .post,
        .path = "/api/violations",
        .body = "{}",
        .retry_count = 0,
        .created_at = 1000,
    };
    try testing.expectEqual(HttpMethod.post, pending.method);
    try testing.expectEqualStrings("/api/violations", pending.path);
    try testing.expectEqual(@as(u32, 0), pending.retry_count);
}
