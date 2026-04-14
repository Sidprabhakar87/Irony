const std = @import("std");
const imgui = @import("imgui");
const build_info = @import("build_info");
const sdk = @import("../../sdk/root.zig");
const core = @import("../core/root.zig");
const model = @import("../model/root.zig");
const ui = @import("root.zig");

pub const MainWindow = struct {
    match_bar: ui.MatchBar = .{},
    quadrant_layout: ui.QuadrantLayout = .{},
    view: ui.View = .{},
    details: ui.Details = .{},
    controls: ui.Controls(.{}) = .{},
    file_menu: ui.FileMenu(.{}) = .{},
    match_bar_height: f32 = 0,
    controls_height: f32 = 0,
    menu_bar_right_side_width: f32 = 0,

    const Self = @This();
    const QuadrantContext = struct {
        self: *Self,
        settings: *const model.Settings,
        frame: ?*const model.Frame,
    };

    pub fn processFrame(self: *Self, settings: *const model.Settings, frame: *const model.Frame) void {
        self.match_bar.processFrame(&settings.match_bar, frame);
        self.view.processFrame(settings, frame);
        self.details.processFrame(&settings.details, frame);
    }

    pub fn update(self: *Self, delta_time: f32, controller: *core.Controller) void {
        self.match_bar.update(delta_time);
        self.view.update(delta_time);
        self.details.update(delta_time);
        self.file_menu.update(controller);
    }

    pub fn handleKeybinds(self: *Self, controller: *core.Controller) void {
        self.controls.handleKeybinds(controller);
    }

    pub fn draw(
        self: *Self,
        ui_instance: *ui.Ui,
        base_dir: *const sdk.misc.BaseDir,
        file_dialog_context: *imgui.ImGuiFileDialog,
        controller: *core.Controller,
        settings: *model.Settings,
        latest_version: ui.LatestVersion,
        memory_usage: usize,
    ) void {
        const display_size = imgui.igGetIO_Nil().*.DisplaySize;
        imgui.igSetNextWindowPos(
            .{ .x = 0.5 * display_size.x, .y = 0.5 * display_size.y },
            imgui.ImGuiCond_FirstUseEver,
            .{ .x = 0.5, .y = 0.5 },
        );
        imgui.igSetNextWindowSize(.{ .x = 960, .y = 640 }, imgui.ImGuiCond_FirstUseEver);

        var title_buffer: [260]u8 = undefined;
        const asterisk = if (controller.contains_unsaved_changes) "*" else "";
        const file_name = if (controller.getFilePath()) |path| sdk.os.pathToFileName(path) else "Untitled";
        const title = std.fmt.bufPrintZ(
            &title_buffer,
            build_info.display_name ++ " - {s}{s}###main_window",
            .{ asterisk, file_name },
        ) catch build_info.display_name ++ "###main_window";

        const render_content = imgui.igBegin(title, &ui_instance.is_open, imgui.ImGuiWindowFlags_MenuBar);
        defer imgui.igEnd();
        if (!render_content) {
            return;
        }

        self.drawMenuBar(
            ui_instance,
            base_dir,
            file_dialog_context,
            controller,
            &settings.misc,
            latest_version,
            memory_usage,
        );

        if (imgui.igBeginChild_Str("match_bar", .{ .y = self.match_bar_height }, 0, 0)) {
            const start_y = imgui.igGetCursorPosY();
            self.match_bar.draw(&settings.match_bar);
            self.match_bar_height = imgui.igGetCursorPosY() - start_y;
        }
        imgui.igEndChild();
        if (imgui.igBeginChild_Str("views", .{ .y = -self.controls_height }, 0, imgui.ImGuiWindowFlags_NoScrollbar)) {
            const context = QuadrantContext{
                .self = self,
                .settings = settings,
                .frame = controller.getCurrentFrame(),
            };
            self.quadrant_layout.draw(context, &.{
                .top_left = .{ .id = "front", .content = drawFrontView, .window_flags = imgui.ImGuiWindowFlags_NoMove },
                .top_right = .{ .id = "side", .content = drawSideView, .window_flags = imgui.ImGuiWindowFlags_NoMove },
                .bottom_left = .{ .id = "top", .content = drawTopView, .window_flags = imgui.ImGuiWindowFlags_NoMove },
                .bottom_right = .{ .id = "details", .content = drawDetails },
            });
        }
        imgui.igEndChild();
        if (imgui.igBeginChild_Str("controls", .{}, 0, 0)) {
            const start_y = imgui.igGetCursorPosY();
            self.controls.draw(controller);
            self.controls_height = imgui.igGetCursorPosY() - start_y;
        }
        imgui.igEndChild();
    }

    fn drawMenuBar(
        self: *Self,
        ui_instance: *ui.Ui,
        base_dir: *const sdk.misc.BaseDir,
        file_dialog_context: *imgui.ImGuiFileDialog,
        controller: *core.Controller,
        settings: *const model.MiscSettings,
        latest_version: ui.LatestVersion,
        memory_usage: usize,
    ) void {
        if (!imgui.igBeginMenuBar()) {
            return;
        }
        defer imgui.igEndMenuBar();

        self.file_menu.draw(base_dir, file_dialog_context, controller, &ui_instance.is_open);
        self.view.camera.drawMenuBar();
        drawSettingsButton(ui_instance);
        drawHelpMenu(ui_instance);

        if (!settings.show_memory_usage and !settings.show_version_info) {
            return;
        }

        var available_size: imgui.ImVec2 = undefined;
        imgui.igGetContentRegionAvail(&available_size);
        const empty_space_width = @max(available_size.x - self.menu_bar_right_side_width, 0);
        imgui.igSetCursorPosX(imgui.igGetCursorPosX() + empty_space_width);

        const right_side_start_x = imgui.igGetCursorPosX();
        if (settings.show_memory_usage) {
            ui.drawMemoryUsage(memory_usage);
        }
        if (settings.show_version_info) {
            ui.drawVersionInfo(latest_version, .{});
        }
        const right_side_end_x = imgui.igGetCursorPosX() - imgui.igGetStyle().*.ItemSpacing.x;
        self.menu_bar_right_side_width = right_side_end_x - right_side_start_x;
    }

    fn drawSettingsButton(ui_instance: *ui.Ui) void {
        if (!imgui.igMenuItem_Bool(ui.SettingsWindow.name, null, false, true)) {
            return;
        }
        ui_instance.settings_window.is_open = !ui_instance.settings_window.is_open;
        if (ui_instance.settings_window.is_open) {
            imgui.igSetWindowFocus_Str(ui.SettingsWindow.name);
        }
    }

    fn drawHelpMenu(ui_instance: *ui.Ui) void {
        if (!imgui.igBeginMenu("Help", true)) {
            return;
        }
        defer imgui.igEndMenu();
        if (imgui.igMenuItem_Bool(ui.LogsWindow.name, null, false, true)) {
            ui_instance.logs_window.is_open = true;
            imgui.igSetWindowFocus_Str(ui.LogsWindow.name);
        }
        if (imgui.igMenuItem_Bool(ui.GameMemoryWindow.name, null, false, true)) {
            ui_instance.game_memory_window.is_open = true;
            imgui.igSetWindowFocus_Str(ui.GameMemoryWindow.name);
        }
        if (imgui.igMenuItem_Bool(ui.FrameWindow.name, null, false, true)) {
            ui_instance.frame_window.is_open = true;
            imgui.igSetWindowFocus_Str(ui.FrameWindow.name);
        }
        imgui.igSeparator();
        if (imgui.igBeginMenu("Donate", true)) {
            defer imgui.igEndMenu();
            if (imgui.igMenuItem_Bool("One Time Donation", null, false, true)) {
                const link = build_info.donation_links.one_time;
                if (openLink(link)) {
                    sdk.ui.toasts.send(.info, null, "The donation page has been opened in the browser.", .{});
                } else |err| {
                    sdk.misc.error_context.append("Failed to open link: {s}", .{link});
                    sdk.misc.error_context.logError(err);
                }
            }
            if (imgui.igMenuItem_Bool("Recurring Donation", null, false, true)) {
                const link = build_info.donation_links.recurring;
                if (openLink(link)) {
                    sdk.ui.toasts.send(.info, null, "The donation page has been opened in the browser.", .{});
                } else |err| {
                    sdk.misc.error_context.append("Failed to open link: {s}", .{link});
                    sdk.misc.error_context.logError(err);
                }
            }
        }
        if (imgui.igMenuItem_Bool(ui.AboutWindow(.{}).name, null, false, true)) {
            ui_instance.about_window.is_open = true;
            imgui.igSetWindowFocus_Str(ui.AboutWindow(.{}).name);
        }
    }

    fn drawFrontView(context: QuadrantContext) void {
        const frame = context.frame orelse return;
        context.self.view.draw(context.settings, frame, .front);
    }

    fn drawSideView(context: QuadrantContext) void {
        const frame = context.frame orelse return;
        context.self.view.draw(context.settings, frame, .side);
    }

    fn drawTopView(context: QuadrantContext) void {
        const frame = context.frame orelse return;
        context.self.view.draw(context.settings, frame, .top);
    }

    fn drawDetails(context: QuadrantContext) void {
        context.self.details.draw(&context.settings.details);
    }
};

fn openLink(url: [:0]const u8) !void {
    const open = imgui.igGetPlatformIO_Nil().*.Platform_OpenInShellFn orelse {
        sdk.misc.error_context.new("Platform_OpenInShellFn is null.", .{});
        return error.LinkOpenError;
    };
    const success = open(imgui.igGetCurrentContext(), url);
    if (!success) {
        sdk.misc.error_context.new("Platform_OpenInShellFn returned false.", .{});
        return error.LinkOpenError;
    }
}
