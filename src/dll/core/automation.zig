const std = @import("std");
const sdk = @import("../../sdk/root.zig");
const core = @import("../core/root.zig");
const model = @import("../model/root.zig");

pub const Automation = struct {
    state: State = .idle,
    previous_frame_match_phase: ?model.MatchPhase = null,

    const Self = @This();
    const State = union(enum) {
        idle: void,
        recording: model.Source,
        saving: void,
    };
    const directory_name = "recordings";

    pub fn processFrame(
        self: *Self,
        base_dir: *const sdk.misc.BaseDir,
        settings: *const model.AutomationSettings,
        controller: *core.Controller,
        frame: *const model.Frame,
    ) void {
        defer self.previous_frame_match_phase = frame.match_phase;
        switch (self.state) {
            .idle => self.processIdleFrame(settings, controller, frame),
            .recording => |source| self.processRecordingFrame(base_dir, settings, controller, frame, source),
            .saving => self.processSavingFrame(controller),
        }
    }

    fn processIdleFrame(
        self: *Self,
        settings: *const model.AutomationSettings,
        controller: *core.Controller,
        frame: *const model.Frame,
    ) void {
        if (!settings.enabled) {
            return;
        }
        const first_frame_of_match = self.previous_frame_match_phase == .intro and frame.match_phase == .round_start;
        if (!first_frame_of_match) {
            return;
        }
        const source = frame.source orelse return;
        const setting = switch (source) {
            .live_game => settings.live_games,
            .replay_loading => settings.replays,
            .practice, .replay_playback => return,
        };
        switch (setting) {
            .do_not_record => return,
            .only_record, .record_and_save => {},
        }
        switch (controller.mode) {
            .record, .load, .save => return,
            .live, .pause, .playback, .scrub => {},
        }
        controller.clear();
        controller.record();
        self.state = .{ .recording = source };
    }

    fn processRecordingFrame(
        self: *Self,
        base_dir: *const sdk.misc.BaseDir,
        settings: *const model.AutomationSettings,
        controller: *core.Controller,
        frame: *const model.Frame,
        source: model.Source,
    ) void {
        const in_a_match = frame.match_phase != null and frame.match_phase != .not_in_a_match;
        const still_recording = controller.mode == .record;
        const source_changed = frame.source != source;
        const last_frame_of_match = self.previous_frame_match_phase == .round_end and frame.match_phase == .outro;
        if (in_a_match and still_recording and !source_changed and !last_frame_of_match) {
            return;
        }
        if (!still_recording) {
            self.state = .idle;
            return;
        }
        const setting = switch (source) {
            .live_game, .practice => settings.live_games,
            .replay_loading, .replay_playback => settings.replays,
        };
        switch (setting) {
            .do_not_record, .only_record => {
                controller.stop();
                self.state = .idle;
            },
            .record_and_save => {
                const last_frame = controller.getFrameAt(controller.getTotalFrames() -| 1) orelse frame;
                var buffer: [core.Controller.FilePath.max_len]u8 = undefined;
                if (constructSaveFilePath(&buffer, base_dir, last_frame, settings.save_format)) |path| {
                    controller.save(path);
                    self.state = .saving;
                } else |err| {
                    sdk.misc.error_context.append("Failed to construct save file path.", .{});
                    sdk.misc.error_context.logError(err);
                    controller.stop();
                    self.state = .idle;
                }
            },
        }
    }

    fn processSavingFrame(self: *Self, controller: *core.Controller) void {
        if (controller.mode == .save) {
            return;
        }
        controller.stop();
        self.state = .idle;
    }

    fn constructSaveFilePath(
        buffer: []u8,
        base_dir: *const sdk.misc.BaseDir,
        last_frame: *const model.Frame,
        format: model.RecordingFormat,
    ) ![]const u8 {
        var writer = std.Io.Writer.fixed(buffer);
        const p1: *const model.Player = last_frame.getPlayerById(.player_1);
        const p2: *const model.Player = last_frame.getPlayerById(.player_2);

        writer.print("{s}\\{s}\\", .{ base_dir.get(), directory_name }) catch |err| {
            sdk.misc.error_context.new("Failed to write directory path: {s}\\{s}\\", .{ base_dir.get(), directory_name });
            return err;
        };

        std.fs.cwd().makePath(buffer[0..writer.end]) catch |err| {
            sdk.misc.error_context.append("Failed to make directory: {s}", .{buffer[0..writer.end]});
            return err;
        };

        const p1_name = p1.name.asSlice();
        const p2_name = p2.name.asSlice();
        const is_character_invalid: [256]bool = comptime block: {
            var result = [1]bool{false} ** 256;
            for (0..31) |c| {
                result[c] = true;
            }
            result['<'] = true;
            result['>'] = true;
            result['"'] = true;
            result['/'] = true;
            result['\\'] = true;
            result['|'] = true;
            result['?'] = true;
            result['*'] = true;
            break :block result;
        };
        const placeholder_character = '_';
        if (p1.name.len > 0 and p2.name.len > 0) {
            var p1_iterator = (std.unicode.Utf8View{ .bytes = p1_name }).iterator();
            while (p1_iterator.nextCodepointSlice()) |codepoint| {
                if (codepoint.len == 1 and is_character_invalid[codepoint[0]]) {
                    writer.writeByte(placeholder_character) catch |err| {
                        sdk.misc.error_context.new("Failed to write player 1 name: {s}", .{p1_name});
                        return err;
                    };
                } else {
                    writer.writeAll(codepoint) catch |err| {
                        sdk.misc.error_context.new("Failed to write player 1 name: {s}", .{p1_name});
                        return err;
                    };
                }
            }
            writer.writeAll(" vs ") catch |err| {
                sdk.misc.error_context.new("Failed to write: vs", .{});
                return err;
            };
            var p2_iterator = (std.unicode.Utf8View{ .bytes = p2_name }).iterator();
            while (p2_iterator.nextCodepointSlice()) |codepoint| {
                if (codepoint.len == 1 and is_character_invalid[codepoint[0]]) {
                    writer.writeByte(placeholder_character) catch |err| {
                        sdk.misc.error_context.new("Failed to write player 2 name: {s}", .{p2_name});
                        return err;
                    };
                } else {
                    writer.writeAll(codepoint) catch |err| {
                        sdk.misc.error_context.new("Failed to write player 2 name: {s}", .{p2_name});
                        return err;
                    };
                }
            }
        }

        if (p1.rounds_won) |p1_rounds| {
            if (p2.rounds_won) |p2_round| {
                writer.print("{}-{}  ", .{ p1_rounds, p2_round }) catch |err| {
                    sdk.misc.error_context.new("Failed to write match score: {}-{}", .{ p1_rounds, p2_round });
                    return err;
                };
            }
        }

        const nano = std.time.nanoTimestamp();
        const ts = sdk.misc.Timestamp.fromNano(nano, .local) catch |err| {
            sdk.misc.error_context.append("Failed to construct timestamp structure for nano timestamp: {}", .{nano});
            return err;
        };
        writer.print(
            "{:0>4}-{:0>2}-{:0>2}T{:0>2}-{:0>2}-{:0>2}",
            .{ @abs(ts.year), ts.month, ts.day, ts.hour, ts.minute, ts.second },
        ) catch |err| {
            sdk.misc.error_context.new("Failed to write the timestamp part of file name.", .{});
            return err;
        };

        writer.writeAll(format.getFileExtension()) catch |err| {
            sdk.misc.error_context.new("Failed to write file extension: {s}", .{format.getFileExtension()});
            return err;
        };

        return buffer[0..writer.end];
    }
};
