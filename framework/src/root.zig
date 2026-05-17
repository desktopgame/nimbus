const std = @import("std");

pub const awt = @import("awt");

pub const Component = @import("Component.zig");
pub const Container = @import("Container.zig");
pub const Label = @import("Label.zig");

test {
    std.testing.refAllDecls(@This());
}
