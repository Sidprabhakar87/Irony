const std = @import("std");
const sdk = @import("../../sdk/root.zig");

pub const ApiClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    api_key: []const u8,
    http_client: HttpClient,
    pending_queue: std.ArrayList(PendingRequest),
    is_connected: bool = false,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8, api_key: []const u8) Self {
        return .{
            .allocator = allocator,
            .endpoint = endpoint,
            .api_key = api_key,
            .http_client = HttpClient{},
            .pending_queue = std.ArrayList(PendingRequest).init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.pending_queue.deinit();
    }

    pub fn authenticate(self: *Self) !bool {
        var request = Request{
            .method = .post,
            .path = "/api/auth/verify",
            .headers = &.{
                .{ .key = "Authorization", .value = self.api_key },
                .{ .key = "Content-Type", .value = "application/json" },
            },
            .body = null,
        };

        const response = try self.sendRequest(&request);
        self.is_connected = response.status == 200;
        return self.is_connected;
    }

    pub fn heartbeat(self: *Self) !bool {
        if (!self.is_connected) {
            self.is_connected = try self.authenticate();
        }
        return self.is_connected;
    }

    pub fn sendViolationAlert(self: *Self, violation_json: []const u8) !void {
        var request = Request{
            .method = .post,
            .path = "/api/violations",
            .headers = &.{
                .{ .key = "Authorization", .value = self.api_key },
                .{ .key = "Content-Type", .value = "application/json" },
            },
            .body = violation_json,
        };

        const response = self.sendRequest(&request) catch |err| {
            try self.queueRequest(.{
                .request = request,
                .retry_count = 0,
                .created_at = std.time.timestamp(),
            });
            return err;
        };

        if (response.status >= 400) {
            return error.RequestFailed;
        }
    }

    pub fn submitCoachingReport(self: *Self, report_json: []const u8) !void {
        var request = Request{
            .method = .post,
            .path = "/api/coaching",
            .headers = &.{
                .{ .key = "Authorization", .value = self.api_key },
                .{ .key = "Content-Type", .value = "application/json" },
            },
            .body = report_json,
        };

        const response = self.sendRequest(&request) catch |err| {
            try self.queueRequest(.{
                .request = request,
                .retry_count = 0,
                .created_at = std.time.timestamp(),
            });
            return err;
        };

        if (response.status >= 400) {
            return error.RequestFailed;
        }
    }

    pub fn getMatchData(self: *Self, match_id: []const u8) ![]const u8 {
        var request = Request{
            .method = .get,
            .path = try std.fmt.allocPrint(self.allocator, "/api/matches/{s}", .{match_id}),
            .headers = &.{
                .{ .key = "Authorization", .value = self.api_key },
            },
            .body = null,
        };
        defer self.allocator.free(request.path);

        const response = try self.sendRequest(&request);
        return response.body;
    }

    pub fn submitMatchResult(self: *Self, match_id: []const u8, result_json: []const u8) !void {
        var request = Request{
            .method = .post,
            .path = try std.fmt.allocPrint(self.allocator, "/api/matches/{s}/result", .{match_id}),
            .headers = &.{
                .{ .key = "Authorization", .value = self.api_key },
                .{ .key = "Content-Type", .value = "application/json" },
            },
            .body = result_json,
        };
        defer self.allocator.free(request.path);

        const response = try self.sendRequest(&request);
        if (response.status >= 400) {
            return error.RequestFailed;
        }
    }

    fn sendRequest(self: *Self, request: *const Request) !Response {
        var url_buffer: [512]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buffer, "{s}{s}", .{ self.endpoint, request.path });

        var headers_buffer: [256]u8 = undefined;
        var headers_str: []u8 = &.{};
        for (request.headers) |header| {
            const header_line = try std.fmt.bufPrint(&headers_buffer, "{s}: {s}\r\n", .{
                header.key, header.value,
            });
            headers_str = try std.mem.concat(self.allocator, u8, &.{ headers_str, header_line });
        }

        _ = url;
        _ = headers_str;
        _ = request;

        return Response{
            .status = 200,
            .body = "",
        };
    }

    fn queueRequest(self: *Self, pending: PendingRequest) !void {
        try self.pending_queue.append(pending);
    }

    pub fn processPendingRequests(self: *Self) !u32 {
        var processed: u32 = 0;
        var failed_indices = std.ArrayList(usize).init(self.allocator);
        defer failed_indices.deinit();

        for (self.pending_queue.items, 0..) |*pending, i| {
            if (pending.retry_count >= max_retries) {
                continue;
            }

            const response = self.sendRequest(&pending.request) catch {
                pending.retry_count += 1;
                failed_indices.append(i) catch {};
                continue;
            };

            if (response.status < 400) {
                processed += 1;
            } else {
                pending.retry_count += 1;
                failed_indices.append(i) catch {};
            }
        }

        var offset: usize = 0;
        for (failed_indices.items) |idx| {
            self.pending_queue.delete(idx - offset);
            offset += 1;
        }

        return processed;
    }

    const max_retries = 3;
};

pub const Request = struct {
    method: HttpMethod,
    path: []const u8,
    headers: []const Header,
    body: ?[]const u8,
};

pub const Response = struct {
    status: u16,
    body: []const u8,
};

pub const HttpMethod = enum {
    get,
    post,
    put,
    delete,
    patch,
};

pub const Header = struct {
    key: []const u8,
    value: []const u8,
};

pub const HttpClient = struct {};

pub const PendingRequest = struct {
    request: Request,
    retry_count: u32,
    created_at: i64,
};

const testing = std.testing;

test "ApiClient.init should initialize correctly" {
    var client = ApiClient.init(std.heap.page_allocator, "https://api.example.com", "test_key");
    defer client.deinit();
    try testing.expectEqualStrings("https://api.example.com", client.endpoint);
    try testing.expectEqualStrings("test_key", client.api_key);
    try testing.expectEqual(false, client.is_connected);
}

test "Request should store correct values" {
    const request = Request{
        .method = .get,
        .path = "/api/test",
        .headers = &.{},
        .body = null,
    };
    try testing.expectEqual(.get, request.method);
    try testing.expectEqualStrings("/api/test", request.path);
}

test "Response should store correct values" {
    const response = Response{
        .status = 200,
        .body = "OK",
    };
    try testing.expectEqual(@as(u16, 200), response.status);
    try testing.expectEqualStrings("OK", response.body);
}