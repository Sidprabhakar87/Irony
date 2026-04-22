const std = @import("std");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    if (args.len != 4) {
        return error.WrongNumberOfArguments;
    }
    const path = args[1];
    const find = args[2];
    const replace = args[3];

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();

    var read_buffer: [4096]u8 = undefined;
    var file_reader = file.reader(&read_buffer);
    const reader = &file_reader.interface;

    var write_buffer: [4096]u8 = undefined;
    var std_writer = std.fs.File.stdout().writer(&write_buffer);
    const writer = &std_writer.interface;

    var find_index: usize = 0;
    var replace_count: usize = 0;
    while (true) {
        const byte = reader.takeByte() catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (byte == find[find_index]) {
            find_index += 1;
            if (find_index == find.len) {
                try writer.writeAll(replace);
                replace_count += 1;
                find_index = 0;
            }
        } else {
            try writer.writeAll(find[0..find_index]);
            try writer.writeByte(byte);
            find_index = 0;
        }
    }
    try writer.writeAll(find[0..find_index]);

    try writer.flush();

    if (replace_count <= 0) {
        return error.NoMatchesFound;
    }
}
