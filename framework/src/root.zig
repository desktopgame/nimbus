const std = @import("std");

pub const awt = @import("awt");

test {
    std.testing.refAllDecls(@This());
}
