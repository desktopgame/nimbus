const Component = @import("Component.zig");

pub const RemapEntry = struct {
    from: *const Component.LookVTable,
    to: Component.UI,
};

pub const LookTable = []const RemapEntry;

pub fn applyLook(root: *Component, table: LookTable) void {
    walk(root, table);
    root.markLayoutDirty();
}

fn walk(node: *Component, table: LookTable) void {
    for (table) |entry| {
        if (node.ui.vtable == entry.from) {
            node.ui = entry.to;
            break;
        }
    }

    if (node.container) |container| {
        container.invalidateSizeCache();
        for (container.children.items) |elem| {
            walk(elem.component, table);
        }
    } else {
        node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx);
    }
}
