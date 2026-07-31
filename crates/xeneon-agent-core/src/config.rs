use std::{
    env, fs,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub herdr_bin: PathBuf,
    pub voxtype_bin: PathBuf,
    pub herdr_refresh_ms: u64,
    pub health_refresh_ms: u64,
    pub voice_refresh_ms: u64,
    pub usage_refresh_ms: u64,
    pub micro_refresh_ms: u64,
    pub screen: ScreenConfig,
    pub desktop: DesktopConfig,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct ScreenConfig {
    pub connector: Option<String>,
    pub serial: Option<String>,
    pub model: Option<String>,
    pub touch_device: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct DesktopConfig {
    pub edge_output: Option<String>,
    pub herdr_class: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            herdr_bin: PathBuf::from("herdr"),
            voxtype_bin: PathBuf::from("voxtype"),
            herdr_refresh_ms: 5_000,
            health_refresh_ms: 1_000,
            voice_refresh_ms: 250,
            usage_refresh_ms: 30_000,
            micro_refresh_ms: 5_000,
            screen: ScreenConfig::default(),
            desktop: DesktopConfig::default(),
        }
    }
}

impl Default for DesktopConfig {
    fn default() -> Self {
        Self {
            edge_output: None,
            herdr_class: "herdr".into(),
        }
    }
}

impl Config {
    pub fn load(path: Option<&Path>) -> Result<Self> {
        let path = path.map(PathBuf::from).or_else(default_config_path);
        let Some(path) = path else {
            return Ok(Self::default());
        };
        if !path.exists() {
            return Ok(Self::default());
        }

        let contents = fs::read_to_string(&path)
            .with_context(|| format!("reading config {}", path.display()))?;
        toml::from_str(&contents).with_context(|| format!("parsing config {}", path.display()))
    }

    pub fn herdr_refresh_interval(&self) -> Duration {
        Duration::from_millis(self.herdr_refresh_ms.max(250))
    }

    pub fn health_refresh_interval(&self) -> Duration {
        Duration::from_millis(self.health_refresh_ms.max(250))
    }

    pub fn voice_refresh_interval(&self) -> Duration {
        Duration::from_millis(self.voice_refresh_ms.max(250))
    }

    pub fn usage_refresh_interval(&self) -> Duration {
        Duration::from_millis(self.usage_refresh_ms.max(5_000))
    }

    pub fn micro_refresh_interval(&self) -> Duration {
        Duration::from_millis(self.micro_refresh_ms.max(1_000))
    }

    pub fn validate(&self) -> Result<()> {
        let screen_identity = [
            ("screen.connector", self.screen.connector.as_deref()),
            ("screen.serial", self.screen.serial.as_deref()),
            ("screen.model", self.screen.model.as_deref()),
            ("screen.touch_device", self.screen.touch_device.as_deref()),
        ];
        for (name, value) in screen_identity {
            if value.is_some_and(|value| value.trim().is_empty()) {
                anyhow::bail!("{name} must not be empty");
            }
        }
        let configured_identity_fields = screen_identity
            .iter()
            .filter(|(_, value)| value.is_some())
            .count();
        if configured_identity_fields != 0 && configured_identity_fields != screen_identity.len() {
            anyhow::bail!(
                "screen identity must configure connector, serial, model, and touch_device together"
            );
        }
        if self
            .desktop
            .edge_output
            .as_deref()
            .is_some_and(|value| value.trim().is_empty())
        {
            anyhow::bail!("desktop.edge_output must not be empty");
        }
        if self.desktop.edge_output.is_some() && configured_identity_fields == 0 {
            anyhow::bail!("desktop.edge_output requires a complete screen identity");
        }
        if configured_identity_fields == screen_identity.len()
            && self.desktop.edge_output.as_deref() != self.screen.connector.as_deref()
        {
            anyhow::bail!("desktop.edge_output must match screen.connector");
        }
        if self.herdr_bin.as_os_str().is_empty() {
            anyhow::bail!("herdr_bin must not be empty");
        }
        if self.voxtype_bin.as_os_str().is_empty() {
            anyhow::bail!("voxtype_bin must not be empty");
        }
        if self.desktop.herdr_class.trim().is_empty() {
            anyhow::bail!("desktop.herdr_class must not be empty");
        }
        if self.herdr_refresh_ms < 250
            || self.health_refresh_ms < 250
            || self.voice_refresh_ms < 250
            || self.usage_refresh_ms < 5_000
            || self.micro_refresh_ms < 1_000
        {
            anyhow::bail!("refresh intervals are below their safe minimum");
        }
        Ok(())
    }
}

fn default_config_path() -> Option<PathBuf> {
    env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))
        .map(|root| root.join("xeneon-edge-agents/config.toml"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_explicit_config_uses_defaults() {
        let temp = tempfile::tempdir().unwrap();
        let config = Config::load(Some(&temp.path().join("missing.toml"))).unwrap();
        assert_eq!(config.herdr_refresh_ms, 5_000);
    }

    #[test]
    fn config_rejects_unsafe_poll_rate() {
        let config = Config {
            health_refresh_ms: 10,
            ..Config::default()
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn partial_screen_identity_is_rejected() {
        let mut config = Config::default();
        config.screen.connector = Some("DP-1".into());
        assert!(config.validate().is_err());
    }

    #[test]
    fn complete_screen_identity_requires_matching_desktop_output() {
        let mut config = Config {
            screen: ScreenConfig {
                connector: Some("DP-1".into()),
                serial: Some("CX123".into()),
                model: Some("XENEON EDGE".into()),
                touch_device: Some("corsair-xeneon-edge-touchscreen".into()),
            },
            ..Config::default()
        };
        config.desktop.edge_output = Some("DP-2".into());
        assert!(config.validate().is_err());

        config.desktop.edge_output = Some("DP-1".into());
        assert!(config.validate().is_ok());
    }
}
