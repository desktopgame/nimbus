//! Widget showcase example. Collects the main framework widgets in one window.
//!
//! Usage:
//!     zig build run-widget_showcase

const std = @import("std");
const nimbus = @import("nimbus");

const Laf = enum { flatlaf, metal };
const LAF: Laf = .flatlaf;

const TableRow = struct {
    name: []const u8,
    kind: []const u8,
    status: []const u8,
};

const CellFactoryCtx = struct {
    app: *nimbus.Application,
};

const TextCell = struct {
    label: *nimbus.Label,

    fn createList(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.List.Cell {
        const ctx: *CellFactoryCtx = @ptrCast(@alignCast(ud));
        const self = try allocator.create(TextCell);
        errdefer allocator.destroy(self);
        self.* = .{ .label = try ctx.app.label("") };
        self.label.component.setMinSize(.{ .width = 0, .height = 24 });
        return .{
            .component = &self.label.component,
            .update = updateList,
            .destroy = destroyCell,
            .user_data = self,
        };
    }

    fn updateList(ud: *anyopaque, ctx: nimbus.List.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(ud));
        const text: *[]const u8 = @ptrCast(@alignCast(ctx.value));
        self.label.setText(text.*) catch {};
    }

    fn createTable(ud: *anyopaque, allocator: std.mem.Allocator) anyerror!nimbus.Table.Cell {
        const ctx: *CellFactoryCtx = @ptrCast(@alignCast(ud));
        const self = try allocator.create(TextCell);
        errdefer allocator.destroy(self);
        self.* = .{ .label = try ctx.app.label("") };
        self.label.component.setMinSize(.{ .width = 0, .height = 22 });
        return .{
            .component = &self.label.component,
            .update = updateTable,
            .destroy = destroyCell,
            .user_data = self,
        };
    }

    fn updateTable(ud: *anyopaque, ctx: nimbus.Table.CellContext) void {
        const self: *TextCell = @ptrCast(@alignCast(ud));
        const row: *TableRow = @ptrCast(@alignCast(ctx.value));
        const text = switch (ctx.col) {
            0 => row.name,
            1 => row.kind,
            else => row.status,
        };
        self.label.setText(text) catch {};
    }

    fn destroyCell(ud: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *TextCell = @ptrCast(@alignCast(ud));
        self.label.component.vtable.destroy(&self.label.component, allocator);
        allocator.destroy(self);
    }
};

fn page(app: *nimbus.Application) !*nimbus.Panel {
    const root = try app.panel();
    root.setPadding(nimbus.Insets.all(12));
    root.asComponent().setGrowX(1);
    root.asComponent().setGrowY(1);
    root.asContainer().setLayout(try nimbus.BoxLayout.verticalSpaced(app.allocator, 10));
    return root;
}

fn addFormCell(app: *nimbus.Application, grid: *nimbus.Container, label_text: []const u8, input: *nimbus.Component) !void {
    const label = try app.label(label_text);
    label.component.setAlignY(.center);

    input.setGrowX(1);
    input.setAlignY(.center);

    try grid.add(&label.component);
    try grid.add(input);
}

fn groupPanel(app: *nimbus.Application, title: []const u8) !*nimbus.Panel {
    const p = try app.panel();
    p.setBorder(.{ .thickness = 1, .color = app.theme.separator });
    p.setPadding(nimbus.Insets.all(8));
    p.asContainer().setLayout(try nimbus.BoxLayout.verticalSpaced(app.allocator, 6));

    const label = try app.label(title);
    try p.asContainer().add(&label.component);
    return p;
}

fn buildMenu(app: *nimbus.Application, frame: *nimbus.Frame) !*nimbus.ButtonGroup {
    const bar = try app.menuBar();

    const file = try app.menu("File");
    try file.add(&(try app.menuItem("New")).component);
    try file.add(&(try app.menuItem("Open")).component);
    try file.add(&(try app.menuItem("Save")).component);
    try file.addSeparator();
    try file.add(&(try app.menuItem("Exit")).component);
    try bar.add(file);

    const edit = try app.menu("Edit");
    try edit.add(&(try app.menuItem("Cut")).component);
    try edit.add(&(try app.menuItem("Copy")).component);
    try edit.add(&(try app.menuItem("Paste")).component);
    try edit.addSeparator();
    const snap = try app.checkBoxMenuItem("Snap to Grid");
    snap.setChecked(true);
    try edit.add(&snap.component);
    try bar.add(edit);

    const help = try app.menu("Help");
    const basic = try app.radioButtonMenuItem("Basic Help");
    const advanced = try app.radioButtonMenuItem("Advanced Help");
    basic.setSelected(true);
    const help_group = try app.buttonGroup();
    errdefer help_group.destroy();
    try help_group.add(basic.getModel());
    try help_group.add(advanced.getModel());
    try help.add(&basic.component);
    try help.add(&advanced.component);
    try help.addSeparator();
    try help.add(&(try app.menuItem("About")).component);
    try bar.add(help);

    try frame.setMenuBar(bar);
    return help_group;
}

fn buildFormTab(app: *nimbus.Application) !*nimbus.Panel {
    const root = try page(app);

    const form = try app.container();
    form.setLayout(try nimbus.GridLayout.create(app.allocator, 2, .{ .col_spacing = 8, .row_spacing = 8 }));

    const salutations = [_][]const u8{ "Mr.", "Ms.", "Dr.", "Prof." };
    try addFormCell(app, form, "Salutation", &(try app.comboBox(&salutations)).component);
    try addFormCell(app, form, "First Name", &(try app.textField("Jane")).component);
    try addFormCell(app, form, "Last Name", &(try app.textField("Nimbus")).component);
    try addFormCell(app, form, "Company", &(try app.textField("Example Labs")).component);
    try addFormCell(app, form, "Email", &(try app.textField("jane@example.test")).component);

    try root.asContainer().add(&form.component);

    return root;
}

fn buildButtonsTab(app: *nimbus.Application) !struct { panel: *nimbus.Panel, group: *nimbus.ButtonGroup } {
    const root = try page(app);

    const buttons = try app.container();
    buttons.setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 8));
    const ok = try app.button("OK");
    const cancel = try app.button("Cancel");
    const disabled = try app.button("Disabled");
    disabled.getModel().setEnabled(false);
    try buttons.add(&ok.component);
    try buttons.add(&cancel.component);
    try buttons.add(&disabled.component);
    try root.asContainer().add(&buttons.component);

    const groups = try app.container();
    groups.setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 12));

    const colors = try groupPanel(app, "favorite color");
    const red = try app.radioButton("Red");
    const green = try app.radioButton("Green");
    const blue = try app.radioButton("Blue");
    green.setSelected(true);
    const color_group = try app.buttonGroup();
    errdefer color_group.destroy();
    try color_group.add(red.getModel());
    try color_group.add(green.getModel());
    try color_group.add(blue.getModel());
    try colors.asContainer().add(&red.component);
    try colors.asContainer().add(&green.component);
    try colors.asContainer().add(&blue.component);

    const foods = try groupPanel(app, "favorite food");
    const rice = try app.checkBox("Rice");
    const noodles = try app.checkBox("Noodles");
    const curry = try app.checkBox("Curry");
    noodles.setSelected(true);
    try foods.asContainer().add(&rice.component);
    try foods.asContainer().add(&noodles.component);
    try foods.asContainer().add(&curry.component);

    colors.asComponent().setGrowX(1);
    foods.asComponent().setGrowX(1);
    try groups.add(colors.asComponent());
    try groups.add(foods.asComponent());
    try root.asContainer().add(&groups.component);

    return .{ .panel = root, .group = color_group };
}

fn buildTextTab(app: *nimbus.Application) !*nimbus.Panel {
    const root = try page(app);

    const field = try app.textField("single line input");
    field.component.setGrowX(1);
    try root.asContainer().add(&field.component);

    const area = try app.textArea(
        \\The TextArea supports multiple lines.
        \\
        \\This tab keeps the control inside a ScrollPane so long text can be inspected.
    );
    const sp = try app.scrollPane(&area.component);
    sp.asComponent().setGrowX(1);
    sp.asComponent().setGrowY(1);
    try root.asContainer().add(sp.asComponent());

    const plain_area = try app.textArea(
        \\Plain TextArea without ScrollPane.
        \\Border decorator keeps this framed.
    );
    plain_area.component.setGrowX(1);
    plain_area.component.setMinSize(.{ .width = 0, .height = 52 });
    const framed_plain = try app.border(&plain_area.component);
    framed_plain.asComponent().setGrowX(1);
    try root.asContainer().add(framed_plain.asComponent());

    return root;
}

fn buildSliderTab(app: *nimbus.Application) !*nimbus.Panel {
    const root = try page(app);

    const horizontal = try app.slider(.horizontal, 0, 35, 100);
    horizontal.component.setGrowX(1);
    try root.asContainer().add(&(try app.label("Horizontal")).component);
    try root.asContainer().add(&horizontal.component);

    const row = try app.container();
    row.setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 12));
    const vertical_label = try app.label("Vertical");
    vertical_label.component.setAlignY(.center);
    const vertical = try app.slider(.vertical, 0, 60, 100);
    vertical.component.setMinSize(.{ .width = vertical.component.getMinSize().width, .height = 180 });
    try row.add(&vertical_label.component);
    try row.add(&vertical.component);
    try root.asContainer().add(&row.component);

    return root;
}

fn buildListsTab(
    app: *nimbus.Application,
    factory_ctx: *CellFactoryCtx,
    list_items: [][]const u8,
    table_rows: []TableRow,
) !*nimbus.Panel {
    const root = try page(app);
    root.asContainer().setLayout(try nimbus.BoxLayout.horizontalSpaced(app.allocator, 12));

    const list = try app.list(.{ .create = TextCell.createList, .user_data = factory_ctx });
    list.setRowHeight(28);
    for (list_items) |*item| try list.model.add(@ptrCast(item));
    list.setSelected(1);
    const list_sp = try app.scrollPane(list.asComponent());
    list_sp.asComponent().setGrowX(1);
    list_sp.asComponent().setGrowY(1);

    const table = try app.table(&.{
        .{ .title = "Name", .width = 140, .factory = .{ .create = TextCell.createTable, .user_data = factory_ctx } },
        .{ .title = "Kind", .width = 100, .factory = .{ .create = TextCell.createTable, .user_data = factory_ctx } },
        .{ .title = "Status", .width = 110, .factory = .{ .create = TextCell.createTable, .user_data = factory_ctx } },
    });
    table.setRowHeight(28);
    table.setSelected(2);
    table.setSortIndicator(0, .ascending);
    for (table_rows) |*row| try table.model.add(@ptrCast(row));
    const table_sp = try app.scrollPane(table.asComponent());
    try table_sp.setColumnHeaderView(try table.headerView());
    table_sp.asComponent().setGrowX(2);
    table_sp.asComponent().setGrowY(1);

    try root.asContainer().add(list_sp.asComponent());
    try root.asContainer().add(table_sp.asComponent());

    return root;
}

fn buildSplitTab(app: *nimbus.Application) !*nimbus.Panel {
    const root = try page(app);

    const left = try app.panel();
    left.setBorder(.{ .thickness = 1, .color = app.theme.separator });
    left.setPadding(nimbus.Insets.all(12));
    left.asContainer().setLayout(nimbus.BoxLayout.vertical());
    try left.asContainer().add(&(try app.label("Left Pane")).component);
    try left.asContainer().add(&(try app.label("Navigation or tree content")).component);

    const right = try app.panel();
    right.setBorder(.{ .thickness = 1, .color = app.theme.separator });
    right.setPadding(nimbus.Insets.all(12));
    right.asContainer().setLayout(nimbus.BoxLayout.vertical());
    try right.asContainer().add(&(try app.label("Right Pane")).component);
    try right.asContainer().add(&(try app.label("Details and editor area")).component);

    const split = try app.splitPane(.horizontal, left.asComponent(), right.asComponent());
    split.setDividerLocation(220);
    split.setResizeWeight(0.25);
    split.asComponent().setGrowX(1);
    split.asComponent().setGrowY(1);
    try root.asContainer().add(split.asComponent());

    return root;
}

pub fn main(init: std.process.Init) !void {
    const app = try nimbus.Application.init(init.gpa, init.io);
    defer app.deinit();

    const frame = try app.frame("widget_showcase", 820, 560);

    const help_menu_group = try buildMenu(app, frame);
    defer help_menu_group.destroy();

    const tabs = try app.tabbedPane();
    tabs.asComponent().setGrowX(1);
    tabs.asComponent().setGrowY(1);

    try tabs.addTab("Form", &(try buildFormTab(app)).container.component);

    const buttons = try buildButtonsTab(app);
    defer buttons.group.destroy();
    try tabs.addTab("Buttons", &buttons.panel.container.component);

    try tabs.addTab("Text", &(try buildTextTab(app)).container.component);
    try tabs.addTab("Slider", &(try buildSliderTab(app)).container.component);

    var factory_ctx = CellFactoryCtx{ .app = app };
    var list_items = [_][]const u8{
        "Alpha",
        "Beta",
        "Gamma",
        "Delta",
        "Epsilon",
        "Zeta",
        "Eta",
        "Theta",
    };
    var table_rows = [_]TableRow{
        .{ .name = "Button", .kind = "control", .status = "ready" },
        .{ .name = "ComboBox", .kind = "chooser", .status = "ready" },
        .{ .name = "List", .kind = "data", .status = "selected" },
        .{ .name = "Table", .kind = "data", .status = "sorted" },
        .{ .name = "TextArea", .kind = "input", .status = "editing" },
    };
    try tabs.addTab("Lists", &(try buildListsTab(app, &factory_ctx, &list_items, &table_rows)).container.component);
    try tabs.addTab("Split", &(try buildSplitTab(app)).container.component);

    try nimbus.BorderLayout.add(&frame.window.container, .center, tabs.asComponent());

    switch (LAF) {
        .flatlaf => {},
        .metal => nimbus.laf.applyLook(&frame.window.container.component, nimbus.laf.metal.metalTable()),
    }

    std.debug.print("Widget showcase. Close the window to exit.\n", .{});
    try app.run();
}
