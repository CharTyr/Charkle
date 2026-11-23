//! External Agent policy store & 14-tool MCP/CLI service.

pub mod policy;
pub mod service;

pub use policy::{resolve_default_data_dir, ExternalAgentConfigStore, EXTERNAL_AGENT_CONFIG_FILE};
pub use service::{
    CharkleExternalAgentService, ToolContent, ToolOutput, WriteWakeHook, READ_TOOL_NAMES,
    WRITE_TOOL_NAMES,
};
