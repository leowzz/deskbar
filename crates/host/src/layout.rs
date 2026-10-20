//! Per-device layouts are owned by the computer; display reports are transient.
use anyhow::{ensure, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LayoutDocument {
    pub schema_version: u32,
    pub active_page_id: String,
    pub pages: Vec<Page>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Page {
    pub id: String,
    pub name: String,
    pub widgets: Vec<Widget>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Widget {
    pub id: String,
    pub title: String,
    pub r#type: String,
    pub visible: bool,
    pub binding: BTreeMap<String, String>,
    pub options: BTreeMap<String, Value>,
    pub placements: BTreeMap<String, Placement>,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Placement {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}
impl Placement {
    fn overlaps(&self, b: &Self) -> bool {
        self.x < b.x + b.w && self.x + self.w > b.x && self.y < b.y + b.h && self.y + self.h > b.y
    }
}
fn valid_text(s: &str) -> bool {
    !s.trim().is_empty() && s.len() <= 256
}
impl LayoutDocument {
    pub fn validate(&self, host_id: &str) -> Result<()> {
        ensure!(self.schema_version == 3, "布局版本不支持，请更新双端");
        ensure!(
            !self.pages.is_empty() && self.pages.len() <= 32,
            "请保留 1 至 32 个页面"
        );
        ensure!(
            self.pages.iter().any(|p| p.id == self.active_page_id),
            "当前页面无效"
        );
        let mut ids = HashSet::new();
        for page in &self.pages {
            ensure!(
                valid_text(&page.id) && valid_text(&page.name) && ids.insert(&page.id),
                "页面名称或编号无效"
            );
            ensure!(page.widgets.len() <= 64, "每页最多 64 个组件");
            for widget in &page.widgets {
                ensure!(
                    valid_text(&widget.id) && ids.insert(&widget.id) && widget.title.len() <= 256,
                    "组件名称或编号无效"
                );
                ensure!(
                    matches!(
                        widget.r#type.as_str(),
                        "sessions" | "usage" | "shortcuts" | "statusBar"
                    ),
                    "组件类型无效"
                );
                ensure!(
                    widget.binding.iter().all(|(k, v)| matches!(
                        k.as_str(),
                        "hostId" | "source" | "resourceId"
                    ) && v.len() <= 256),
                    "组件来源无效"
                );
                ensure!(
                    widget
                        .binding
                        .get("hostId")
                        .is_none_or(|v| v.is_empty() || v == host_id),
                    "组件必须绑定此电脑"
                );
                ensure!(widget.options.len() <= 16, "组件参数过多");
                for (key, value) in &widget.options {
                    let valid = match key.as_str() {
                        "showTitle" | "fitRows" | "labels" | "showClock" | "showSeconds"
                        | "showConnection" | "showThemeButton" | "showSettingsButton" => {
                            value.is_boolean()
                        }
                        // Kept readable for layouts written by older editors;
                        // current clients omit it and show details in a tooltip.
                        "showDetails" => value.is_boolean(),
                        "label" => {
                            widget.r#type == "statusBar"
                                && value.as_str().is_some_and(|v| v.chars().count() <= 80)
                        }
                        "appearance" => match widget.r#type.as_str() {
                            "sessions" => matches!(value.as_str(), Some("plain" | "cards")),
                            "shortcuts" => matches!(value.as_str(), Some("plain" | "dock")),
                            _ => false,
                        },
                        "textScale" => {
                            widget.r#type == "sessions"
                                && value.as_f64().is_some_and(|n| (1.0..=2.0).contains(&n))
                        }
                        "maxSessions" => value.as_u64().is_some_and(|n| (1..=40).contains(&n)),
                        "itemWidth" | "itemHeight" => {
                            value.as_f64().is_some_and(|n| n > 0.0 && n <= 2000.0)
                        }
                        "iconSize" => {
                            value == "max" || value.as_f64().is_some_and(|n| n > 0.0 && n <= 200.0)
                        }
                        "spacing" => {
                            widget.r#type == "shortcuts"
                                && value.as_f64().is_some_and(|n| (0.0..=16.0).contains(&n))
                        }
                        "gap" | "gapX" | "gapY" => {
                            value.as_f64().is_some_and(|n| (0.0..=128.0).contains(&n))
                        }
                        "density" => match widget.r#type.as_str() {
                            "sessions" => matches!(value.as_str(), Some("normal" | "compact")),
                            "usage" => {
                                matches!(
                                    value.as_str(),
                                    Some("compact" | "standard" | "fill" | "sidebar")
                                )
                            }
                            _ => false,
                        },
                        "content" => matches!(value.as_str(), Some("quota" | "api")),
                        "columns" => {
                            value == "auto"
                                || (widget.r#type == "sessions"
                                    && value.as_u64().is_some_and(|n| (1..=6).contains(&n)))
                        }
                        "rows" => {
                            value == "auto" || value.as_u64().is_some_and(|n| (1..=12).contains(&n))
                        }
                        "alignment" => match widget.r#type.as_str() {
                            "usage" => matches!(
                                value.as_str(),
                                Some("top" | "center" | "spaceEvenly" | "bottom")
                            ),
                            _ => matches!(
                                value.as_str(),
                                Some("left" | "center" | "spaceEvenly" | "right")
                            ),
                        },
                        _ => false,
                    };
                    ensure!(valid, "组件参数无效：{key}");
                }
                ensure!(widget.placements.len() == 2, "缺少横竖屏布局");
                for (orientation, columns, rows) in [("wide", 48, 48), ("portrait", 16, 96)] {
                    let r = widget
                        .placements
                        .get(orientation)
                        .context("缺少横竖屏布局")?;
                    ensure!(
                        r.w > 0
                            && r.h > 0
                            && r.w <= columns
                            && r.h <= rows
                            && r.x <= columns - r.w
                            && r.y <= rows - r.h,
                        "组件超出屏幕"
                    );
                }
            }
            // Check overlap only after every coordinate has passed bounds checks.
            for (index, a) in page.widgets.iter().enumerate().filter(|(_, w)| w.visible) {
                for b in page.widgets.iter().skip(index + 1).filter(|w| w.visible) {
                    ensure!(
                        !a.placements["wide"].overlaps(&b.placements["wide"])
                            && !a.placements["portrait"].overlaps(&b.placements["portrait"]),
                        "组件不能重叠"
                    );
                }
            }
        }
        Ok(())
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DisplayReport {
    pub width: f64,
    pub height: f64,
    pub text_scale: f64,
    pub dark: bool,
    pub page_id: String,
    pub layout_revision: u64,
}
#[derive(Clone, Debug, Serialize)]
pub struct DisplayState {
    #[serde(flatten)]
    pub report: DisplayReport,
    pub seen_at: u64,
}
impl crate::Host {
    pub fn save_layout(
        &mut self,
        id: &str,
        expected_revision: u64,
        layout: LayoutDocument,
    ) -> Result<u64> {
        layout.validate(&self.id)?;
        let mut devices = self.devices.clone();
        let device = devices
            .iter_mut()
            .find(|d| d.id == id)
            .context("设备已移除")?;
        ensure!(
            device.layout_revision == expected_revision,
            "布局已在其他窗口修改，请重新打开编辑器"
        );
        device.layout = Some(layout);
        device.layout_revision += 1;
        let revision = device.layout_revision;
        self.save(&devices)?;
        self.devices = devices;
        self.revision += 1;
        Ok(revision)
    }
    pub fn report_display(&mut self, token: &str, report: DisplayReport) -> Result<()> {
        let id = self.device_id(token).context("设备未授权")?;
        ensure!(
            (1.0..=8192.0).contains(&report.width)
                && (1.0..=8192.0).contains(&report.height)
                && (0.5..=4.0).contains(&report.text_scale)
                && report.page_id.len() <= 256,
            "显示参数无效"
        );
        self.devices
            .iter_mut()
            .find(|d| d.id == id)
            .unwrap()
            .display = Some(DisplayState {
            report,
            seen_at: crate::now(),
        });
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{secret, Host};
    fn pair(host: &mut Host) -> (String, String) {
        let invite = host.invite(100);
        let claim = secret();
        let request = host
            .request_pairing(&invite.session_id, &invite.secret, &claim, "屏幕", 101)
            .unwrap();
        host.approve(&request.id, 102).unwrap();
        let token = host.claim(&request.id, &claim, 103).unwrap().unwrap();
        (request.id, token)
    }
    fn document() -> LayoutDocument {
        serde_json::from_str(include_str!("../../../protocol/layout.example.json")).unwrap()
    }
    #[test]
    fn dashboard_contract_accepts_options_and_rejects_invalid_values() {
        let layout: LayoutDocument =
            serde_json::from_str(include_str!("../../../protocol/dashboard.example.json")).unwrap();
        layout.validate("host").unwrap();
        for (index, key, value) in [
            (0, "showClock", serde_json::json!("yes")),
            (0, "label", serde_json::json!("a".repeat(81))),
            (2, "columns", serde_json::json!(7)),
            (2, "appearance", serde_json::json!("unknown")),
            (2, "textScale", serde_json::json!(3)),
        ] {
            let mut invalid = layout.clone();
            invalid.pages[0].widgets[index]
                .options
                .insert(key.into(), value);
            assert!(invalid.validate("host").is_err(), "{key}");
        }
    }

    #[test]
    fn shortcut_spacing_is_bounded_and_round_trips() {
        let mut layout: LayoutDocument =
            serde_json::from_str(include_str!("../../../protocol/dashboard.example.json")).unwrap();
        for value in [serde_json::json!(0), serde_json::json!(16)] {
            layout.pages[0].widgets[3]
                .options
                .insert("spacing".into(), value.clone());
            layout.validate("host").unwrap();
            let restored: LayoutDocument =
                serde_json::from_str(&serde_json::to_string(&layout).unwrap()).unwrap();
            assert_eq!(restored.pages[0].widgets[3].options["spacing"], value);
        }
        for value in [
            serde_json::json!(-1),
            serde_json::json!(17),
            serde_json::json!("8"),
        ] {
            layout.pages[0].widgets[3]
                .options
                .insert("spacing".into(), value);
            assert!(layout.validate("host").is_err());
        }
    }

    #[test]
    fn accepts_current_usage_options_and_legacy_detail_flag() {
        let mut layout = document();
        let mut usage = layout.pages[0].widgets[0].clone();
        usage.id = "usage-1".into();
        usage.title = "额度".into();
        usage.r#type = "usage".into();
        usage.visible = false;
        usage.options = BTreeMap::from([
            ("content".into(), serde_json::json!("api")),
            ("density".into(), serde_json::json!("fill")),
            ("alignment".into(), serde_json::json!("bottom")),
            ("showDetails".into(), serde_json::json!(true)),
        ]);
        layout.pages[0].widgets.push(usage);
        assert!(layout.validate("host").is_ok());
    }
    #[test]
    fn layout_is_device_scoped_durable_and_revision_checked() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let (id, token) = pair(&mut host);
        let (_, other) = pair(&mut host);
        assert_eq!(host.save_layout(&id, 0, document()).unwrap(), 1);
        assert!(host.save_layout(&id, 0, document()).is_err());
        assert!(host.authorized_snapshot(&other).unwrap().layout.is_none());
        assert!(host.authorized_snapshot(&token).unwrap().layout.is_some());
        assert!(host
            .authorized_snapshot(&token)
            .unwrap()
            .sessions
            .is_empty());
        drop(host);
        let mut host = Host::load(dir.path().into(), "unused".into()).unwrap();
        assert_eq!(host.authorized_snapshot(&token).unwrap().layout_revision, 1);
        host.revoke(&id).unwrap();
        assert!(host.device_snapshot(&id).is_none());
        assert!(host.save_layout(&id, 1, document()).is_err());
    }
    #[test]
    fn rejects_invalid_layouts_without_replacing_saved_state() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let (id, token) = pair(&mut host);
        host.save_layout(&id, 0, document()).unwrap();
        let mut invalid = document();
        invalid.pages[0].widgets[0]
            .placements
            .get_mut("wide")
            .unwrap()
            .w = u32::MAX;
        assert!(host.save_layout(&id, 1, invalid).is_err());
        let mut invalid = document();
        let mut overlap = invalid.pages[0].widgets[0].clone();
        overlap.id = "overlap".into();
        invalid.pages[0].widgets.push(overlap);
        assert!(host.save_layout(&id, 1, invalid).is_err());
        let mut invalid = document();
        invalid.pages[0].widgets[0]
            .binding
            .insert("hostId".into(), "another-computer".into());
        assert!(host.save_layout(&id, 1, invalid).is_err());
        let mut invalid = document();
        invalid.pages[1].widgets[0]
            .options
            .insert("rows".into(), serde_json::json!(13));
        assert!(host.save_layout(&id, 1, invalid).is_err());
        let mut invalid = document();
        invalid.pages[1].widgets[0]
            .options
            .insert("alignment".into(), serde_json::json!("justify"));
        assert!(host.save_layout(&id, 1, invalid).is_err());
        assert_eq!(host.authorized_snapshot(&token).unwrap().layout_revision, 1);
        // A failed atomic write also leaves the in-memory layout unchanged.
        std::fs::create_dir(dir.path().join("host.yaml.tmp")).unwrap();
        assert!(host.save_layout(&id, 1, document()).is_err());
        assert_eq!(host.authorized_snapshot(&token).unwrap().layout_revision, 1);
    }
    #[test]
    fn display_reports_require_authentication_and_bounded_metrics() {
        let dir = tempfile::tempdir().unwrap();
        let mut host = Host::load(dir.path().into(), "电脑".into()).unwrap();
        let (id, token) = pair(&mut host);
        let report = DisplayReport {
            width: 1280.0,
            height: 720.0,
            text_scale: 1.0,
            dark: false,
            page_id: "main".into(),
            layout_revision: 0,
        };
        assert!(host.report_display("wrong-token", report.clone()).is_err());
        assert!(host
            .report_display(
                &token,
                DisplayReport {
                    width: f64::NAN,
                    ..report.clone()
                }
            )
            .is_err());
        host.report_display(&token, report).unwrap();
        assert_eq!(
            host.devices
                .iter()
                .find(|d| d.id == id)
                .unwrap()
                .display
                .as_ref()
                .unwrap()
                .report
                .width,
            1280.0
        );
    }
}
