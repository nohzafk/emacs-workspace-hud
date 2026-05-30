use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use wasm_bindgen::prelude::*;

lazy_static::lazy_static! {
    static ref GLOBAL_STATE: Mutex<HudState> = Mutex::new(HudState::default());
    static ref REPAINT_SIGNAL: Mutex<Option<egui::Context>> = Mutex::new(None);
    static ref GLOBAL_THEME: Mutex<ThemeColors> = Mutex::new(ThemeColors::default());
}

#[derive(Default, Serialize, Deserialize, Clone)]
pub struct UnitInfo {
    pub name: String,
    pub status: String,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct HudState {
    #[serde(default = "default_branch")]
    pub branch: String,
    #[serde(default)]
    pub upstream: String,
    #[serde(default)]
    pub changes: String,
    #[serde(rename = "mcp-online", default)]
    pub mcp_online: bool,
    #[serde(default)]
    pub units: Vec<UnitInfo>,
    #[serde(default)]
    pub location: String,
    #[serde(rename = "last-commit", default)]
    pub last_commit: String,
    #[serde(rename = "project-name", default)]
    pub project_name: String,
    #[serde(rename = "project-root", default)]
    pub project_root: String,
}

fn default_branch() -> String {
    "main".to_string()
}

impl Default for HudState {
    fn default() -> Self {
        Self {
            branch: "main".to_string(),
            upstream: String::new(),
            changes: "+0 -0".to_string(),
            mcp_online: false,
            units: Vec::new(),
            location: String::new(),
            last_commit: String::new(),
            project_name: String::new(),
            project_root: String::new(),
        }
    }
}

#[derive(Serialize, Deserialize, Clone)]
pub struct ThemeColors {
    #[serde(default)]
    pub bg: String,
    #[serde(default)]
    pub fg: String,
    #[serde(rename = "font-size", default)]
    pub font_size: Option<f32>,
    #[serde(rename = "surface-bg", default)]
    pub surface_bg: String,
}

impl Default for ThemeColors {
    fn default() -> Self {
        Self {
            bg: "#0c0c10".to_string(),
            fg: "#e6ebff".to_string(),
            font_size: None,
            surface_bg: String::new(),
        }
    }
}

fn parse_hex_color(hex: &str) -> Option<egui::Color32> {
    let hex = hex.trim_start_matches('#');
    if hex.len() >= 6 {
        let r = u8::from_str_radix(&hex[0..2], 16).ok()?;
        let g = u8::from_str_radix(&hex[2..4], 16).ok()?;
        let b = u8::from_str_radix(&hex[4..6], 16).ok()?;
        Some(egui::Color32::from_rgb(r, g, b))
    } else {
        None
    }
}

fn luminance(c: egui::Color32) -> u8 {
    ((c.r() as u32 * 299 + c.g() as u32 * 587 + c.b() as u32 * 114) / 1000) as u8
}

fn card_fill_from_bg(bg: egui::Color32) -> egui::Color32 {
    if luminance(bg) < 128 {
        // Dark theme: card slightly lighter
        egui::Color32::from_rgba_unmultiplied(
            bg.r().saturating_add(12),
            bg.g().saturating_add(12),
            bg.b().saturating_add(14),
            240,
        )
    } else {
        // Light theme: card is white-ish
        egui::Color32::from_rgba_unmultiplied(255, 255, 255, 245)
    }
}

fn muted_color(fg: egui::Color32) -> egui::Color32 {
    // Reduce opacity for muted text
    egui::Color32::from_rgba_unmultiplied(fg.r(), fg.g(), fg.b(), 118)
}

fn light_card_text() -> egui::Color32 {
    egui::Color32::from_rgb(54, 57, 64)
}

fn light_card_muted_text() -> egui::Color32 {
    egui::Color32::from_rgb(146, 149, 154)
}

#[derive(Clone, Copy)]
enum HudIcon {
    Changes,
    Branch,
    Commit,
    Source,
}

fn draw_icon(ui: &mut egui::Ui, icon: HudIcon, color: egui::Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(16.0, 16.0), egui::Sense::hover());
    let painter = ui.painter();
    let stroke = egui::Stroke::new(1.7, color);
    let thin = egui::Stroke::new(1.35, color);
    let c = rect.center();

    match icon {
        HudIcon::Changes => {
            let r = egui::Rect::from_center_size(c, egui::vec2(13.0, 13.0));
            painter.rect_stroke(r, 3.0, stroke, egui::StrokeKind::Middle);
            painter.line_segment(
                [egui::pos2(c.x - 3.8, c.y), egui::pos2(c.x + 3.8, c.y)],
                thin,
            );
            painter.line_segment(
                [egui::pos2(c.x, c.y - 3.8), egui::pos2(c.x, c.y + 3.8)],
                thin,
            );
        }
        HudIcon::Branch => {
            let left_top = egui::pos2(rect.left() + 5.0, rect.top() + 4.5);
            let left_bottom = egui::pos2(rect.left() + 5.0, rect.bottom() - 4.5);
            let right_mid = egui::pos2(rect.right() - 4.5, c.y);
            painter.line_segment([left_top, left_bottom], thin);
            painter.line_segment([left_top, right_mid], thin);
            painter.circle_stroke(left_top, 2.2, stroke);
            painter.circle_stroke(left_bottom, 2.2, stroke);
            painter.circle_stroke(right_mid, 2.2, stroke);
        }
        HudIcon::Commit => {
            painter.circle_stroke(c, 5.0, stroke);
            painter.circle_filled(c, 2.0, color);
        }
        HudIcon::Source => {
            let a = egui::pos2(rect.left() + 5.0, rect.top() + 5.0);
            let b = egui::pos2(rect.right() - 5.0, c.y);
            let d = egui::pos2(rect.left() + 5.0, rect.bottom() - 5.0);
            painter.line_segment([a, b], thin);
            painter.line_segment([d, b], thin);
            painter.circle_stroke(a, 2.5, stroke);
            painter.circle_stroke(b, 2.5, stroke);
            painter.circle_stroke(d, 2.5, stroke);
        }
    }
}

enum RowRight<'a> {
    Plain(&'a str, egui::Color32),
    Diff {
        added: &'a str,
        removed: &'a str,
        added_color: egui::Color32,
        removed_color: egui::Color32,
    },
}

fn split_diff_stat(value: &str) -> Option<(&str, &str)> {
    let mut parts = value.split_whitespace();
    let added = parts.next()?;
    let removed = parts.next()?;

    if parts.next().is_none() && added.starts_with('+') && removed.starts_with('-') {
        Some((added, removed))
    } else {
        None
    }
}

fn hud_row(
    ui: &mut egui::Ui,
    icon: HudIcon,
    label: &str,
    right: Option<RowRight<'_>>,
    primary: egui::Color32,
    muted: egui::Color32,
    text_size: f32,
    font_family: &egui::FontFamily,
) {
    ui.allocate_ui_with_layout(
        egui::vec2(ui.available_width(), 24.0),
        egui::Layout::left_to_right(egui::Align::Center),
        |ui| {
            draw_icon(ui, icon, muted);
            ui.add_space(6.0);
            ui.label(
                egui::RichText::new(label)
                    .family(font_family.clone())
                    .size(text_size)
                    .color(primary),
            );
            if let Some(right) = right {
                ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                    let right_size = (text_size - 0.4).max(10.0);
                    match right {
                        RowRight::Plain(value, color) => {
                            ui.label(
                                egui::RichText::new(value)
                                    .family(font_family.clone())
                                    .size(right_size)
                                    .color(color),
                            );
                        }
                        RowRight::Diff {
                            added,
                            removed,
                            added_color,
                            removed_color,
                        } => {
                            ui.label(
                                egui::RichText::new(removed)
                                    .family(font_family.clone())
                                    .size(right_size)
                                    .color(removed_color),
                            );
                            ui.add_space(5.0);
                            ui.label(
                                egui::RichText::new(added)
                                    .family(font_family.clone())
                                    .size(right_size)
                                    .color(added_color),
                            );
                        }
                    }
                });
            }
        },
    );
}

fn section_header(
    ui: &mut egui::Ui,
    title: &str,
    muted: egui::Color32,
    text_size: f32,
    font_family: &egui::FontFamily,
) {
    ui.allocate_ui_with_layout(
        egui::vec2(ui.available_width(), 22.0),
        egui::Layout::left_to_right(egui::Align::Center),
        |ui| {
            ui.label(
                egui::RichText::new(title)
                    .family(font_family.clone())
                    .size(text_size)
                    .color(muted),
            );
        },
    );
}

fn soft_separator(ui: &mut egui::Ui, color: egui::Color32) {
    let y = ui.cursor().top() + 4.0;
    let x = ui.available_rect_before_wrap().x_range();
    ui.painter().hline(x, y, egui::Stroke::new(1.0, color));
    ui.add_space(9.0);
}

pub struct HudApp {}

impl HudApp {
    pub fn new(_cc: &eframe::CreationContext<'_>) -> Self {
        Self {}
    }
}

impl eframe::App for HudApp {
    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        egui::Color32::TRANSPARENT.to_normalized_gamma_f32()
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        // Store context for programmatic repaints when state is pushed
        if let Ok(mut signal) = (*REPAINT_SIGNAL).lock() {
            if signal.is_none() {
                *signal = Some(ctx.clone());
            }
        }

        let state = {
            if let Ok(guard) = (*GLOBAL_STATE).lock() {
                guard.clone()
            } else {
                HudState::default()
            }
        };

        let theme = {
            if let Ok(guard) = (*GLOBAL_THEME).lock() {
                guard.clone()
            } else {
                ThemeColors::default()
            }
        };

        let bg = parse_hex_color(&theme.bg).unwrap_or(egui::Color32::from_rgb(12, 12, 16));
        let fg = parse_hex_color(&theme.fg).unwrap_or(egui::Color32::from_rgb(230, 235, 255));
        let is_dark = luminance(bg) < 128;
        let text_size = theme
            .font_size
            .map(|font_size| font_size * 0.76)
            .unwrap_or(12.0)
            .clamp(10.2, 12.0);
        let font_family = egui::FontFamily::Monospace;

        let col_text_primary = if is_dark {
            egui::Color32::from_rgba_unmultiplied(fg.r(), fg.g(), fg.b(), 218)
        } else {
            light_card_text()
        };
        let col_text_muted = if is_dark {
            muted_color(fg)
        } else {
            light_card_muted_text()
        };
        let col_green = egui::Color32::from_rgb(85, 166, 99);
        let col_orange = egui::Color32::from_rgb(202, 120, 76);
        let col_red = egui::Color32::from_rgb(198, 88, 94);
        let card_bg = parse_hex_color(&theme.surface_bg).unwrap_or_else(|| card_fill_from_bg(bg));
        let separator_color = if is_dark {
            egui::Color32::from_rgba_unmultiplied(fg.r(), fg.g(), fg.b(), 28)
        } else {
            egui::Color32::from_rgba_unmultiplied(30, 34, 40, 22)
        };
        // Keep egui itself transparent. xwidget-webkit still supplies an
        // opaque native backing view on some builds, so the card must fill
        // the whole web surface instead of relying on transparent gutters.
        let mut style = (*ctx.style()).clone();
        style.visuals.widgets.noninteractive.bg_fill = egui::Color32::TRANSPARENT;
        style.visuals.window_fill = egui::Color32::TRANSPARENT;
        style.visuals.panel_fill = egui::Color32::TRANSPARENT;
        ctx.set_style(style);

        egui::CentralPanel::default()
            .frame(
                egui::Frame::new()
                    .fill(card_bg)
                    .corner_radius(egui::CornerRadius::ZERO)
                    .inner_margin(egui::Margin {
                        left: 12,
                        right: 12,
                        top: 14,
                        bottom: 14,
                    })
                    .stroke(egui::Stroke::NONE),
            )
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing = egui::vec2(0.0, 0.0);

                section_header(ui, "Environment", col_text_muted, text_size, &font_family);
                soft_separator(ui, separator_color);

                let has_changes = !state.changes.is_empty()
                    && state.changes != "0 files"
                    && state.changes != "+0 -0";
                let changes_display = if state.changes.is_empty() {
                    "0 files".to_string()
                } else {
                    state.changes.clone()
                };
                let changes_color = if has_changes {
                    col_orange
                } else {
                    col_text_muted
                };
                let changes_right =
                    if let Some((added, removed)) = split_diff_stat(&changes_display) {
                        Some(RowRight::Diff {
                            added,
                            removed,
                            added_color: if added == "+0" {
                                col_text_muted
                            } else {
                                col_green
                            },
                            removed_color: if removed == "-0" {
                                col_text_muted
                            } else {
                                col_red
                            },
                        })
                    } else {
                        Some(RowRight::Plain(&changes_display, changes_color))
                    };
                hud_row(
                    ui,
                    HudIcon::Changes,
                    "Changes",
                    changes_right,
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                hud_row(
                    ui,
                    HudIcon::Branch,
                    &state.branch,
                    if state.upstream.is_empty() {
                        None
                    } else {
                        Some(RowRight::Plain(&state.upstream, col_text_primary))
                    },
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                let commit_display = if state.last_commit.is_empty() {
                    "no commits".to_string()
                } else {
                    state.last_commit.clone()
                };
                hud_row(
                    ui,
                    HudIcon::Commit,
                    &commit_display,
                    None,
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                ui.add_space(7.0);
                soft_separator(ui, separator_color);
                section_header(ui, "Sources", col_text_muted, text_size, &font_family);

                // Config units (if any)
                let source_status = if state.mcp_online {
                    Some(("Online", col_green))
                } else {
                    Some(("Offline", col_red))
                };
                hud_row(
                    ui,
                    HudIcon::Source,
                    "Elle MCP",
                    source_status.map(|(value, color)| RowRight::Plain(value, color)),
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );
                if !state.units.is_empty() {
                    for unit in &state.units {
                        let (color, label) = match unit.status.as_str() {
                            "running" => (col_green, "running"),
                            "failed" => (col_red, "failed"),
                            s => (col_text_muted, s),
                        };
                        hud_row(
                            ui,
                            HudIcon::Source,
                            &unit.name,
                            Some(RowRight::Plain(label, color)),
                            col_text_primary,
                            col_text_muted,
                            text_size,
                            &font_family,
                        );
                    }
                }
            });
    }
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn start(_canvas_id: &str) -> Result<(), JsValue> {
    // Redirect panics to browser console
    console_error_panic_hook::set_once();

    let web_options = eframe::WebOptions::default();
    wasm_bindgen_futures::spawn_local(async {
        let document = web_sys::window()
            .and_then(|win| win.document())
            .expect("Failed to get document");
        let canvas = document
            .get_element_by_id("hud-canvas")
            .expect("Failed to get canvas")
            .dyn_into::<web_sys::HtmlCanvasElement>()
            .expect("Failed to cast to canvas");

        eframe::WebRunner::new()
            .start(
                canvas,
                web_options,
                Box::new(|cc| Ok(Box::new(HudApp::new(cc)))),
            )
            .await
            .expect("failed to start eframe");
    });

    Ok(())
}

/// Fix type mismatches caused by the Emacs Lisp → JSON encoding layer.
/// Elle boolean `false` arrives as JSON string `"false"` instead of JSON boolean.
/// Elle empty list `()` arrives as JSON `null` instead of JSON array `[]`.
fn fixup_sexp_rpc_json(val: &mut serde_json::Value) {
    if let serde_json::Value::Object(map) = val {
        // Fix boolean fields that arrive as strings from Emacs json-encode
        for key in ["mcp-online"] {
            if let Some(v) = map.get(key).cloned() {
                if let Some(s) = v.as_str() {
                    match s {
                        "true" => {
                            map.insert(key.to_string(), serde_json::Value::Bool(true));
                        }
                        "false" => {
                            map.insert(key.to_string(), serde_json::Value::Bool(false));
                        }
                        _ => {}
                    }
                }
            }
        }
        // Fix array fields that arrive as null (Emacs nil for empty list)
        for key in ["units"] {
            if matches!(map.get(key), Some(serde_json::Value::Null)) {
                map.insert(key.to_string(), serde_json::Value::Array(vec![]));
            }
        }
        // Recurse into array elements (e.g. unit items)
        for (_, v) in map.iter_mut() {
            if let serde_json::Value::Array(arr) = v {
                for item in arr.iter_mut() {
                    fixup_sexp_rpc_json(item);
                }
            }
        }
    }
}

#[wasm_bindgen]
pub fn push_state(json: &str) {
    if let Ok(mut val) = serde_json::from_str::<serde_json::Value>(json) {
        fixup_sexp_rpc_json(&mut val);
        if let Ok(new_state) = serde_json::from_value::<HudState>(val) {
            if let Ok(mut guard) = (*GLOBAL_STATE).lock() {
                *guard = new_state;
            }
            // Trigger repaint immediately
            if let Ok(signal) = (*REPAINT_SIGNAL).lock() {
                if let Some(ctx) = &*signal {
                    ctx.request_repaint();
                }
            }
        }
    }
}

#[wasm_bindgen]
pub fn push_theme(json: &str) {
    if let Ok(new_theme) = serde_json::from_str::<ThemeColors>(json) {
        if let Ok(mut guard) = (*GLOBAL_THEME).lock() {
            *guard = new_theme;
        }
        if let Ok(signal) = (*REPAINT_SIGNAL).lock() {
            if let Some(ctx) = &*signal {
                ctx.request_repaint();
            }
        }
    }
}
