//! Top-level application object. See `framework/doc/application.md`.

const std = @import("std");
const awt = @import("awt");
const Component = @import("Component.zig");
const Container = @import("Container.zig");
const Label = @import("Label.zig");
const Panel = @import("Panel.zig");
const Button = @import("Button.zig");
const Slider = @import("Slider.zig");
const Frame = @import("Frame.zig");
const Window = @import("Window.zig");

const Application = @This();

const WindowEntry = struct {
    window:  *Window,
    /// Free the outer widget (Frame, Dialog 等) that contains the Window.
    /// Called when the window closes or Application.deinit runs.
    outer:   *anyopaque,
    destroy: *const fn (*anyopaque, std.mem.Allocator) void,
};

allocator:    std.mem.Allocator,
device:       awt.Device,
context:      awt.Graphics.Context,
default_font: awt.Font,
event_queue:  *awt.EventQueue,
windows:      std.ArrayList(WindowEntry),

// Owned program / buffer objects (Graphics.Context holds pointers to these).
_color_program: awt.programs.Color,
_image_program: awt.programs.Image,
_rrect_program: awt.programs.RoundedRect,
_text_program:  awt.programs.Text,
_vertex_ring:   awt.VertexRing,
_uniforms:      awt.UniformBuffer,
_quad_index:    awt.QuadIndexBuffer,
_atlas:         awt.GlyphAtlas,

/// Initialize the application. `font_data` is the byte slice for the default
/// font (e.g., `@embedFile("...ttf")`). The data must outlive the
/// Application.
pub fn init(allocator: std.mem.Allocator, font_data: []const u8) !*Application {
    const app = try allocator.create(Application);
    errdefer allocator.destroy(app);

    try awt.init();
    errdefer awt.deinit();

    app.allocator = allocator;
    app.windows = .empty;

    app.device = try awt.Device.init();
    errdefer app.device.deinit();

    app._color_program = try awt.programs.Color.init(app.device);
    errdefer app._color_program.deinit();
    app._image_program = try awt.programs.Image.init(app.device);
    errdefer app._image_program.deinit();
    app._rrect_program = try awt.programs.RoundedRect.init(app.device);
    errdefer app._rrect_program.deinit();
    app._text_program = try awt.programs.Text.init(app.device);
    errdefer app._text_program.deinit();

    app._vertex_ring = try awt.VertexRing.init(app.device, 256 * 1024);
    errdefer app._vertex_ring.deinit();
    app._uniforms = try awt.UniformBuffer.init(app.device, 64 * 1024);
    errdefer app._uniforms.deinit();
    app._quad_index = try awt.QuadIndexBuffer.init(allocator, app.device, 1024);
    errdefer app._quad_index.deinit();
    app._atlas = try awt.GlyphAtlas.init(allocator, app.device, 2048);
    errdefer app._atlas.deinit();

    app.context = .{
        .vertex_ring   = &app._vertex_ring,
        .uniforms      = &app._uniforms,
        .quad_index    = &app._quad_index,
        .atlas         = &app._atlas,
        .color_program = &app._color_program,
        .image_program = &app._image_program,
        .rrect_program = &app._rrect_program,
        .text_program  = &app._text_program,
    };

    app.default_font = try awt.Font.init(font_data, 0);
    errdefer app.default_font.deinit();

    app.event_queue = try awt.EventQueue.init(allocator);
    errdefer app.event_queue.deinit();
    app.event_queue.setUiThread(std.Thread.getCurrentId());

    return app;
}

pub fn deinit(self: *Application) void {
    for (self.windows.items) |entry| {
        entry.destroy(entry.outer, self.allocator);
    }
    self.windows.deinit(self.allocator);

    self.event_queue.deinit();
    self.default_font.deinit();
    self._atlas.deinit();
    self._quad_index.deinit();
    self._uniforms.deinit();
    self._vertex_ring.deinit();
    self._text_program.deinit();
    self._rrect_program.deinit();
    self._image_program.deinit();
    self._color_program.deinit();
    self.device.deinit();
    awt.deinit();

    self.allocator.destroy(self);
}

pub fn getEventQueue(self: *Application) *awt.EventQueue {
    return self.event_queue;
}

/// Run the main event loop. Returns when all windows have been closed.
pub fn run(self: *Application) !void {
    while (self.windows.items.len > 0) {
        awt.waitEvents();
        self.event_queue.drain();

        // Render dirty windows.
        for (self.windows.items) |entry| {
            if (entry.window.paint_dirty or entry.window.layout_dirty) {
                entry.window.redraw();
            }
        }

        // Collect closed windows.
        var i: usize = 0;
        while (i < self.windows.items.len) {
            const entry = self.windows.items[i];
            if (entry.window.shouldClose()) {
                _ = self.windows.orderedRemove(i);
                entry.destroy(entry.outer, self.allocator);
            } else {
                i += 1;
            }
        }
    }
}

// ── factories ────────────────────────────────────────────────────────────

pub fn frame(self: *Application, title: []const u8, w: u32, h: u32) !*Frame {
    const f = try self.allocator.create(Frame);
    errdefer self.allocator.destroy(f);
    f.* = try Frame.init(self.allocator, @ptrCast(self), title, w, h, &self.device, &self.context);

    // The Window vtable's install() does container linkup + OS callback wiring.
    Window.vtable.install(&f.window.container.component);

    const dtor = struct {
        fn destroy(p: *anyopaque, a: std.mem.Allocator) void {
            const frm: *Frame = @ptrCast(@alignCast(p));
            frm.deinit();
            a.destroy(frm);
        }
    }.destroy;

    try self.windows.append(self.allocator, .{
        .window  = &f.window,
        .outer   = @ptrCast(f),
        .destroy = dtor,
    });

    return f;
}

pub fn label(self: *Application, text: []const u8) !*Label {
    return try Label.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        awt.Graphics.Color.rgb(0, 0, 0),
    );
}

pub fn container(self: *Application) !*Container {
    return try Container.create(self.allocator);
}

pub fn panel(self: *Application) !*Panel {
    return try Panel.create(self.allocator);
}

pub fn button(self: *Application, text: []const u8) !*Button {
    return try Button.create(
        self.allocator,
        text,
        .{ .face = self.default_font, .pixel_size = 14 },
        awt.Graphics.Color.rgb(0, 0, 0),
    );
}

pub fn slider(
    self: *Application,
    orientation: Slider.Orientation,
    min: i32,
    value: i32,
    max: i32,
) !*Slider {
    return try Slider.create(self.allocator, orientation, min, value, max);
}

pub fn filler(self: *Application) !*Panel {
    const p = try self.panel();
    p.container.component.setGrowX(1);
    p.container.component.setGrowY(1);
    return p;
}
