//! Overlay stack for a Window: floating layers (popup menus, combobox
//! dropdowns, drag ghosts, tooltips) drawn above the container and menu bar.
//! Extracted from Window so the overlay lifecycle lives in one place. Depends
//! only on Component + awt (not Window), so it can be reasoned about and reused
//! on its own. See `framework/doc/overlay.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");

const OverlayManager = @This();

/// Input model of an overlay.
pub const OverlayPolicy = enum {
    /// Hit-tested; outside-press / ESC dismiss it. Menus, combobox popups.
    modal_popup,
    /// Non-interactive: skipped by hit-test and dismiss, painted only.
    /// Drag ghosts, (future) tooltips.
    passthrough,
};

/// One floating overlay. The component's `position` is window-local and its
/// `parent` is null; `absoluteOriginInWindow` includes that position so
/// window-local mouse coords hit-test correctly.
pub const OverlayEntry = struct {
    component:  *Component,
    /// Opaque owner (Menu / PopupMenu / a ghost component) for dismiss / remove.
    owner:      *anyopaque,
    /// Called when a modal overlay is dismissed (outside-press / ESC) so the
    /// owner can update its `open` state.
    on_dismiss: *const fn (*anyopaque) void,
    /// Input model. Default modal (the common popup case).
    policy:     OverlayPolicy = .modal_popup,
};

/// Registration order: bottom = first opened, top = most recent.
entries:          std.ArrayList(OverlayEntry),
allocator:        std.mem.Allocator,
/// Borrowed from the owning Window (set in `wire`, after the Window installs
/// its notify/controller). Used to wire modal overlays so their descendants'
/// repaint / requestFocus bubble to the Window, and (via `dirty_notify`) to
/// mark the Window dirty after a change. Held as the generic property types
/// (not `*Window`) so this manager does not depend on Window.
dirty_notify:     *Component.DirtyNotify,
focus_controller: *Component.FocusController,

pub fn init(allocator: std.mem.Allocator) OverlayManager {
    return .{
        .entries = .empty,
        .allocator = allocator,
        .dirty_notify = undefined, // set in wire()
        .focus_controller = undefined, // set in wire()
    };
}

pub fn deinit(self: *OverlayManager) void {
    // Entries are not owned (owners hold their components) — just drop the list.
    self.entries.deinit(self.allocator);
}

/// Connect the owning Window's dirty-notify and focus-controller. Call once
/// (from Window.install) before any add / remove.
pub fn wire(
    self: *OverlayManager,
    dirty_notify: *Component.DirtyNotify,
    focus_controller: *Component.FocusController,
) void {
    self.dirty_notify = dirty_notify;
    self.focus_controller = focus_controller;
}

fn markDirty(self: *OverlayManager) void {
    self.dirty_notify.paint(self.dirty_notify.user_data);
}

/// Register a modal popup overlay (hit-tested; outside-press / ESC dismiss it).
/// `component.parent` is set null and dirty-notify / focus-controller are wired
/// so its descendants reach the Window. `component.position` should already be
/// set (window-local). Usually called from Menu / PopupMenu / ComboBox `show`.
pub fn add(
    self: *OverlayManager,
    component: *Component,
    owner: *anyopaque,
    on_dismiss: *const fn (*anyopaque) void,
) !void {
    component.parent = null;
    try component.putProperty(@typeName(Component.DirtyNotify), @ptrCast(self.dirty_notify), null);
    try component.putProperty(@typeName(Component.FocusController), @ptrCast(self.focus_controller), null);
    try self.entries.append(self.allocator, .{
        .component = component,
        .owner = owner,
        .on_dismiss = on_dismiss,
    });
    self.markDirty();
}

/// Register a passthrough overlay (non-interactive: drag ghost / tooltip). No
/// owner / on_dismiss needed — remove with `remove(@ptrCast(component))`.
pub fn addPassthrough(self: *OverlayManager, component: *Component) !void {
    component.parent = null;
    try self.entries.append(self.allocator, .{
        .component = component,
        .owner = @ptrCast(component),
        .on_dismiss = noopDismiss,
        .policy = .passthrough,
    });
    self.markDirty();
}

fn noopDismiss(_: *anyopaque) void {}

/// Remove the overlay registered by `owner`. No-op if not found. Does NOT call
/// on_dismiss (caller is presumably the owner itself).
pub fn remove(self: *OverlayManager, owner: *anyopaque) void {
    var i: usize = 0;
    while (i < self.entries.items.len) : (i += 1) {
        if (self.entries.items[i].owner == owner) {
            _ = self.entries.orderedRemove(i);
            self.markDirty();
            return;
        }
    }
}

/// Dismiss every `modal_popup` overlay, top-down, calling each on_dismiss so
/// owners can update their `open` state. `passthrough` entries are left intact.
pub fn dismissAll(self: *OverlayManager) void {
    var i: usize = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        if (self.entries.items[i].policy != .modal_popup) continue;
        const e = self.entries.orderedRemove(i);
        e.on_dismiss(e.owner);
    }
    self.markDirty();
}

/// Index of the topmost `modal_popup` overlay, or null if none is open.
/// `passthrough` entries do not make the window modal.
pub fn topModalIndex(self: *const OverlayManager) ?usize {
    var i: usize = self.entries.items.len;
    while (i > 0) {
        i -= 1;
        if (self.entries.items[i].policy == .modal_popup) return i;
    }
    return null;
}

/// Paint all overlays (both policies) in registration order, on top of the
/// caller's content.
pub fn paintAll(self: *OverlayManager, g: *awt.Graphics) void {
    for (self.entries.items) |entry| entry.component.paintAt(g);
}
