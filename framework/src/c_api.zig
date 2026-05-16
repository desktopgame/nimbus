const framework = @import("nimbus");

export fn nimbus_double(x: c_int) c_int {
    return framework.awt.c.nimbus_awt_test_double(x);
}

export fn nimbus_backend_version() [*:0]const u8 {
    return @ptrCast(framework.awt.c.nimbus_awt_backend_version());
}
