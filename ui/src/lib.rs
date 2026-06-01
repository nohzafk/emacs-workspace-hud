use emacs_egui_sdk::eframe;
use emacs_egui_sdk::egui;
use emacs_egui_sdk::{parse_hex_color, EguiEmacsApp, ThemeColors};
use serde::{Deserialize, Serialize};
use wasm_bindgen::prelude::*;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HudState {
    #[serde(default = "default_branch")]
    pub branch: String,
    #[serde(default)]
    pub upstream: String,
    #[serde(default)]
    pub changes: String,
    #[serde(default)]
    pub location: String,
    #[serde(rename = "last-commit", default)]
    pub last_commit: String,
    #[serde(rename = "project-name", default)]
    pub project_name: String,
    #[serde(rename = "project-root", default)]
    pub project_root: String,
    #[serde(rename = "lsp-status", default = "default_lsp_status")]
    pub lsp_status: String,
    #[serde(rename = "diagnostic-errors", default)]
    pub diagnostic_errors: u32,
    #[serde(rename = "diagnostic-warnings", default)]
    pub diagnostic_warnings: u32,
    #[serde(rename = "diagnostic-notes", default)]
    pub diagnostic_notes: u32,
}

fn default_branch() -> String {
    "main".to_string()
}

fn default_lsp_status() -> String {
    "n/a".to_string()
}

impl Default for HudState {
    fn default() -> Self {
        Self {
            branch: "main".to_string(),
            upstream: String::new(),
            changes: "+0 -0".to_string(),
            location: String::new(),
            last_commit: String::new(),
            project_name: String::new(),
            project_root: String::new(),
            lsp_status: default_lsp_status(),
            diagnostic_errors: 0,
            diagnostic_warnings: 0,
            diagnostic_notes: 0,
        }
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
    Project,
    Changes,
    Branch,
    Lsp,
    Diagnostics,
}

fn draw_icon(ui: &mut egui::Ui, icon: HudIcon, color: egui::Color32) {
    let (rect, _) = ui.allocate_exact_size(egui::vec2(16.0, 16.0), egui::Sense::hover());
    let painter = ui.painter();
    let stroke = egui::Stroke::new(1.7, color);
    let thin = egui::Stroke::new(1.35, color);
    let c = rect.center();

    match icon {
        HudIcon::Project => {
            let r = egui::Rect::from_min_max(
                egui::pos2(rect.left() + 3.0, rect.top() + 4.5),
                egui::pos2(rect.right() - 3.0, rect.bottom() - 3.5),
            );
            painter.rect_stroke(r, 2.5, stroke);
            painter.line_segment(
                [
                    egui::pos2(r.left() + 2.0, r.top() + 3.5),
                    egui::pos2(r.right() - 2.0, r.top() + 3.5),
                ],
                thin,
            );
        }
        HudIcon::Changes => {
            let r = egui::Rect::from_center_size(c, egui::vec2(13.0, 13.0));
            painter.rect_stroke(r, 3.0, stroke);
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
        HudIcon::Lsp => {
            let a = egui::pos2(rect.left() + 5.0, rect.top() + 5.0);
            let b = egui::pos2(rect.right() - 5.0, c.y);
            let d = egui::pos2(rect.left() + 5.0, rect.bottom() - 5.0);
            painter.line_segment([a, b], thin);
            painter.line_segment([d, b], thin);
            painter.circle_stroke(a, 2.5, stroke);
            painter.circle_stroke(b, 2.5, stroke);
            painter.circle_stroke(d, 2.5, stroke);
        }
        HudIcon::Diagnostics => {
            painter.line_segment(
                [
                    egui::pos2(c.x, rect.top() + 3.5),
                    egui::pos2(rect.right() - 3.5, c.y),
                ],
                thin,
            );
            painter.line_segment(
                [
                    egui::pos2(rect.right() - 3.5, c.y),
                    egui::pos2(c.x, rect.bottom() - 3.5),
                ],
                thin,
            );
            painter.line_segment(
                [
                    egui::pos2(c.x, rect.bottom() - 3.5),
                    egui::pos2(rect.left() + 3.5, c.y),
                ],
                thin,
            );
            painter.line_segment(
                [
                    egui::pos2(rect.left() + 3.5, c.y),
                    egui::pos2(c.x, rect.top() + 3.5),
                ],
                thin,
            );
            painter.circle_filled(c, 1.8, color);
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

fn compact_text(value: &str, fallback: &str, max_chars: usize) -> String {
    let trimmed = value.trim();
    let display = if trimmed.is_empty() {
        fallback
    } else {
        trimmed
    };
    let char_count = display.chars().count();

    if char_count <= max_chars {
        return display.to_string();
    }

    if max_chars <= 3 {
        return ".".repeat(max_chars);
    }

    let keep = max_chars - 3;
    let head_len = keep - (keep / 2);
    let tail_len = keep / 2;
    let head: String = display.chars().take(head_len).collect();
    let tail_chars: Vec<char> = display.chars().rev().take(tail_len).collect();
    let tail: String = tail_chars.into_iter().rev().collect();

    format!("{head}...{tail}")
}

fn diagnostics_display(errors: u32, warnings: u32, notes: u32) -> String {
    match (errors, warnings, notes) {
        (0, 0, 0) => "0 err".to_string(),
        (0, 0, notes) => format!("{notes} info"),
        (0, warnings, _) => format!("{warnings} warn"),
        (errors, 0, _) => format!("{errors} err"),
        (errors, warnings, _) => format!("{errors}E {warnings}W"),
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

pub struct HudApp {
    state: HudState,
    theme: ThemeColors,
}

impl HudApp {
    pub fn new() -> Self {
        Self {
            state: HudState::default(),
            theme: ThemeColors::default(),
        }
    }
}

impl EguiEmacsApp for HudApp {
    type State = HudState;

    fn on_state_update(&mut self, state: Self::State) {
        self.state = state;
    }

    fn on_theme_update(&mut self, theme: ThemeColors) {
        self.theme = theme;
    }

    fn update(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        let bg = parse_hex_color(&self.theme.bg).unwrap_or(egui::Color32::from_rgb(12, 12, 16));
        let fg = parse_hex_color(&self.theme.fg).unwrap_or(egui::Color32::from_rgb(230, 235, 255));
        let is_dark = luminance(bg) < 128;
        let text_size = self
            .theme
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
        let card_bg =
            parse_hex_color(&self.theme.surface_bg).unwrap_or_else(|| card_fill_from_bg(bg));
        let separator_color = if is_dark {
            egui::Color32::from_rgba_unmultiplied(fg.r(), fg.g(), fg.b(), 28)
        } else {
            egui::Color32::from_rgba_unmultiplied(30, 34, 40, 22)
        };

        // Keep egui itself transparent.
        let mut style = (*ctx.style()).clone();
        style.visuals.widgets.noninteractive.bg_fill = egui::Color32::TRANSPARENT;
        style.visuals.window_fill = egui::Color32::TRANSPARENT;
        style.visuals.panel_fill = egui::Color32::TRANSPARENT;
        ctx.set_style(style);

        egui::CentralPanel::default()
            .frame(
                egui::Frame::none()
                    .fill(card_bg)
                    .rounding(egui::Rounding::ZERO)
                    .inner_margin(egui::Margin {
                        left: 12.0,
                        right: 12.0,
                        top: 14.0,
                        bottom: 14.0,
                    })
                    .stroke(egui::Stroke::NONE),
            )
            .show(ctx, |ui| {
                ui.spacing_mut().item_spacing = egui::vec2(0.0, 0.0);

                section_header(ui, "Workspace", col_text_muted, text_size, &font_family);
                soft_separator(ui, separator_color);

                let project_display = compact_text(&self.state.project_name, "No project", 24);
                let location_display = compact_text(&self.state.location, "", 10);
                hud_row(
                    ui,
                    HudIcon::Project,
                    &project_display,
                    if location_display.is_empty() {
                        None
                    } else {
                        Some(RowRight::Plain(&location_display, col_text_muted))
                    },
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                let branch_display = compact_text(&self.state.branch, "no branch", 22);
                let upstream_display = compact_text(&self.state.upstream, "", 12);
                hud_row(
                    ui,
                    HudIcon::Branch,
                    &branch_display,
                    if upstream_display.is_empty() {
                        None
                    } else {
                        Some(RowRight::Plain(&upstream_display, col_text_primary))
                    },
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                let has_changes = !self.state.changes.is_empty()
                    && self.state.changes != "0 files"
                    && self.state.changes != "+0 -0";
                let changes_display = if self.state.changes.is_empty() {
                    "0 files".to_string()
                } else {
                    self.state.changes.clone()
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
                    "Dirty",
                    changes_right,
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                ui.add_space(7.0);
                soft_separator(ui, separator_color);
                section_header(ui, "Health", col_text_muted, text_size, &font_family);

                let lsp_status = compact_text(&self.state.lsp_status, "n/a", 12);
                let lsp_color = match lsp_status.as_str() {
                    "online" => col_green,
                    "offline" => col_red,
                    _ => col_text_muted,
                };
                hud_row(
                    ui,
                    HudIcon::Lsp,
                    "LSP",
                    Some(RowRight::Plain(&lsp_status, lsp_color)),
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );

                let diagnostics = diagnostics_display(
                    self.state.diagnostic_errors,
                    self.state.diagnostic_warnings,
                    self.state.diagnostic_notes,
                );
                let diagnostics_color = if self.state.diagnostic_errors > 0 {
                    col_red
                } else if self.state.diagnostic_warnings > 0 {
                    col_orange
                } else {
                    col_text_muted
                };
                hud_row(
                    ui,
                    HudIcon::Diagnostics,
                    "Diagnostics",
                    Some(RowRight::Plain(&diagnostics, diagnostics_color)),
                    col_text_primary,
                    col_text_muted,
                    text_size,
                    &font_family,
                );
            });
    }
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn start_app(canvas_id: &str) -> Result<(), JsValue> {
    emacs_egui_sdk::launch_simple(canvas_id, HudApp::new())
}
