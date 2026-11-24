//! External Agent policy store & 20-tool MCP v2 / CLI service.

pub mod policy;
pub mod service;

pub use policy::{resolve_default_data_dir, ExternalAgentConfigStore, EXTERNAL_AGENT_CONFIG_FILE};
pub use service::{
    CharkleExternalAgentService, ToolContent, ToolOutput, WriteWakeHook, READ_TOOL_NAMES,
    SUPPORTED_PROTOCOL_VERSIONS, WRITE_TOOL_NAMES,
};
