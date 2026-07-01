const std = @import("std");

/// Central rebranding config.
/// To rebrand: replace the asset files and adjust colors/build mode here.
pub const config = struct {
    pub const accent_color: u32 = 0x199FFF; // SteamOS cyan-blue
    pub const bg_color: u32 = 0x111215;     // SteamOS dark background
    pub const text_color: u32 = 0xFFFFFF;
    pub const progress_color: u32 = 0x199FFF;
    pub const progress_bg: u32 = 0x3D4450;

    pub const title = "Ulises Kernel";
    pub const subtitle = "BSV Unikernel";

    // Build mode: controls which assets are included
    // .minimal — no images, no wallpaper, just framebuffer text
    // .steamos — SteamOS themed (default)
    // .custom  — user-provided assets from assets/
    pub const mode: enum { minimal, steamos, custom } = .steamos;
};
