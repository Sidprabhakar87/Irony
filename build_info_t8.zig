const build = @import("build.zig.zon");

pub const Game = enum { t7, t8 };
pub const game: Game = .t8;
pub const RenderingApi = enum { dx11, dx12 };
pub const rendering_api: RenderingApi = .dx12;
pub const name = build.name;
pub const display_name = build.display_name;
pub const version = build.version;
pub const game_version = build.t8_version;
pub const recording_format_version = build.recording_format_version;
pub const author = build.author;
pub const home_page = build.home_page;
pub const latest_version_download_page = build.latest_version_download_page;
pub const donation_links = build.donation_links;
pub const contributors = build.contributors;
