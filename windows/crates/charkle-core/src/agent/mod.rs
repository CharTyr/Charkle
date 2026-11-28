//! External Agent Pure MCP v2 policy store, run rollback journal & 10-tool MCP service.

pub mod policy;
pub mod run_store;
pub mod service;

pub use policy::{resolve_default_data_dir, ExternalAgentConfigStore, EXTERNAL_AGENT_CONFIG_FILE};
pub use run_store::{
    AgentAssetSnapshot, AgentCurationSession, AgentFolderSnapshot, AgentRunRecord,
    ExternalAgentStateStore,
};
pub use service::{
    CharkleExternalAgentService, ToolContent, ToolOutput, WriteWakeHook, READ_TOOL_NAMES,
    SERVER_VERSION, SUPPORTED_PROTOCOL_VERSIONS, WRITE_TOOL_NAMES,
};
