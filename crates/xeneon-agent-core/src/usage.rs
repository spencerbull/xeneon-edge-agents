use std::{
    env, fs,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::Value;

use crate::model::{AiUsageSnapshot, ProviderUsage, UsageKind, UsageWindow};

const FRESH_FOR: Duration = Duration::from_secs(15 * 60);
const MAX_CACHE_BYTES: u64 = 64 * 1024;

#[derive(Debug, Clone)]
pub struct UsageCollector {
    cache_dir: PathBuf,
}

impl Default for UsageCollector {
    fn default() -> Self {
        let cache_dir = env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".cache")))
            .unwrap_or_else(|| PathBuf::from(".cache"));
        Self { cache_dir }
    }
}

impl UsageCollector {
    pub fn new(cache_dir: impl Into<PathBuf>) -> Self {
        Self {
            cache_dir: cache_dir.into(),
        }
    }

    pub fn sample(&self) -> AiUsageSnapshot {
        AiUsageSnapshot {
            providers: vec![
                self.read_provider("claude", "Claude", UsageKind::Quota),
                self.read_provider("codex", "Codex", UsageKind::Quota),
                self.read_provider("opencode", "OpenCode", UsageKind::LocalBudget),
            ],
        }
    }

    fn read_provider(&self, id: &str, label: &str, kind: UsageKind) -> ProviderUsage {
        let path = self.cache_dir.join(format!("{id}-usage.json"));
        let last_updated_ms = modified_ms(&path);
        let stale_by_age = last_updated_ms
            .and_then(|updated| now_ms().checked_sub(updated))
            .is_none_or(|age| age > FRESH_FOR.as_millis() as u64);
        let value = fs::metadata(&path)
            .ok()
            .filter(|metadata| metadata.len() <= MAX_CACHE_BYTES)
            .and_then(|_| fs::read_to_string(&path).ok())
            .and_then(|contents| serde_json::from_str::<Value>(&contents).ok());
        let Some(value) = value else {
            return unavailable_provider(id, label, kind, last_updated_ms);
        };

        let source = safe_source(value.get("_source").and_then(Value::as_str));
        let status = safe_status(value.get("status").and_then(Value::as_str));
        let mut provider = ProviderUsage {
            id: id.into(),
            label: label.into(),
            kind,
            available: false,
            stale: stale_by_age || source == "stale",
            source,
            status,
            plan: bounded(value.get("_plan").and_then(Value::as_str), 32),
            model: bounded(value.get("_model").and_then(Value::as_str), 80),
            primary: None,
            secondary: None,
            last_updated_ms,
        };

        if id == "codex" {
            apply_codex_windows(&value, &mut provider);
        } else {
            provider.primary = legacy_window(&value, "5h", "5h-utilization", "5h-reset");
            provider.secondary = legacy_window(&value, "Weekly", "7d-utilization", "7d-reset");
        }
        let trusted = source_is_usable(id, &provider.source) && status_is_usable(&provider.status);
        provider.available =
            trusted && (provider.primary.is_some() || provider.secondary.is_some());
        if !trusted {
            provider.stale = true;
            provider.primary = None;
            provider.secondary = None;
        }
        provider
    }
}

fn apply_codex_windows(value: &Value, provider: &mut ProviderUsage) {
    let bucket = value
        .get("buckets")
        .and_then(Value::as_array)
        .and_then(|buckets| {
            buckets
                .iter()
                .find(|bucket| bucket.get("isGeneral").and_then(Value::as_bool) == Some(true))
                .or_else(|| {
                    buckets
                        .iter()
                        .find(|bucket| bucket.get("id").and_then(Value::as_str) == Some("codex"))
                })
        });
    let windows = bucket
        .and_then(|bucket| bucket.get("windows"))
        .or_else(|| value.get("windows"))
        .and_then(Value::as_array);
    if let Some(bucket) = bucket {
        provider.plan = bounded(
            bucket
                .get("plan")
                .and_then(Value::as_str)
                .or_else(|| value.get("_plan").and_then(Value::as_str)),
            32,
        );
    }
    let Some(windows) = windows else {
        provider.secondary = legacy_window(value, "Weekly", "7d-utilization", "7d-reset");
        return;
    };
    provider.primary = windows.first().and_then(codex_window);
    provider.secondary = windows.get(1).and_then(codex_window);
}

fn codex_window(value: &Value) -> Option<UsageWindow> {
    let utilization = numeric(value.get("utilization"))?.clamp(0.0, 1.0);
    let label =
        bounded(value.get("label").and_then(Value::as_str), 24).unwrap_or_else(|| "Usage".into());
    let reset_at_ms = numeric(value.get("reset"))
        .filter(|reset| *reset > 0.0)
        .map(|reset| (reset * 1_000.0) as u64);
    Some(UsageWindow {
        label,
        utilization,
        reset_at_ms,
    })
}

fn legacy_window(
    value: &Value,
    label: &str,
    utilization_key: &str,
    reset_key: &str,
) -> Option<UsageWindow> {
    let utilization = numeric(value.get(utilization_key))?.clamp(0.0, 1.0);
    let reset_at_ms = numeric(value.get(reset_key))
        .filter(|reset| *reset > 0.0)
        .map(|reset| (reset * 1_000.0) as u64);
    Some(UsageWindow {
        label: label.into(),
        utilization,
        reset_at_ms,
    })
}

fn numeric(value: Option<&Value>) -> Option<f64> {
    let value = value?;
    value
        .as_f64()
        .or_else(|| value.as_str().and_then(|raw| raw.parse().ok()))
        .filter(|number: &f64| number.is_finite())
}

fn bounded(value: Option<&str>, limit: usize) -> Option<String> {
    value
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(|value| value.chars().take(limit).collect())
}

fn safe_source(value: Option<&str>) -> String {
    match value.unwrap_or_default() {
        "oauth" | "rpc" | "rollout" | "sqlite" | "fixture" | "stale" => {
            value.unwrap_or_default().into()
        }
        _ => "unknown".into(),
    }
}

fn safe_status(value: Option<&str>) -> String {
    match value.unwrap_or_default() {
        "allowed" | "allowed_warning" | "blocked" | "rejected" => value.unwrap_or_default().into(),
        _ => "unknown".into(),
    }
}

fn source_is_usable(provider: &str, source: &str) -> bool {
    source == "fixture"
        || source == "stale"
        || matches!(
            (provider, source),
            ("claude", "oauth") | ("codex", "rpc") | ("codex", "rollout") | ("opencode", "sqlite")
        )
}

fn status_is_usable(status: &str) -> bool {
    matches!(status, "allowed" | "allowed_warning")
}

fn unavailable_provider(
    id: &str,
    label: &str,
    kind: UsageKind,
    last_updated_ms: Option<u64>,
) -> ProviderUsage {
    ProviderUsage {
        id: id.into(),
        label: label.into(),
        kind,
        available: false,
        stale: true,
        source: "unavailable".into(),
        status: "unavailable".into(),
        plan: None,
        model: None,
        primary: None,
        secondary: None,
        last_updated_ms,
    }
}

fn modified_ms(path: &Path) -> Option<u64> {
    fs::metadata(path)
        .ok()?
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()
        .map(|duration| duration.as_millis() as u64)
}

fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collector_normalizes_quota_and_local_budget_without_raw_counters() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("claude-usage.json"),
            r#"{"5h-utilization":"0.25","5h-reset":"1800000000","7d-utilization":"0.5","7d-reset":"1800100000","_source":"oauth","status":"allowed","_today_tokens":999}"#,
        )
        .unwrap();
        fs::write(
            temp.path().join("codex-usage.json"),
            r#"{"buckets":[{"isGeneral":true,"plan":"pro","windows":[{"label":"Weekly","utilization":0.74,"reset":1800000000}]}],"_source":"rpc","status":"allowed"}"#,
        )
        .unwrap();
        fs::write(
            temp.path().join("opencode-usage.json"),
            r#"{"5h-utilization":"0.1","7d-utilization":"0.2","_source":"sqlite","_plan":"local messages","_model":"gpt-test","status":"allowed"}"#,
        )
        .unwrap();

        let snapshot = UsageCollector::new(temp.path()).sample();
        assert_eq!(snapshot.providers.len(), 3);
        assert_eq!(
            snapshot.providers[0].primary.as_ref().unwrap().utilization,
            0.25
        );
        assert_eq!(
            snapshot.providers[1].primary.as_ref().unwrap().label,
            "Weekly"
        );
        assert_eq!(snapshot.providers[2].kind, UsageKind::LocalBudget);
        assert_eq!(snapshot.providers[2].model.as_deref(), Some("gpt-test"));
        let encoded = serde_json::to_string(&snapshot).unwrap();
        assert!(!encoded.contains("today_tokens"));
        assert!(!encoded.contains("_models"));
    }

    #[test]
    fn absent_files_remain_explicitly_unavailable() {
        let temp = tempfile::tempdir().unwrap();
        let snapshot = UsageCollector::new(temp.path()).sample();
        assert!(
            snapshot
                .providers
                .iter()
                .all(|provider| !provider.available)
        );
        assert!(snapshot.providers.iter().all(|provider| provider.stale));
    }

    #[test]
    fn blocked_or_untrusted_cache_data_fails_closed() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("claude-usage.json"),
            r#"{"5h-utilization":"0.25","_source":"oauth","status":"blocked"}"#,
        )
        .unwrap();
        fs::write(
            temp.path().join("codex-usage.json"),
            r#"{"windows":[{"label":"Weekly","utilization":0.9}],"_source":"mystery","status":"allowed"}"#,
        )
        .unwrap();

        let snapshot = UsageCollector::new(temp.path()).sample();
        let claude = &snapshot.providers[0];
        assert_eq!(claude.status, "blocked");
        assert!(!claude.available);
        assert!(claude.stale);
        assert!(claude.primary.is_none());
        let codex = &snapshot.providers[1];
        assert_eq!(codex.source, "unknown");
        assert!(!codex.available);
        assert!(codex.stale);
        assert!(codex.primary.is_none());
    }
}
