const framework = @import("nimbus");

export fn nmGetBackendVersion() [*:0]const u8 {
    return @ptrCast(framework.awt.c.nmGetBackendVersion());
}
