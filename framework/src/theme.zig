//! Color catalog consulted by the default look-and-feel. See
//! `framework/doc/theme.md` (spec) and `framework/doc/narrative/theme.md`
//! (design rationale / rejected alternatives).
//!
//! A public fixed struct — NOT a string-keyed map (UIManager) and NOT a UI
//! delegate system (ComponentUI): a LAF in nimbus is a vtable swap, and Theme
//! is merely the parameter table of the built-in look. Custom-paint LAFs may
//! read `component.theme` (to follow the app's theme) or ignore it entirely.
//!
//! The theme is fixed at startup (`Application.initWithTheme`); there is no
//! runtime switching — metrics are baked into min_size at creation, so a live
//! swap would need a whole-tree re-metrics protocol (the very thing that made
//! runtime LAF switching fragile in Swing).

const awt = @import("awt");

const Color = awt.Graphics.Color;

pub const Theme = struct {
    // ── Role tokens (cross-widget; the surface theme authors mostly touch) ──
    accent: Color = Color.rgb(0.30, 0.55, 0.95), // selection / checked / focus border / slider thumb
    accent_soft: Color = Color.rgb(0.90, 0.93, 0.99), // menu hover background
    selection_bg: Color = Color.rgb(0.80, 0.87, 0.98), // List selected row
    focus_ring: Color = Color.rgb(0.25, 0.45, 0.85), // keyboard focus ring
    text: Color = Color.rgb(0.10, 0.10, 0.10),
    text_disabled: Color = Color.rgb(0.55, 0.55, 0.55),
    text_on_accent: Color = Color.rgb(1.00, 1.00, 1.00), // selected-menu text / check glyphs
    surface_window: Color = Color.rgb(0.94, 0.94, 0.94), // window / menu bar / panel background
    surface_input: Color = Color.rgb(1.00, 1.00, 1.00), // TextField / List / popup / ComboBox background
    surface_disabled: Color = Color.rgb(0.93, 0.93, 0.93),
    border: Color = Color.rgb(0.55, 0.55, 0.55), // input-field / popup frames
    border_soft: Color = Color.rgb(0.78, 0.78, 0.82), // weak frames (menu bar underline etc.)
    separator: Color = Color.rgb(0.75, 0.75, 0.78),
    indicator_border: Color = Color.rgb(0.50, 0.50, 0.50), // CheckBox square / RadioButton circle frame

    // ── Per-widget values (folding these into roles would change meaning) ──
    button_bg: Color = Color.rgb(0.85, 0.85, 0.90),
    button_bg_hover: Color = Color.rgb(0.92, 0.92, 0.97),
    button_bg_armed: Color = Color.rgb(0.55, 0.65, 0.85), // deliberately paler than accent
    button_bg_disabled: Color = Color.rgb(0.75, 0.75, 0.78),
    button_flat_hover: Color = Color.rgb(0.88, 0.88, 0.92),
    button_flat_armed: Color = Color.rgb(0.78, 0.82, 0.92),
    scrollbar_track: Color = Color.rgb(0.88, 0.88, 0.90),
    scrollbar_thumb: Color = Color.rgb(0.62, 0.62, 0.66),
    scrollbar_thumb_hover: Color = Color.rgb(0.48, 0.48, 0.52),
    slider_track: Color = Color.rgb(0.70, 0.70, 0.75),
    ime_preedit_underline: Color = Color.rgb(0.40, 0.40, 0.40), // shared by TextField / TextArea
    ime_preedit_target: Color = Color.rgb(0.20, 0.20, 0.20),

    /// The built-in default theme — exactly the field defaults above. Comptime
    /// constant (immutable data, not a mutable global): components created
    /// outside an Application factory point here and stay valid forever.
    pub const default = Theme{};

    /// Built-in dark preset, defined as a diff over the defaults. `accent`
    /// and `text_on_accent` are untouched on purpose: the default blue reads
    /// fine on dark surfaces, and it doubles as a demonstration that presets
    /// are diff-definitions like any user theme.
    pub const dark = Theme{
        .accent_soft = Color.rgb(0.22, 0.28, 0.40),
        .selection_bg = Color.rgb(0.20, 0.30, 0.45),
        .focus_ring = Color.rgb(0.40, 0.60, 0.95), // brighter: must stay visible on dark
        .text = Color.rgb(0.92, 0.92, 0.92),
        .text_disabled = Color.rgb(0.50, 0.50, 0.50),
        .surface_window = Color.rgb(0.13, 0.13, 0.14),
        .surface_input = Color.rgb(0.18, 0.18, 0.20),
        .surface_disabled = Color.rgb(0.16, 0.16, 0.17),
        .border = Color.rgb(0.35, 0.35, 0.38),
        .border_soft = Color.rgb(0.28, 0.28, 0.32),
        .separator = Color.rgb(0.30, 0.30, 0.33),
        .indicator_border = Color.rgb(0.45, 0.45, 0.48),

        .button_bg = Color.rgb(0.25, 0.25, 0.28),
        .button_bg_hover = Color.rgb(0.32, 0.32, 0.36),
        .button_bg_armed = Color.rgb(0.30, 0.40, 0.60),
        .button_bg_disabled = Color.rgb(0.20, 0.20, 0.22),
        .button_flat_hover = Color.rgb(0.22, 0.22, 0.26),
        .button_flat_armed = Color.rgb(0.26, 0.30, 0.40),
        .scrollbar_track = Color.rgb(0.18, 0.18, 0.20),
        .scrollbar_thumb = Color.rgb(0.40, 0.40, 0.44),
        .scrollbar_thumb_hover = Color.rgb(0.55, 0.55, 0.60),
        .slider_track = Color.rgb(0.35, 0.35, 0.40),
        .ime_preedit_underline = Color.rgb(0.65, 0.65, 0.65),
        .ime_preedit_target = Color.rgb(0.85, 0.85, 0.85),
    };
};
