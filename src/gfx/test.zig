// This file collects all gfx module tests for host-based execution.
// Build: zig build test

comptime {
    _ = @import("font.zig");
    _ = @import("fb.zig");
    _ = @import("compositor.zig");
}
