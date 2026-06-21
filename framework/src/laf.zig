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
    }
    if (node.container == null and node.tree_children == null) {
        node.min_size = node.ui.vtable.measureMinSize(node, node.ui.ctx);
    }

    const child_count = node.automationChildCount();
    for (0..child_count) |i| {
        walk(node.automationChildAt(i), table);
    }
    if (node.detached_look_roots) |roots| {
        const root_count = roots.count(node);
        for (0..root_count) |i| {
            walk(roots.at(node, i), table);
        }
    }
}
