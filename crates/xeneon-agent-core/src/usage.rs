use std::{
    collections::HashMap,
    env, fs,
    io::Read,
    path::{Path, PathBuf},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use rusqlite::{Connection, OpenFlags, types::Value as SqlValue};
use serde_json::Value;
use time::{OffsetDateTime, format_description::well_known::Rfc3339};

use crate::model::{AiUsageSnapshot, ProviderUsage, UsageKind, UsageWindow};

const FRESH_FOR: Duration = Duration::from_secs(15 * 60);
const MAX_CACHE_BYTES: u64 = 64 * 1024;
const MAX_AGGREGATE_TOKENS: u64 = 1_000_000_000_000_000;
const MAX_OPENCODE_ROWS: usize = 100_000;
const OPENCODE_BUSY_TIMEOUT: Duration = Duration::from_millis(250);
const OPENCODE_QUERY_BUDGET: Duration = Duration::from_millis(500);
const OPENCODE_5H_LIMIT: u64 = 1_000_000;
const OPENCODE_7D_LIMIT: u64 = 20_000_000;
const FIVE_HOURS_MS: u64 = 5 * 60 * 60 * 1_000;
const SEVEN_DAYS_MS: u64 = 7 * 24 * 60 * 60 * 1_000;
const ONE_HOUR_MS: u64 = 60 * 60 * 1_000;

#[derive(Debug, Clone)]
pub struct UsageCollector {
    legacy_cache_dir: PathBuf,
    state_usage_dir: PathBuf,
    cliproxy_usage_path: PathBuf,
    opencode_db: PathBuf,
}

impl Default for UsageCollector {
    fn default() -> Self {
        let home = env::var_os("HOME").map(PathBuf::from);
        let legacy_cache_dir = env::var_os("XDG_CACHE_HOME")
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|home| home.join(".cache")))
            .unwrap_or_else(|| PathBuf::from(".cache"));
        let state_usage_dir = env::var_os("XDG_STATE_HOME")
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|home| home.join(".local/state")))
            .unwrap_or_else(|| PathBuf::from(".local/state"))
            .join("omarchy/agents/usage");
        let cliproxy_usage_path = env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/run/user/1000"))
            .join("xeneon-edge-agents/cliproxy-usage.json");
        let opencode_db = env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .or_else(|| home.as_ref().map(|home| home.join(".local/share")))
            .unwrap_or_else(|| PathBuf::from(".local/share"))
            .join("opencode/opencode.db");
        Self {
            legacy_cache_dir,
            state_usage_dir,
            cliproxy_usage_path,
            opencode_db,
        }
    }
}

impl UsageCollector {
    #[cfg(test)]
    fn legacy_only(cache_dir: impl Into<PathBuf>) -> Self {
        let legacy_cache_dir = cache_dir.into();
        Self {
            state_usage_dir: legacy_cache_dir.join("missing-state-records"),
            cliproxy_usage_path: legacy_cache_dir.join("missing-cliproxy-usage.json"),
            opencode_db: legacy_cache_dir.join("missing-opencode.db"),
            legacy_cache_dir,
        }
    }

    pub fn sample(&self) -> AiUsageSnapshot {
        let cliproxy = read_cliproxy_usage(&self.cliproxy_usage_path);
        let claude = merge_provider(
            self.read_quota_provider("claude", "claude", "Claude"),
            cliproxy.get("claude").cloned(),
        );
        let codex = merge_provider(
            self.read_quota_provider("codex", "codex", "Codex"),
            cliproxy.get("codex").cloned(),
        );
        let gemini = merge_provider(
            self.read_omarchy_optional("agy", "gemini", "Gemini"),
            cliproxy.get("gemini").cloned(),
        );
        let grok = merge_provider(
            self.read_omarchy_optional("grok", "grok", "Grok"),
            cliproxy.get("grok").cloned(),
        );
        let cursor = merge_provider(
            self.read_omarchy_optional("cursor", "cursor", "Cursor"),
            cliproxy.get("cursor").cloned(),
        );
        let opencode = self.read_opencode();

        let mut providers = vec![claude, codex];
        let mut extras = 0usize;
        for extra in [gemini, grok, cursor] {
            if extra.available {
                providers.push(extra);
                extras += 1;
            }
        }
        if opencode.available || extras == 0 {
            providers.push(opencode);
        }
        AiUsageSnapshot { providers }
    }

    fn read_quota_provider(&self, file_id: &str, canonical_id: &str, label: &str) -> ProviderUsage {
        let normalized_path = self.state_usage_dir.join(format!("{file_id}.json"));
        if normalized_path.exists() {
            return read_omarchy_provider(&normalized_path, file_id, canonical_id, label);
        }
        self.read_legacy_provider(canonical_id, label, UsageKind::Quota)
    }

    fn read_omarchy_optional(
        &self,
        file_id: &str,
        canonical_id: &str,
        label: &str,
    ) -> ProviderUsage {
        let normalized_path = self.state_usage_dir.join(format!("{file_id}.json"));
        if normalized_path.exists() {
            return read_omarchy_provider(&normalized_path, file_id, canonical_id, label);
        }
        unavailable_provider(canonical_id, label, UsageKind::Quota, None)
    }

    fn read_opencode(&self) -> ProviderUsage {
        let database = read_opencode_db(&self.opencode_db);
        if database.available {
            return database;
        }
        let legacy_path = self.legacy_cache_dir.join("opencode-usage.json");
        if legacy_path.exists() {
            return self.read_legacy_provider("opencode", "OpenCode", UsageKind::LocalBudget);
        }
        database
    }

    fn read_legacy_provider(&self, id: &str, label: &str, kind: UsageKind) -> ProviderUsage {
        let path = self.legacy_cache_dir.join(format!("{id}-usage.json"));
        let last_updated_ms = modified_ms(&path);
        let stale_by_age = last_updated_ms
            .and_then(|updated| now_ms().checked_sub(updated))
            .is_none_or(|age| age > FRESH_FOR.as_millis() as u64);
        let value = read_bounded_json(&path);
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
            account_count: None,
            primary: None,
            secondary: None,
            today_tokens: aggregate_tokens(value.get("_today_tokens")),
            tokens_per_hour: aggregate_tokens(value.get("_rate_per_hour")),
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
            provider.plan = None;
            provider.model = None;
            provider.primary = None;
            provider.secondary = None;
            provider.today_tokens = None;
            provider.tokens_per_hour = None;
        }
        provider
    }
}

fn merge_provider(omarchy: ProviderUsage, cliproxy: Option<ProviderUsage>) -> ProviderUsage {
    let Some(proxy) = cliproxy else {
        return omarchy;
    };
    if !proxy.available {
        return omarchy;
    }
    if !omarchy.available {
        return proxy;
    }
    // Both Omarchy and CLIProxyAPI have live data: prefer CLIProxyAPI when it
    // covers a multi-account pool or fresher limits, and merge today_tokens.
    let prefer_proxy = proxy.account_count.unwrap_or(0) > 1
        || (proxy.primary.is_some() && omarchy.primary.is_none())
        || (omarchy.stale && !proxy.stale);
    let (mut chosen, other) = if prefer_proxy {
        (proxy, omarchy)
    } else {
        (omarchy, proxy)
    };
    if chosen.plan.is_none() {
        chosen.plan = other.plan;
    }
    if chosen.account_count.is_none() {
        chosen.account_count = other.account_count;
    }
    if chosen.secondary.is_none() {
        chosen.secondary = other.secondary;
    }
    chosen.today_tokens = match (chosen.today_tokens, other.today_tokens) {
        (Some(a), Some(b)) => Some(a.max(b)),
        (Some(a), None) => Some(a),
        (None, Some(b)) => Some(b),
        (None, None) => None,
    };
    chosen
}

fn read_cliproxy_usage(path: &Path) -> HashMap<String, ProviderUsage> {
    let mut out = HashMap::new();
    let file_updated_ms = modified_ms(path);
    let Some(value) = read_bounded_json(path) else {
        return out;
    };
    if value.get("schema_version").and_then(Value::as_u64) != Some(1) {
        return out;
    }
    let Some(providers) = value.get("providers").and_then(Value::as_array) else {
        return out;
    };
    let generated_ms = value
        .get("generated_at_ms")
        .and_then(Value::as_u64)
        .or(file_updated_ms);
    let file_stale = stale_by_age(generated_ms);

    for item in providers.iter().take(6) {
        let Some(id) = item
            .get("id")
            .and_then(Value::as_str)
            .map(|s| s.trim().to_ascii_lowercase())
            .filter(|s| {
                matches!(
                    s.as_str(),
                    "claude" | "codex" | "gemini" | "grok" | "cursor"
                )
            })
        else {
            continue;
        };
        let label = bounded(item.get("label").and_then(Value::as_str), 24).unwrap_or_else(|| {
            match id.as_str() {
                "claude" => "Claude",
                "codex" => "Codex",
                "gemini" => "Gemini",
                "grok" => "Grok",
                "cursor" => "Cursor",
                _ => "Agent",
            }
            .into()
        });
        let primary = item.get("primary").and_then(cliproxy_window);
        let secondary = item.get("secondary").and_then(cliproxy_window);
        let today_tokens = aggregate_tokens(item.get("today_tokens"));
        if primary.is_none() && secondary.is_none() && today_tokens.is_none() {
            continue;
        }
        let status = safe_status(item.get("status").and_then(Value::as_str));
        let status = if status == "unknown" {
            "allowed".into()
        } else {
            status
        };
        let account_count = item
            .get("account_count")
            .and_then(Value::as_u64)
            .and_then(|count| u32::try_from(count).ok())
            .filter(|count| *count > 0);
        let last_updated_ms = item
            .get("last_updated_ms")
            .and_then(Value::as_u64)
            .or(generated_ms);
        out.insert(
            id.clone(),
            ProviderUsage {
                id,
                label,
                kind: UsageKind::Quota,
                available: status_is_usable(&status),
                stale: file_stale || stale_by_age(last_updated_ms),
                source: "cliproxy".into(),
                status,
                plan: bounded(item.get("plan").and_then(Value::as_str), 32),
                model: bounded(item.get("model").and_then(Value::as_str), 80),
                account_count,
                primary,
                secondary,
                today_tokens,
                tokens_per_hour: None,
                last_updated_ms,
            },
        );
    }
    out
}

fn cliproxy_window(value: &Value) -> Option<UsageWindow> {
    let utilization = numeric(value.get("utilization"))?.clamp(0.0, 1.0);
    let label = bounded(value.get("label").and_then(Value::as_str), 24)?;
    let reset_at_ms = value.get("reset_at_ms").and_then(Value::as_u64);
    Some(UsageWindow {
        label,
        utilization,
        reset_at_ms,
    })
}

fn read_omarchy_provider(
    path: &Path,
    expected_id: &str,
    canonical_id: &str,
    label: &str,
) -> ProviderUsage {
    let last_updated_ms = modified_ms(path);
    let stale = stale_by_age(last_updated_ms);
    let value = read_bounded_json(path);
    let Some(value) = value else {
        return unavailable_provider(canonical_id, label, UsageKind::Quota, last_updated_ms);
    };
    let trusted_record = value.get("schemaVersion").and_then(Value::as_u64) == Some(1)
        && value.get("id").and_then(Value::as_str) == Some(expected_id)
        && value.get("ready").and_then(Value::as_bool) == Some(true)
        && value
            .get("usageStatusText")
            .and_then(Value::as_str)
            .is_some_and(|status| status.trim().is_empty());
    if !trusted_record {
        return unavailable_provider(canonical_id, label, UsageKind::Quota, last_updated_ms);
    }

    let windows = value
        .get("limits")
        .and_then(Value::as_array)
        .map(|limits| {
            limits
                .iter()
                .filter_map(omarchy_window)
                .take(2)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let primary = windows.first().cloned();
    let secondary = windows.get(1).cloned();
    if primary.is_none() && secondary.is_none() {
        return unavailable_provider(canonical_id, label, UsageKind::Quota, last_updated_ms);
    }

    ProviderUsage {
        id: canonical_id.into(),
        label: label.into(),
        kind: UsageKind::Quota,
        available: true,
        stale,
        source: "omarchy".into(),
        status: "allowed".into(),
        plan: bounded(value.get("tierLabel").and_then(Value::as_str), 32),
        model: None,
        account_count: None,
        primary,
        secondary,
        today_tokens: aggregate_tokens(value.get("todayTotalTokens")),
        tokens_per_hour: None,
        last_updated_ms,
    }
}

fn omarchy_window(value: &Value) -> Option<UsageWindow> {
    let utilization = numeric(value.get("percent"))?.clamp(0.0, 1.0);
    let label = bounded(value.get("label").and_then(Value::as_str), 24)?;
    let reset_at_ms = value
        .get("resetsAt")
        .and_then(Value::as_str)
        .and_then(parse_rfc3339_ms);
    Some(UsageWindow {
        label,
        utilization,
        reset_at_ms,
    })
}

fn parse_rfc3339_ms(value: &str) -> Option<u64> {
    let timestamp = OffsetDateTime::parse(value, &Rfc3339)
        .ok()?
        .unix_timestamp_nanos();
    u64::try_from(timestamp / 1_000_000).ok()
}

fn read_bounded_json(path: &Path) -> Option<Value> {
    let file = fs::File::open(path).ok()?;
    let metadata = file.metadata().ok()?;
    if !metadata.is_file() || metadata.len() > MAX_CACHE_BYTES {
        return None;
    }
    let mut contents = Vec::with_capacity((metadata.len() as usize).min(MAX_CACHE_BYTES as usize));
    file.take(MAX_CACHE_BYTES.saturating_add(1))
        .read_to_end(&mut contents)
        .ok()?;
    if contents.len() > MAX_CACHE_BYTES as usize {
        return None;
    }
    serde_json::from_slice(&contents).ok()
}

#[derive(Debug)]
struct OpenCodeMessage {
    updated_ms: u64,
    tokens: u64,
    model: Option<String>,
}

fn read_opencode_db(path: &Path) -> ProviderUsage {
    let fallback_updated_ms = modified_ms(path);
    let Some((tokens_5h, tokens_7d, tokens_1h, Some(latest))) = collect_opencode_usage(path) else {
        return unavailable_provider(
            "opencode",
            "OpenCode",
            UsageKind::LocalBudget,
            fallback_updated_ms,
        );
    };
    let last_updated_ms = Some(latest.updated_ms);
    let status = if tokens_5h >= OPENCODE_5H_LIMIT.saturating_mul(9) / 10 {
        "allowed_warning"
    } else {
        "allowed"
    };
    ProviderUsage {
        id: "opencode".into(),
        label: "OpenCode".into(),
        kind: UsageKind::LocalBudget,
        available: true,
        stale: stale_by_age(last_updated_ms),
        source: "sqlite".into(),
        status: status.into(),
        plan: Some("local messages".into()),
        model: latest.model,
        account_count: None,
        primary: Some(UsageWindow {
            label: "5h".into(),
            utilization: (tokens_5h as f64 / OPENCODE_5H_LIMIT as f64).clamp(0.0, 1.0),
            reset_at_ms: None,
        }),
        secondary: Some(UsageWindow {
            label: "Weekly".into(),
            utilization: (tokens_7d as f64 / OPENCODE_7D_LIMIT as f64).clamp(0.0, 1.0),
            reset_at_ms: None,
        }),
        today_tokens: None,
        tokens_per_hour: Some(tokens_1h),
        last_updated_ms,
    }
}

fn collect_opencode_usage(path: &Path) -> Option<(u64, u64, u64, Option<OpenCodeMessage>)> {
    collect_opencode_usage_bounded(path, MAX_OPENCODE_ROWS, OPENCODE_QUERY_BUDGET)
}

fn collect_opencode_usage_bounded(
    path: &Path,
    max_rows: usize,
    query_budget: Duration,
) -> Option<(u64, u64, u64, Option<OpenCodeMessage>)> {
    let connection = Connection::open_with_flags(
        path,
        OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX,
    )
    .ok()?;
    connection.busy_timeout(OPENCODE_BUSY_TIMEOUT).ok()?;
    let deadline = Instant::now().checked_add(query_budget)?;
    connection
        .progress_handler(10_000, Some(move || Instant::now() >= deadline))
        .ok()?;
    let now = now_ms();
    let mut statement = connection
        .prepare(
            "SELECT time_created, time_updated, \
                substr(CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.role') END, 1, 10), \
                substr(CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.modelID') END, 1, 49), \
                substr(CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.providerID') END, 1, 25), \
                CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.tokens.input') END, \
                CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.tokens.output') END, \
                CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.tokens.reasoning') END, \
                CASE WHEN length(CAST(data AS BLOB)) <= ?2 AND json_valid(data) THEN json_extract(data, '$.tokens.cache.write') END \
             FROM message \
             WHERE time_updated >= ?3 OR time_created >= ?3 \
             ORDER BY rowid DESC LIMIT ?1",
        )
        .ok()?;
    let mut rows = statement
        .query(rusqlite::params![
            i64::try_from(max_rows.saturating_add(1)).ok()?,
            i64::try_from(MAX_CACHE_BYTES).ok()?,
            i64::try_from(now.saturating_sub(SEVEN_DAYS_MS)).ok()?
        ])
        .ok()?;
    let mut row_count = 0usize;
    let mut tokens_5h = 0u64;
    let mut tokens_7d = 0u64;
    let mut tokens_1h = 0u64;
    let mut latest = None;
    while let Some(row) = rows.next().ok()? {
        row_count = row_count.saturating_add(1);
        if row_count > max_rows {
            return None;
        }
        let time_created = row.get::<_, i64>(0).ok()?;
        let time_updated = row.get::<_, i64>(1).ok()?;
        let role = row.get::<_, Option<String>>(2).ok()?;
        let model_id = row.get::<_, Option<String>>(3).ok()?;
        let provider_id = row.get::<_, Option<String>>(4).ok()?;
        let token_values = [
            row.get::<_, SqlValue>(5).ok()?,
            row.get::<_, SqlValue>(6).ok()?,
            row.get::<_, SqlValue>(7).ok()?,
            row.get::<_, SqlValue>(8).ok()?,
        ];
        let Some(message) = parse_opencode_scalars(
            time_created,
            time_updated,
            role.as_deref(),
            model_id.as_deref(),
            provider_id.as_deref(),
            &token_values,
        ) else {
            continue;
        };
        if message.updated_ms > now.saturating_add(FRESH_FOR.as_millis() as u64) {
            continue;
        }
        if message.updated_ms < now.saturating_sub(SEVEN_DAYS_MS) {
            continue;
        }
        tokens_7d = bounded_add(tokens_7d, message.tokens)?;
        if message.updated_ms >= now.saturating_sub(FIVE_HOURS_MS) {
            tokens_5h = bounded_add(tokens_5h, message.tokens)?;
        }
        if message.updated_ms >= now.saturating_sub(ONE_HOUR_MS) {
            tokens_1h = bounded_add(tokens_1h, message.tokens)?;
        }
        if latest
            .as_ref()
            .is_none_or(|current: &OpenCodeMessage| message.updated_ms > current.updated_ms)
        {
            latest = Some(message);
        }
    }
    drop(rows);
    drop(statement);

    Some((tokens_5h, tokens_7d, tokens_1h, latest))
}

fn parse_opencode_scalars(
    time_created: i64,
    time_updated: i64,
    role: Option<&str>,
    model_id: Option<&str>,
    provider_id: Option<&str>,
    token_values: &[SqlValue; 4],
) -> Option<OpenCodeMessage> {
    if role != Some("assistant") {
        return None;
    }
    if token_values
        .iter()
        .all(|value| matches!(value, SqlValue::Null))
    {
        return None;
    }
    let model_id = bounded(model_id, 48)?;
    let provider_id = bounded(provider_id, 24);
    let total = token_values
        .iter()
        .map(sql_aggregate_tokens)
        .try_fold(0u64, |total, value| bounded_add(total, value?))?;
    let updated_ms = u64::try_from(time_updated.max(time_created)).ok()?;
    let model_label = provider_id
        .as_ref()
        .map(|provider| format!("{model_id} ({provider})"))
        .unwrap_or(model_id);
    let model = bounded(Some(&model_label), 80);
    Some(OpenCodeMessage {
        updated_ms,
        tokens: total,
        model,
    })
}

fn bounded_add(total: u64, value: u64) -> Option<u64> {
    total
        .checked_add(value)
        .filter(|sum| *sum <= MAX_AGGREGATE_TOKENS)
}

fn sql_aggregate_tokens(value: &SqlValue) -> Option<u64> {
    match value {
        SqlValue::Null => Some(0),
        SqlValue::Integer(value) => u64::try_from(*value)
            .ok()
            .filter(|value| *value <= MAX_AGGREGATE_TOKENS),
        SqlValue::Real(value) => aggregate_number(*value),
        SqlValue::Text(value) => value.parse::<f64>().ok().and_then(aggregate_number),
        SqlValue::Blob(_) => None,
    }
}

fn aggregate_number(value: f64) -> Option<u64> {
    if !value.is_finite() || !(0.0..=MAX_AGGREGATE_TOKENS as f64).contains(&value) {
        return None;
    }
    Some(value.floor() as u64)
}

fn stale_by_age(last_updated_ms: Option<u64>) -> bool {
    last_updated_ms
        .and_then(|updated| now_ms().checked_sub(updated))
        .is_none_or(|age| age > FRESH_FOR.as_millis() as u64)
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

fn aggregate_tokens(value: Option<&Value>) -> Option<u64> {
    let value = numeric(value)?;
    if !(0.0..=MAX_AGGREGATE_TOKENS as f64).contains(&value) {
        return None;
    }
    Some(value.floor() as u64)
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
        account_count: None,
        primary: None,
        secondary: None,
        today_tokens: None,
        tokens_per_hour: None,
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

    fn collector_with_sources(root: &Path) -> UsageCollector {
        UsageCollector {
            legacy_cache_dir: root.join("legacy"),
            state_usage_dir: root.join("state"),
            cliproxy_usage_path: root.join("cliproxy-usage.json"),
            opencode_db: root.join("opencode.db"),
        }
    }

    #[test]
    fn collector_reads_current_omarchy_agent_records() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        fs::create_dir_all(&collector.state_usage_dir).unwrap();
        fs::write(
            collector.state_usage_dir.join("claude.json"),
            r#"{
                "schemaVersion":1,
                "id":"claude",
                "ready":true,
                "tierLabel":"Max 20x",
                "usageStatusText":"",
                "limits":[
                    {"label":"Session (5-hour)","percent":0.08,"resetsAt":"2027-01-15T12:30:00Z"},
                    {"label":"Weekly (7-day)","percent":0.42,"resetsAt":"2027-01-20T00:00:00+00:00"},
                    {"label":"Fable Weekly","percent":0.12,"resetsAt":"2027-01-20T00:00:00Z"}
                ],
                "todayTotalTokens":11619849
            }"#,
        )
        .unwrap();
        fs::write(
            collector.state_usage_dir.join("codex.json"),
            r#"{
                "schemaVersion":1,
                "id":"codex",
                "ready":true,
                "tierLabel":"pro",
                "usageStatusText":"",
                "limits":[{"label":"Weekly (7-day)","percent":0.51,"resetsAt":"2027-01-20T00:00:00Z"}],
                "todayTotalTokens":564291335
            }"#,
        )
        .unwrap();

        let snapshot = collector.sample();
        let claude = &snapshot.providers[0];
        assert!(claude.available);
        assert_eq!(claude.source, "omarchy");
        assert_eq!(claude.plan.as_deref(), Some("Max 20x"));
        assert_eq!(claude.primary.as_ref().unwrap().utilization, 0.08);
        assert_eq!(claude.secondary.as_ref().unwrap().utilization, 0.42);
        assert_eq!(claude.today_tokens, Some(11_619_849));
        assert!(claude.primary.as_ref().unwrap().reset_at_ms.is_some());
        let codex = &snapshot.providers[1];
        assert!(codex.available);
        assert_eq!(codex.primary.as_ref().unwrap().label, "Weekly (7-day)");
        assert_eq!(codex.today_tokens, Some(564_291_335));
    }

    #[test]
    fn unready_or_mismatched_omarchy_records_fail_closed() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        fs::create_dir_all(&collector.state_usage_dir).unwrap();
        fs::create_dir_all(&collector.legacy_cache_dir).unwrap();
        fs::write(
            collector.state_usage_dir.join("claude.json"),
            r#"{"schemaVersion":1,"id":"other","ready":true,"usageStatusText":"","limits":[{"label":"5h","percent":0.1}]}"#,
        )
        .unwrap();
        fs::write(
            collector.legacy_cache_dir.join("claude-usage.json"),
            r#"{"5h-utilization":0.25,"_source":"oauth","status":"allowed"}"#,
        )
        .unwrap();
        fs::write(
            collector.state_usage_dir.join("codex.json"),
            r#"{"schemaVersion":1,"id":"codex","ready":true,"usageStatusText":"Codex unavailable","limits":[{"label":"Weekly","percent":0.5}]}"#,
        )
        .unwrap();

        let snapshot = collector.sample();
        assert!(!snapshot.providers[0].available);
        assert!(snapshot.providers[0].primary.is_none());
        assert!(!snapshot.providers[1].available);
        assert!(snapshot.providers[1].primary.is_none());
    }

    #[test]
    fn collector_recovers_opencode_local_budget_from_read_only_database() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        fs::create_dir_all(&collector.legacy_cache_dir).unwrap();
        fs::write(
            collector.legacy_cache_dir.join("opencode-usage.json"),
            r#"{"5h-utilization":0.9,"_source":"stale","status":"allowed"}"#,
        )
        .unwrap();
        let connection = Connection::open(&collector.opencode_db).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE message (\
                    id TEXT PRIMARY KEY,\
                    session_id TEXT NOT NULL,\
                    time_created INTEGER NOT NULL,\
                    time_updated INTEGER NOT NULL,\
                    data TEXT NOT NULL\
                );",
            )
            .unwrap();
        let recent = now_ms().saturating_sub(30 * 60 * 1_000);
        let older = now_ms().saturating_sub(6 * 60 * 60 * 1_000);
        let future = now_ms().saturating_add(60 * 60 * 1_000);
        connection
            .execute(
                "INSERT INTO message VALUES (?1, 'session-a', ?2, ?2, ?3)",
                rusqlite::params![
                    "recent",
                    recent as i64,
                    r#"{"role":"assistant","modelID":"gpt-test","providerID":"openai","tokens":{"input":100,"output":25,"reasoning":5,"cache":{"write":10,"read":900}}}"#
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO message VALUES (?1, 'session-b', ?2, ?2, ?3)",
                rusqlite::params![
                    "older",
                    older as i64,
                    r#"{"role":"assistant","modelID":"older","providerID":"local","tokens":{"input":200,"output":20}}"#
                ],
            )
            .unwrap();
        connection
            .execute(
                "INSERT INTO message VALUES (?1, 'session-c', ?2, ?2, ?3)",
                rusqlite::params![
                    "future",
                    future as i64,
                    r#"{"role":"assistant","modelID":"future","providerID":"untrusted","tokens":{"input":900000}}"#
                ],
            )
            .unwrap();
        let oversized_prompt = format!(
            r#"{{"role":"user","prompt":"{}"}}"#,
            "x".repeat(MAX_CACHE_BYTES as usize * 16)
        );
        connection
            .execute(
                "INSERT INTO message VALUES (?1, 'session-d', ?2, ?2, ?3)",
                rusqlite::params!["oversized-user", recent as i64, oversized_prompt],
            )
            .unwrap();
        drop(connection);

        let opencode = collector.sample().providers.remove(2);
        assert!(opencode.available);
        assert_eq!(opencode.source, "sqlite");
        assert_eq!(opencode.plan.as_deref(), Some("local messages"));
        assert_eq!(opencode.model.as_deref(), Some("gpt-test (openai)"));
        // Cache reads reuse prior context and are deliberately excluded from
        // the established 1M/20M local soft-budget signal.
        assert_eq!(opencode.primary.as_ref().unwrap().utilization, 0.00014);
        assert_eq!(opencode.secondary.as_ref().unwrap().utilization, 0.000018);
        assert_eq!(opencode.tokens_per_hour, Some(140));
    }

    #[test]
    fn future_only_opencode_database_is_unavailable() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        let connection = Connection::open(&collector.opencode_db).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE message (\
                    id TEXT PRIMARY KEY,\
                    session_id TEXT NOT NULL,\
                    time_created INTEGER NOT NULL,\
                    time_updated INTEGER NOT NULL,\
                    data TEXT NOT NULL\
                );",
            )
            .unwrap();
        let future = now_ms().saturating_add(60 * 60 * 1_000);
        connection
            .execute(
                "INSERT INTO message VALUES ('future', 'session', ?1, ?1, ?2)",
                rusqlite::params![
                    future as i64,
                    r#"{"role":"assistant","modelID":"future","providerID":"untrusted","tokens":{"input":900000}}"#
                ],
            )
            .unwrap();
        drop(connection);

        let opencode = collector.sample().providers.remove(2);
        assert!(!opencode.available);
        assert!(opencode.primary.is_none());
        assert!(opencode.model.is_none());
    }

    #[test]
    fn omarchy_status_must_be_a_present_empty_string() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().join("claude.json");
        for record in [
            r#"{"schemaVersion":1,"id":"claude","ready":true,"limits":[{"label":"5h","percent":0.1}]}"#,
            r#"{"schemaVersion":1,"id":"claude","ready":true,"usageStatusText":42,"limits":[{"label":"5h","percent":0.1}]}"#,
            r#"{"schemaVersion":1,"id":"claude","ready":true,"usageStatusText":{},"limits":[{"label":"5h","percent":0.1}]}"#,
        ] {
            fs::write(&path, record).unwrap();
            let provider = read_omarchy_provider(&path, "claude", "claude", "Claude");
            assert!(!provider.available);
            assert!(provider.primary.is_none());
        }
    }

    #[test]
    fn opencode_database_fails_closed_when_the_row_budget_is_exceeded() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("opencode.db");
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE message (\
                    id TEXT PRIMARY KEY,\
                    session_id TEXT NOT NULL,\
                    time_created INTEGER NOT NULL,\
                    time_updated INTEGER NOT NULL,\
                    data TEXT NOT NULL\
                );",
            )
            .unwrap();
        let recent = now_ms().saturating_sub(1_000);
        for index in 0..3 {
            connection
                .execute(
                    "INSERT INTO message VALUES (?1, 'session', ?2, ?2, ?3)",
                    rusqlite::params![
                        format!("message-{index}"),
                        recent as i64,
                        r#"{"role":"assistant","modelID":"bounded","tokens":{"input":1}}"#
                    ],
                )
                .unwrap();
        }
        drop(connection);

        assert!(collect_opencode_usage_bounded(&database, 2, Duration::from_secs(1)).is_none());
    }

    #[test]
    fn old_opencode_history_does_not_consume_the_recent_row_budget() {
        let temp = tempfile::tempdir().unwrap();
        let database = temp.path().join("opencode.db");
        let connection = Connection::open(&database).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE message (\
                    id TEXT PRIMARY KEY,\
                    session_id TEXT NOT NULL,\
                    time_created INTEGER NOT NULL,\
                    time_updated INTEGER NOT NULL,\
                    data TEXT NOT NULL\
                );",
            )
            .unwrap();
        let old = now_ms().saturating_sub(SEVEN_DAYS_MS + 1_000);
        let recent = now_ms().saturating_sub(1_000);
        for index in 0..3 {
            connection
                .execute(
                    "INSERT INTO message VALUES (?1, 'old-session', ?2, ?2, ?3)",
                    rusqlite::params![
                        format!("old-{index}"),
                        old as i64,
                        r#"{"role":"assistant","modelID":"old","tokens":{"input":1}}"#
                    ],
                )
                .unwrap();
        }
        connection
            .execute(
                "INSERT INTO message VALUES ('recent', 'recent-session', ?1, ?1, ?2)",
                rusqlite::params![
                    recent as i64,
                    r#"{"role":"assistant","modelID":"recent","tokens":{"input":7}}"#
                ],
            )
            .unwrap();
        drop(connection);

        let aggregate =
            collect_opencode_usage_bounded(&database, 2, Duration::from_secs(1)).unwrap();
        assert_eq!((aggregate.0, aggregate.1, aggregate.2), (7, 7, 7));
        assert_eq!(aggregate.3.unwrap().model.as_deref(), Some("recent"));
    }

    #[test]
    fn empty_opencode_database_uses_a_valid_legacy_record() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        fs::create_dir_all(&collector.legacy_cache_dir).unwrap();
        fs::write(
            collector.legacy_cache_dir.join("opencode-usage.json"),
            r#"{"5h-utilization":0.2,"_source":"sqlite","status":"allowed"}"#,
        )
        .unwrap();
        let connection = Connection::open(&collector.opencode_db).unwrap();
        connection
            .execute_batch(
                "CREATE TABLE message (\
                    id TEXT PRIMARY KEY,\
                    session_id TEXT NOT NULL,\
                    time_created INTEGER NOT NULL,\
                    time_updated INTEGER NOT NULL,\
                    data TEXT NOT NULL\
                );",
            )
            .unwrap();
        drop(connection);

        let opencode = collector.sample().providers.remove(2);
        assert!(opencode.available);
        assert_eq!(opencode.source, "sqlite");
        assert_eq!(opencode.primary.as_ref().unwrap().utilization, 0.2);
    }

    #[test]
    fn collector_normalizes_capacity_and_bounded_aggregate_activity() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("claude-usage.json"),
            r#"{"5h-utilization":"0.25","5h-reset":"1800000000","7d-utilization":"0.5","7d-reset":"1800100000","_source":"oauth","status":"allowed","_today_tokens":999,"_rate_per_hour":"125.9"}"#,
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

        let snapshot = UsageCollector::legacy_only(temp.path()).sample();
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
        assert_eq!(snapshot.providers[0].today_tokens, Some(999));
        assert_eq!(snapshot.providers[0].tokens_per_hour, Some(125));
        let encoded = serde_json::to_string(&snapshot).unwrap();
        assert!(encoded.contains("\"today_tokens\":999"));
        assert!(encoded.contains("\"tokens_per_hour\":125"));
        assert!(!encoded.contains("_models"));
    }

    #[test]
    fn absent_files_remain_explicitly_unavailable() {
        let temp = tempfile::tempdir().unwrap();
        let snapshot = UsageCollector::legacy_only(temp.path()).sample();
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
            r#"{"5h-utilization":"0.25","_source":"oauth","status":"blocked","_plan":"injected-plan","_model":"injected-model","_today_tokens":123,"_rate_per_hour":45}"#,
        )
        .unwrap();
        fs::write(
            temp.path().join("codex-usage.json"),
            r#"{"windows":[{"label":"Weekly","utilization":0.9}],"_source":"mystery","status":"allowed"}"#,
        )
        .unwrap();

        let snapshot = UsageCollector::legacy_only(temp.path()).sample();
        let claude = &snapshot.providers[0];
        assert_eq!(claude.status, "blocked");
        assert!(!claude.available);
        assert!(claude.stale);
        assert_eq!(claude.plan, None);
        assert_eq!(claude.model, None);
        assert!(claude.primary.is_none());
        assert_eq!(claude.today_tokens, None);
        assert_eq!(claude.tokens_per_hour, None);
        let codex = &snapshot.providers[1];
        assert_eq!(codex.source, "unknown");
        assert!(!codex.available);
        assert!(codex.stale);
        assert!(codex.primary.is_none());
    }

    #[test]
    fn aggregate_activity_rejects_negative_non_finite_and_oversized_values() {
        let temp = tempfile::tempdir().unwrap();
        fs::write(
            temp.path().join("claude-usage.json"),
            format!(
                r#"{{"5h-utilization":"0.25","_source":"oauth","status":"allowed","_today_tokens":-1,"_rate_per_hour":{}}}"#,
                MAX_AGGREGATE_TOKENS + 1
            ),
        )
        .unwrap();

        let snapshot = UsageCollector::legacy_only(temp.path()).sample();
        let claude = &snapshot.providers[0];
        assert!(claude.available);
        assert_eq!(claude.today_tokens, None);
        assert_eq!(claude.tokens_per_hour, None);
        assert_eq!(aggregate_tokens(Some(&Value::String("NaN".into()))), None);
    }

    #[test]
    fn collector_merges_cliproxy_and_additional_omarchy_agents() {
        let temp = tempfile::tempdir().unwrap();
        let collector = collector_with_sources(temp.path());
        fs::create_dir_all(&collector.state_usage_dir).unwrap();
        // Local Claude is waiting for auth while CLIProxyAPI has 2 active Max accounts.
        fs::write(
            collector.state_usage_dir.join("claude.json"),
            r#"{"schemaVersion":1,"id":"claude","ready":true,"usageStatusText":"Waiting for auth","limits":[]}"#,
        )
        .unwrap();
        fs::write(
            collector.state_usage_dir.join("codex.json"),
            r#"{"schemaVersion":1,"id":"codex","ready":true,"tierLabel":"Pro 500","usageStatusText":"","limits":[{"label":"Weekly (7-day)","percent":0.02}]}"#,
        )
        .unwrap();
        fs::write(
            collector.state_usage_dir.join("agy.json"),
            r#"{"schemaVersion":1,"id":"agy","ready":true,"tierLabel":"Ultra","usageStatusText":"","limits":[{"label":"Session (5-hour)","percent":0.14}],"todayTotalTokens":186629}"#,
        )
        .unwrap();
        fs::write(
            collector.state_usage_dir.join("grok.json"),
            r#"{"schemaVersion":1,"id":"grok","ready":true,"tierLabel":"SuperGrok Heavy","usageStatusText":"","limits":[{"label":"Weekly","percent":0.0}],"todayTotalTokens":374451}"#,
        )
        .unwrap();
        fs::write(
            &collector.cliproxy_usage_path,
            serde_json::to_string(&serde_json::json!({
                "schema_version": 1,
                "generated_at_ms": now_ms(),
                "providers": [
                    {
                        "id": "claude",
                        "label": "Claude",
                        "plan": "Max",
                        "account_count": 2,
                        "status": "allowed",
                        "primary": {"label": "Weekly", "utilization": 0.09, "reset_at_ms": 1800000000000u64},
                        "secondary": {"label": "Fable 5 weekly", "utilization": 0.165, "reset_at_ms": 1800000000000u64},
                        "today_tokens": 2500000
                    }
                ]
            }))
            .unwrap(),
        )
        .unwrap();

        let snapshot = collector.sample();
        let ids: Vec<&str> = snapshot.providers.iter().map(|p| p.id.as_str()).collect();
        assert_eq!(ids, vec!["claude", "codex", "gemini", "grok"]);
        assert_eq!(snapshot.providers[0].source, "cliproxy");
        assert_eq!(snapshot.providers[0].account_count, Some(2));
        assert_eq!(snapshot.providers[0].plan.as_deref(), Some("Max"));
        assert_eq!(snapshot.providers[0].today_tokens, Some(2_500_000));
        assert_eq!(snapshot.providers[2].source, "omarchy");
        assert_eq!(snapshot.providers[2].plan.as_deref(), Some("Ultra"));
        assert_eq!(snapshot.providers[3].today_tokens, Some(374_451));
    }
}
