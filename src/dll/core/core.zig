const std = @import("std");
const build_info = @import("build_info");
const sdk = @import("../../sdk/root.zig");
const core = @import("../core/root.zig");
const game = @import("../game/root.zig");
const model = @import("../model/root.zig");

pub const Core = struct {
    allocator: std.mem.Allocator,
    frame_detector: game.FrameDetector,
    capturer: game.Capturer(build_info.game),
    hit_detector: core.HitDetector,
    move_detector: core.MoveDetector,
    move_measurer: core.MoveMeasurer,
    automation: core.Automation(.{}),
    controller: core.Controller,
    referee: core.Referee,
    /// Tracks the previous match phase to detect match completion transitions.
    previous_match_phase: ?model.MatchPhase = null,
    /// Stores the latest coach report (if coach is enabled and analysis was triggered).
    latest_coach_report: ?core.CoachReport = null,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{
            .allocator = allocator,
            .frame_detector = .{},
            .capturer = .{},
            .hit_detector = .{},
            .move_detector = .{},
            .move_measurer = .{},
            .automation = .{},
            .controller = core.Controller.init(allocator),
            .referee = core.Referee.init(allocator),
        };
    }

    pub fn deinit(self: *Self) void {
        self.controller.deinit();
        self.referee.deinit();
    }

    pub fn tick(
        self: *Self,
        base_dir: *const sdk.misc.BaseDir,
        settings: *const model.Settings,
        game_memory: *const game.Memory(build_info.game),
        context: anytype,
        processFrame: *const fn (context: @TypeOf(context), frame: *const model.Frame) void,
    ) void {
        if (!self.frame_detector.detect(build_info.game, game_memory)) {
            return;
        }
        var frame = self.capturer.captureFrame(game_memory);
        self.hit_detector.detect(&frame);
        self.move_detector.detect(&frame);
        self.move_measurer.measure(&frame);
        self.automation.processFrame(base_dir, &settings.automation, &self.controller, &frame);

        // AI Referee: monitor frame for violations in real-time
        if (settings.referee.enabled) {
            self.referee.settings = settings.referee;
            self.referee.tick(&frame);
        }

        // AI Coach: detect match completion and trigger post-match analysis
        if (settings.coach.enabled) {
            self.detectMatchCompletion(&frame, settings);
        }

        self.controller.processFrame(&frame, context, processFrame);
    }

    /// Detects when a match transitions from mid_round/round_end to not_in_a_match (match over).
    /// When detected, triggers coach analysis on the recorded frames.
    fn detectMatchCompletion(self: *Self, frame: *const model.Frame, settings: *const model.Settings) void {
        const current_phase = frame.match_phase orelse return;
        defer self.previous_match_phase = current_phase;

        const prev_phase = self.previous_match_phase orelse return;

        // Match completion: transition from active match to "not in a match"
        const was_in_match = (prev_phase == .mid_round or prev_phase == .round_end or prev_phase == .outro);
        const now_out_of_match = (current_phase == .not_in_a_match);

        if (was_in_match and now_out_of_match) {
            self.runCoachAnalysis(settings);
        }
    }

    /// Runs coach analysis on the current recording.
    /// Can also be called externally (e.g., via API request).
    pub fn runCoachAnalysis(self: *Self, settings: *const model.Settings) void {
        _ = settings;
        const frames = self.controller.recording.items;
        if (frames.len == 0) return;

        const analysis = core.Coach.analyzeReplay(
            self.allocator,
            frames,
            .player_1, // Analyze from player 1's perspective by default
        );

        const strategy_recs = core.Coach.generateStrategyGuide(
            self.allocator,
            frames,
            .player_1,
        );

        self.latest_coach_report = core.CoachReport.fromAnalysis(
            self.allocator,
            "live-match",
            "player_1",
            "player_2",
            &analysis,
            strategy_recs,
        );
    }

    /// Returns the latest coach report if available.
    pub fn getLatestCoachReport(self: *const Self) ?*const core.CoachReport {
        if (self.latest_coach_report) |*report| {
            return report;
        }
        return null;
    }

    /// Returns the current violation count from the referee.
    pub fn getRefereeViolationCount(self: *const Self) usize {
        return self.referee.getViolationCount();
    }

    /// Exports the referee report as JSON.
    pub fn exportRefereeReport(self: *const Self) []const u8 {
        return self.referee.exportReport(self.allocator);
    }

    pub fn update(
        self: *Self,
        delta_time: f32,
        context: anytype,
        processFrame: *const fn (context: @TypeOf(context), frame: *const model.Frame) void,
    ) void {
        self.automation.update(&self.controller);
        self.controller.update(delta_time, context, processFrame);
    }
};
