use std::{
    env,
    path::PathBuf,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};
use tokio::{
    io::{AsyncBufReadExt, AsyncWriteExt, BufReader},
    net::UnixStream,
    time::timeout,
};

use crate::model::MicroSnapshot;

const STATUS_TIMEOUT: Duration = Duration::from_millis(1_200);

#[derive(Debug, Clone)]
pub struct MicroCollector {
    socket_path: PathBuf,
}

impl Default for MicroCollector {
    fn default() -> Self {
        let runtime = env::var_os("XDG_RUNTIME_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/run/user/0"));
        Self {
            socket_path: runtime.join("microd/microd.sock"),
        }
    }
}

impl MicroCollector {
    pub fn new(socket_path: impl Into<PathBuf>) -> Self {
        Self {
            socket_path: socket_path.into(),
        }
    }

    pub async fn sample(&self) -> MicroSnapshot {
        self.sample_with_timeout(STATUS_TIMEOUT).await
    }

    async fn sample_with_timeout(&self, status_timeout: Duration) -> MicroSnapshot {
        let Ok(Ok(stream)) = timeout(status_timeout, UnixStream::connect(&self.socket_path)).await
        else {
            return MicroSnapshot::default();
        };
        timeout(status_timeout, self.sample_stream(stream))
            .await
            .ok()
            .and_then(Result::ok)
            .unwrap_or_default()
    }

    async fn sample_stream(&self, stream: UnixStream) -> anyhow::Result<MicroSnapshot> {
        let (read, mut write) = stream.into_split();
        write
            .write_all(
                serde_json::to_string(&json!({
                    "id": "xeneon-agentd-status",
                    "cmd": "raw",
                    "method": "device.status",
                    "params": {}
                }))?
                .as_bytes(),
            )
            .await?;
        write.write_all(b"\n").await?;
        write.flush().await?;

        let mut lines = BufReader::new(read).lines();
        while let Some(line) = lines.next_line().await? {
            let Ok(value) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            if let Some(snapshot) = status_from_message(&value) {
                return Ok(snapshot);
            }
        }
        anyhow::bail!("microd disconnected before device.status")
    }
}

fn status_from_message(value: &Value) -> Option<MicroSnapshot> {
    if value.get("event").and_then(Value::as_str) != Some("device_message") {
        return None;
    }
    let message = value.get("message")?;
    if message.get("method").and_then(Value::as_str) != Some("device.status") {
        return None;
    }
    let result = message.get("result")?.as_object()?;
    let firmware: String = result
        .get("version")
        .and_then(Value::as_str)?
        .trim()
        .trim_start_matches('v')
        .chars()
        .take(32)
        .collect();
    if firmware.is_empty() {
        return None;
    }
    Some(MicroSnapshot {
        connected: true,
        firmware: Some(firmware),
        battery: result
            .get("battery")
            .and_then(Value::as_u64)
            .map(|battery| battery.min(100) as u8),
        charging: result
            .get("is_charging")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        layer: result
            .get("layer_index")
            .and_then(Value::as_u64)
            .and_then(|layer| u8::try_from(layer).ok()),
        profile: result
            .get("profile_index")
            .and_then(Value::as_u64)
            .and_then(|profile| u8::try_from(profile).ok()),
        last_updated_ms: Some(now_ms()),
    })
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
    fn device_status_is_normalized_without_exposing_raw_messages() {
        let value = json!({
            "event": "device_message",
            "message": {
                "method": "device.status",
                "result": {
                    "version": "v0.4.1",
                    "battery": 46,
                    "is_charging": false,
                    "layer_index": 1,
                    "profile_index": 0
                }
            }
        });
        let status = status_from_message(&value).unwrap();
        assert!(status.connected);
        assert_eq!(status.firmware.as_deref(), Some("0.4.1"));
        assert_eq!(status.battery, Some(46));
        assert_eq!(status.layer, Some(1));
        assert_eq!(status.profile, Some(0));
    }

    #[test]
    fn unrelated_device_messages_are_ignored() {
        assert!(status_from_message(&json!({"id": 1, "ok": true})).is_none());
        assert!(
            status_from_message(&json!({
                "event": "device_message",
                "message": {"method": "sys.version", "result": {}}
            }))
            .is_none()
        );
        for malformed in [Value::Null, json!("not-an-object"), json!({})] {
            assert!(
                status_from_message(&json!({
                    "event": "device_message",
                    "message": {
                        "method": "device.status",
                        "result": malformed
                    }
                }))
                .is_none()
            );
        }
    }

    #[tokio::test]
    async fn socket_without_verified_device_status_stays_disconnected() {
        let temp = tempfile::tempdir().unwrap();
        let socket_path = temp.path().join("microd.sock");
        let listener = tokio::net::UnixListener::bind(&socket_path).unwrap();
        let server = tokio::spawn(async move {
            let (_stream, _) = listener.accept().await.unwrap();
            tokio::time::sleep(Duration::from_millis(100)).await;
        });

        let snapshot = MicroCollector::new(socket_path)
            .sample_with_timeout(Duration::from_millis(20))
            .await;

        assert!(!snapshot.connected);
        assert!(snapshot.battery.is_none());
        server.abort();
    }
}
