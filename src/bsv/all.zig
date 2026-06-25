const std = @import("std");

test {
    _ = @import("hash.zig");
    _ = @import("ripemd.zig");
    _ = @import("primitives.zig");
    _ = @import("script.zig");
    _ = @import("builder.zig");
    _ = @import("wallet.zig");
    _ = @import("bkds.zig");
    _ = @import("brc43.zig");
    _ = @import("brc100.zig");
    _ = @import("basm.zig");
    _ = @import("overlay.zig");
    _ = @import("secp256k1.zig");
    _ = @import("beef.zig");
    _ = @import("x402.zig");
    _ = @import("../utxo/persistent.zig");
}
