//! External Agent policy models mirroring `Sources/CharkleCore/Intelligence/ExternalAgentPolicy.swift`.

use serde::{Deserialize, Deserializer, Serialize, Serializer};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExternalAgentAccessLevel {
    #[default]
    ReadOnly,
    ReadWriteOrganize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ExternalAgentChannel {
    Mcp,
    Cli,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ExternalAgentConfig {
    pub mcp_enabled: bool,
    pub cli_enabled: bool,
    pub access_level: ExternalAgentAccessLevel,
}

impl Default for ExternalAgentConfig {
    fn default() -> Self {
        Self {
            mcp_enabled: true,
            cli_enabled: true,
            access_level: ExternalAgentAccessLevel::ReadOnly,
        }
    }
}

impl ExternalAgentConfig {
    pub fn enabled(&self) -> bool {
        self.mcp_enabled || self.cli_enabled
    }

    pub fn is_enabled(&self, channel: ExternalAgentChannel) -> bool {
        match channel {
            ExternalAgentChannel::Mcp => self.mcp_enabled,
            ExternalAgentChannel::Cli => self.cli_enabled,
        }
    }

    pub fn allows_read(&self, channel: ExternalAgentChannel) -> bool {
        self.is_enabled(channel)
    }

    pub fn allows_write(&self, channel: ExternalAgentChannel) -> bool {
        self.is_enabled(channel) && self.access_level == ExternalAgentAccessLevel::ReadWriteOrganize
    }
}

#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExternalAgentConfigWire {
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    mcp_enabled: Option<bool>,
    #[serde(default)]
    cli_enabled: Option<bool>,
    #[serde(default)]
    access_level: Option<ExternalAgentAccessLevel>,
}

impl Serialize for ExternalAgentConfig {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        ExternalAgentConfigWire {
            enabled: Some(self.enabled()),
            mcp_enabled: Some(self.mcp_enabled),
            cli_enabled: Some(self.cli_enabled),
            access_level: Some(self.access_level),
        }
        .serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for ExternalAgentConfig {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let raw = ExternalAgentConfigWire::deserialize(deserializer)?;
        let legacy_enabled = raw.enabled.unwrap_or(true);
        Ok(Self {
            mcp_enabled: raw.mcp_enabled.unwrap_or(legacy_enabled),
            cli_enabled: raw.cli_enabled.unwrap_or(legacy_enabled),
            access_level: raw
                .access_level
                .unwrap_or(ExternalAgentAccessLevel::ReadOnly),
        })
    }
}
