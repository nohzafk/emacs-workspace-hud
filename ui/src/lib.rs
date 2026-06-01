use emacs_egui_sdk::eframe;
use emacs_egui_sdk::egui;
use emacs_egui_sdk::{parse_hex_color, EguiEmacsApp, ThemeColors};
use serde::{Deserialize, Serialize};
use wasm_bindgen::prelude::*;

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HudSection {
    pub title: String,
    pub priority: u32,
    pub rows: Vec<HudRow>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HudRow {
    pub label: String,
    pub value: String,
    pub status: Option<String>,
    pub detail: Option<String>,
    #[serde(rename = "max-lines")]
    pub max_lines: Option<u32>,
    pub icon: Option<String>,
}

#[derive(Serialize, Deserialize, Clone, Debug)]
pub struct HudState {
    #[serde(default)]
    pub sections: Vec<HudSection>,
}

impl Default for HudState {
    fn default() -> Self {
        Self {
            sections: Vec::new(),
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
    Agent,
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
        HudIcon::Agent => {
            let r = egui::Rect::from_center_size(c, egui::vec2(8.0, 8.0));
            painter.rect_stroke(r, 1.5, stroke);
            painter.circle_filled(c, 1.2, color);
            painter.line_segment([egui::pos2(c.x - 2.0, r.top()), egui::pos2(c.x - 2.0, r.top() - 2.5)], thin);
            painter.line_segment([egui::pos2(c.x + 2.0, r.top()), egui::pos2(c.x + 2.0, r.top() - 2.5)], thin);
            painter.line_segment([egui::pos2(c.x - 2.0, r.bottom()), egui::pos2(c.x - 2.0, r.bottom() + 2.5)], thin);
            painter.line_segment([egui::pos2(c.x + 2.0, r.bottom()), egui::pos2(c.x + 2.0, r.bottom() + 2.5)], thin);
            painter.line_segment([egui::pos2(r.left(), c.y - 2.0), egui::pos2(r.left() - 2.5, c.y - 2.0)], thin);
            painter.line_segment([egui::pos2(r.left(), c.y + 2.0), egui::pos2(r.left() - 2.5, c.y + 2.0)], thin);
            painter.line_segment([egui::pos2(r.right(), c.y - 2.0), egui::pos2(r.right() + 2.5, c.y - 2.0)], thin);
            painter.line_segment([egui::pos2(r.right(), c.y + 2.0), egui::pos2(r.right() + 2.5, c.y + 2.0)], thin);
        }
    }
}

fn map_icon(icon_str: &str) -> HudIcon {
    match icon_str {
        "project" => HudIcon::Project,
        "branch" => HudIcon::Branch,
        "changes" => HudIcon::Changes,
        "lsp" => HudIcon::Lsp,
        "diagnostics" => HudIcon::Diagnostics,
        "agent" => HudIcon::Agent,
        _ => HudIcon::Project,
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

                let len = self.state.sections.len();
                for (idx, section) in self.state.sections.iter().enumerate() {
                    section_header(ui, &section.title, col_text_muted, text_size, &font_family);
                    soft_separator(ui, separator_color);

                    for row in &section.rows {
                        let row_icon = if let Some(ref icon_str) = row.icon {
                            map_icon(icon_str)
                        } else {
                            HudIcon::Project
                        };

                        let row_color = match row.status.as_deref() {
                            Some("ok") => col_green,
                            Some("warn") => col_orange,
                            Some("error") => col_red,
                            Some("busy") => egui::Color32::from_rgb(98, 160, 234),
                            _ => col_text_muted,
                        };

                        let right_content = if let Some((added, removed)) = split_diff_stat(&row.value) {
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
                        } else if !row.value.is_empty() {
                            Some(RowRight::Plain(&row.value, row_color))
                        } else {
                            None
                        };

                        hud_row(
                            ui,
                            row_icon,
                            &row.label,
                            right_content,
                            col_text_primary,
                            col_text_muted,
                            text_size,
                            &font_family,
                        );
                    }

                    if idx + 1 < len {
                        ui.add_space(18.0);
                    }
                }
            });
    }
}

#[cfg(target_arch = "wasm32")]
#[wasm_bindgen]
pub fn start_app(canvas_id: &str) -> Result<(), JsValue> {
    emacs_egui_sdk::launch_simple(canvas_id, HudApp::new())
}
