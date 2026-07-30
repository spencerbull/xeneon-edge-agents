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
    pub herdr_refresh_ms: u64,
    pub health_refresh_ms: u64,
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
            herdr_refresh_ms: 5_000,
            health_refresh_ms: 1_000,
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

    pub fn validate(&self) -> Result<()> {
        if self.screen.connector.as_deref() == Some("") {
            anyhow::bail!("screen.connector must not be empty");
        }
        if self.screen.touch_device.as_deref() == Some("") {
            anyhow::bail!("screen.touch_device must not be empty");
        }
        if self.herdr_refresh_ms < 250 || self.health_refresh_ms < 250 {
            anyhow::bail!("refresh intervals must be at least 250ms");
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
}
