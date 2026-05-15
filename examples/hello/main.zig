const std = @import("std");
const nimbus = @import("nimbus");

pub fn main() !void {
    const result = nimbus.awt.c.nimbus_awt_test_double(21);
    std.debug.print("nimbus_awt_test_double(21) = {d}\n", .{result});
}
