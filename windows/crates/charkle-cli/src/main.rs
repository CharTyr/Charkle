//! Native Windows `charkle-cli.exe` binary powering BOTH:
//! - MCP v2 Server over JSON-RPC 2.0 stdio (`charkle-cli.exe mcp`, supporting NDJSON & `Content-Length` framing + batch arrays)
//! - Grounded CLI subcommands (`status`, `doctor`, `overview`, `inbox`, `search`, `semantic-search`,
//!   `similar`, `jump`, `suggest-folder`, `asset`, `contact-sheet`, `boards`, `board`, `export-board`,
//!   `organize`, `create-folder`, `update-folder`, `folder`, `ingest`, `compose-board`, `patch-board`,
//!   `trash`, `analyze`, `completions`)
//!
//! Opens `Library.sqlite3` directly in SQLite WAL mode, enforces `ExternalAgentConfig`
//! (`mcpEnabled`, `cliEnabled`, `readOnly` / `readWriteOrganize`, soft-trash only), and
//! signals any running `charkle-desktop.exe` via `Local\CharkleLibraryChanged`.

use std::io::{self, BufRead, BufReader, Read, Write};
use std::path::PathBuf;
use std::sync::Arc;

use charkle_core::agent::{
    resolve_default_data_dir, CharkleExternalAgentService, ExternalAgentConfigStore,
    READ_TOOL_NAMES, SUPPORTED_PROTOCOL_VERSIONS, WRITE_TOOL_NAMES,
};
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::models::agent::ExternalAgentChannel;
use charkle_platform_win::wake::pulse_library_changed;
use clap::{Parser, Subcommand};
use serde_json::{json, Value};

#[derive(Debug, Parser)]
#[command(
    name = "charkle-cli",
    version = "1.2.0",
    about = "Charkle Windows Native CLI & MCP v2 Server"
)]
struct Cli {
    /// Override Charkle library data directory (defaults to AppData / CHARKLE_LIBRARY_DIR).
    #[arg(long, global = true)]
    library_dir: Option<PathBuf>,

    /// Emit raw JSON output where applicable.
    #[arg(long, global = true)]
    json: bool,

    /// Emit compact single-line JSON output.
    #[arg(long, global = true)]
    compact: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum FolderSubcommand {
    /// List all folders with paths and counts.
    List,
    /// [Write] Create a new folder.
    Create {
        name: String,
        #[arg(long)]
        parent_id: Option<String>,
        #[arg(long)]
        parent_path: Option<String>,
        #[arg(long)]
        color: Option<String>,
    },
    /// [Write] Rename an existing folder.
    Rename {
        id_or_path: String,
        new_name: String,
    },
    /// [Write] Move an existing folder under a new parent or to root.
    Move {
        id_or_path: String,
        #[arg(long)]
        parent_id: Option<String>,
        #[arg(long)]
        parent_path: Option<String>,
        #[arg(long)]
        root: bool,
    },
    /// [Write] Update folder name, parent, color, or symbol.
    Update {
        id_or_path: String,
        #[arg(long)]
        new_name: Option<String>,
        #[arg(long)]
        parent_id: Option<String>,
        #[arg(long)]
        parent_path: Option<String>,
        #[arg(long)]
        root: bool,
        #[arg(long)]
        color: Option<String>,
        #[arg(long)]
        symbol: Option<String>,
    },
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Print CLI readiness, library directory, and active External Agent policy.
    Status,
    /// Run environment, database, permissions, and MCP v2 capability diagnostics.
    Doctor,
    /// Run JSON-RPC 2.0 Model Context Protocol (MCP v2) server on stdio.
    Mcp,
    /// Show library overview (folders, smart folders, top tags, asset & board counts).
    Overview,
    /// List newest items waiting in Inbox.
    Inbox {
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 40)]
        limit: u64,
    },
    /// Search visual references by query, tags, color, or folder.
    Search {
        #[arg(default_value = "")]
        query: String,
        #[arg(long = "tag")]
        tags: Vec<String>,
        #[arg(long)]
        color: Option<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long)]
        include_subfolders: bool,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 30)]
        limit: u64,
    },
    /// Hybrid semantic + keyword search across the library.
    SemanticSearch {
        query: String,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long, default_value_t = 20)]
        limit: u64,
    },
    /// Find visually similar assets to a reference asset UUID.
    Similar {
        asset_id: String,
        #[arg(long, default_value_t = 12)]
        limit: u64,
    },
    /// Unified fast fuzzy jump across folders, moodboards, tags, and assets.
    Jump {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: u64,
    },
    /// Recommend best folders for one or more asset UUIDs.
    SuggestFolder {
        #[arg(long = "id", required = true)]
        asset_ids: Vec<String>,
    },
    /// Inspect full metadata for one asset UUID.
    Asset { id: String },
    /// Render up to 16 asset thumbnails into a numbered JPEG contact sheet.
    ContactSheet {
        #[arg(long = "id")]
        asset_ids: Vec<String>,
        #[arg(long)]
        query: Option<String>,
        #[arg(long, default_value_t = 4)]
        columns: u64,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long)]
        output: Option<PathBuf>,
    },
    /// List all moodboards.
    Boards,
    /// Inspect nodes and palette of a moodboard by UUID or title.
    Board { id_or_title: String },
    /// Export a moodboard to PNG or JPEG.
    ExportBoard {
        id_or_title: String,
        #[arg(long, default_value = "png")]
        format: String,
        #[arg(long, default_value_t = 1.0)]
        scale: f64,
        #[arg(long)]
        output: PathBuf,
    },
    /// [Write] Move/tag/rate assets.
    Organize {
        #[arg(long = "id", required = true)]
        asset_ids: Vec<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long)]
        inbox: bool,
        #[arg(long = "add-tag")]
        add_tags: Vec<String>,
        #[arg(long = "remove-tag")]
        remove_tags: Vec<String>,
        #[arg(long)]
        rating: Option<i64>,
        #[arg(long)]
        ai_description: Option<String>,
    },
    /// [Write] Create a new folder.
    CreateFolder {
        name: String,
        #[arg(long)]
        parent_id: Option<String>,
    },
    /// [Write] Update a folder (rename, move, color, symbol; never delete).
    UpdateFolder {
        id_or_path: String,
        #[arg(long)]
        new_name: Option<String>,
        #[arg(long)]
        parent_id: Option<String>,
        #[arg(long)]
        root: bool,
        #[arg(long)]
        color: Option<String>,
    },
    /// Hierarchical folder operations (list / create / rename / move / update).
    Folder {
        #[command(subcommand)]
        action: FolderSubcommand,
    },
    /// [Write] Ingest a file path, URL, color hex, or text snippet.
    Ingest {
        #[arg(long)]
        file: Option<PathBuf>,
        #[arg(long)]
        url: Option<String>,
        #[arg(long)]
        color: Option<String>,
        #[arg(long)]
        text: Option<String>,
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long = "tag")]
        tags: Vec<String>,
    },
    /// [Write] Compose a moodboard from prompt or explicit asset UUIDs.
    ComposeBoard {
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long = "id")]
        asset_ids: Vec<String>,
        #[arg(long, default_value = "magazine")]
        style: String,
        #[arg(long)]
        freeform: bool,
    },
    /// [Write] Patch an existing moodboard (rename, add/remove unlocked assets, add section/note).
    PatchBoard {
        id_or_title: String,
        #[arg(long)]
        new_title: Option<String>,
        #[arg(long = "add-id")]
        add_ids: Vec<String>,
        #[arg(long = "remove-id")]
        remove_ids: Vec<String>,
        #[arg(long)]
        section: Option<String>,
        #[arg(long)]
        note: Option<String>,
    },
    /// [Write] Soft-move assets to Trash (or --restore). Permanent delete is never permitted.
    Trash {
        #[arg(long = "id", required = true)]
        asset_ids: Vec<String>,
        #[arg(long)]
        restore: bool,
    },
    /// [Write] Hydrate EXIF, AI prompts, OCR, and optional live rich metadata for up to 20 assets.
    Analyze {
        #[arg(long = "id", required = true)]
        asset_ids: Vec<String>,
        #[arg(long)]
        refresh_rich: bool,
    },
    /// Print shell completion script (`powershell`, `bash`, `zsh`).
    Completions {
        #[arg(default_value = "powershell")]
        shell: String,
    },
}

#[tokio::main]
async fn main() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    let cli = Cli::parse();
    let data_dir = cli.library_dir.unwrap_or_else(resolve_default_data_dir);

    if let Some(Commands::Completions { shell }) = &cli.command {
        print_completions(shell);
        return;
    }

    if matches!(
        cli.command,
        None | Some(Commands::Status) | Some(Commands::Doctor)
    ) {
        let policy = ExternalAgentConfigStore::load(&data_dir);
        let db_path = data_dir.join("Library.sqlite3");
        let status = json!({
            "name": "charkle-cli",
            "version": "1.2.0",
            "protocolVersions": SUPPORTED_PROTOCOL_VERSIONS,
            "libraryDir": data_dir.display().to_string(),
            "databasePath": db_path.display().to_string(),
            "databaseExists": db_path.exists(),
            "mcpEnabled": policy.mcp_enabled,
            "cliEnabled": policy.cli_enabled,
            "accessLevel": policy.access_level,
            "readToolCount": READ_TOOL_NAMES.len(),
            "writeToolCount": WRITE_TOOL_NAMES.len(),
            "resourceCount": 6,
            "promptCount": 4
        });
        if cli.json || cli.compact || matches!(cli.command, Some(Commands::Doctor)) {
            let rendered = if cli.compact {
                serde_json::to_string(&status).unwrap_or_else(|_| "{}".to_string())
            } else {
                serde_json::to_string_pretty(&status).unwrap_or_else(|_| "{}".to_string())
            };
            println!("{rendered}");
        } else {
            println!(
                "charkle-cli 1.2.0 (MCP v2: {} read / {} write tools) | library={} | mcp={} | cli={} | access={:?}",
                READ_TOOL_NAMES.len(),
                WRITE_TOOL_NAMES.len(),
                data_dir.display(),
                policy.mcp_enabled,
                policy.cli_enabled,
                policy.access_level
            );
        }
        return;
    }

    let engine = match LiveCharkleEngine::open(&data_dir) {
        Ok(e) => Arc::new(e),
        Err(err) => {
            eprintln!(
                "Failed to open Charkle library at {}: {err}",
                data_dir.display()
            );
            std::process::exit(1);
        }
    };

    let wake_dir = data_dir.clone();
    let service = CharkleExternalAgentService::new(
        engine,
        data_dir,
        Some(Arc::new(move |_kind| {
            pulse_library_changed(Some(&wake_dir));
        })),
    );

    let cmd = cli.command.unwrap_or(Commands::Status);
    if matches!(cmd, Commands::Mcp) {
        run_mcp_stdio(&service).await;
        return;
    }

    let (tool_name, args) = match cmd {
        Commands::Overview => ("library_overview", json!({})),
        Commands::Inbox { offset, limit } => {
            ("list_inbox", json!({ "offset": offset, "limit": limit }))
        }
        Commands::Search {
            query,
            tags,
            color,
            folder,
            include_subfolders,
            offset,
            limit,
        } => (
            "search_assets",
            json!({
                "query": query,
                "tags": tags,
                "color_hex": color,
                "folder_path": folder,
                "include_subfolders": include_subfolders,
                "offset": offset,
                "limit": limit
            }),
        ),
        Commands::SemanticSearch {
            query,
            folder,
            limit,
        } => (
            "semantic_search",
            json!({ "query": query, "folder_path": folder, "limit": limit }),
        ),
        Commands::Similar { asset_id, limit } => (
            "find_similar_assets",
            json!({ "asset_id": asset_id, "limit": limit }),
        ),
        Commands::Jump { query, limit } => {
            ("quick_jump", json!({ "query": query, "limit": limit }))
        }
        Commands::SuggestFolder { asset_ids } => {
            ("suggest_folder", json!({ "asset_ids": asset_ids }))
        }
        Commands::Asset { id } => ("get_asset", json!({ "asset_id": id })),
        Commands::ContactSheet {
            asset_ids,
            query,
            columns,
            offset,
            output,
        } => (
            "render_contact_sheet",
            json!({
                "asset_ids": asset_ids,
                "query": query.unwrap_or_default(),
                "columns": columns,
                "offset": offset,
                "output_path": output.map(|p| p.display().to_string())
            }),
        ),
        Commands::Boards => ("list_boards", json!({})),
        Commands::Board { id_or_title } => ("get_board_context", board_selector(&id_or_title)),
        Commands::ExportBoard {
            id_or_title,
            format,
            scale,
            output,
        } => {
            let mut m = board_selector(&id_or_title);
            m["format"] = json!(format);
            m["scale"] = json!(scale);
            m["output_path"] = json!(output.display().to_string());
            m["include_image"] = json!(false);
            ("export_board_image", m)
        }
        Commands::Organize {
            asset_ids,
            folder,
            inbox,
            add_tags,
            remove_tags,
            rating,
            ai_description,
        } => (
            "organize_assets",
            json!({
                "asset_ids": asset_ids,
                "folder_path": folder,
                "move_to_inbox": inbox,
                "add_tags": add_tags,
                "remove_tags": remove_tags,
                "rating": rating,
                "ai_description": ai_description
            }),
        ),
        Commands::CreateFolder { name, parent_id } => (
            "create_folder",
            json!({ "name": name, "parent_id": parent_id }),
        ),
        Commands::UpdateFolder {
            id_or_path,
            new_name,
            parent_id,
            root,
            color,
        } => {
            let mut m = folder_selector(&id_or_path);
            m["new_name"] = json!(new_name);
            m["parent_id"] = json!(parent_id);
            m["move_to_root"] = json!(root);
            if let Some(c) = color {
                m["color_hex"] = json!(c);
            }
            ("update_folder", m)
        }
        Commands::Folder { action } => match action {
            FolderSubcommand::List => ("library_overview", json!({})),
            FolderSubcommand::Create {
                name,
                parent_id,
                parent_path,
                color,
            } => (
                "create_folder",
                json!({
                    "name": name,
                    "parent_id": parent_id,
                    "parent_path": parent_path,
                    "color_hex": color
                }),
            ),
            FolderSubcommand::Rename {
                id_or_path,
                new_name,
            } => {
                let mut m = folder_selector(&id_or_path);
                m["new_name"] = json!(new_name);
                ("update_folder", m)
            }
            FolderSubcommand::Move {
                id_or_path,
                parent_id,
                parent_path,
                root,
            } => {
                let mut m = folder_selector(&id_or_path);
                m["parent_id"] = json!(parent_id);
                m["parent_path"] = json!(parent_path);
                m["move_to_root"] = json!(root);
                ("update_folder", m)
            }
            FolderSubcommand::Update {
                id_or_path,
                new_name,
                parent_id,
                parent_path,
                root,
                color,
                symbol,
            } => {
                let mut m = folder_selector(&id_or_path);
                m["new_name"] = json!(new_name);
                m["parent_id"] = json!(parent_id);
                m["parent_path"] = json!(parent_path);
                m["move_to_root"] = json!(root);
                if let Some(c) = color {
                    m["color_hex"] = json!(c);
                }
                if let Some(s) = symbol {
                    m["custom_symbol"] = json!(s);
                }
                ("update_folder", m)
            }
        },
        Commands::Ingest {
            file,
            url,
            color,
            text,
            title,
            folder,
            tags,
        } => (
            "ingest_asset",
            json!({
                "file_path": file.map(|p| p.display().to_string()),
                "web_url": url,
                "color_hex": color,
                "text": text,
                "title": title,
                "folder_path": folder,
                "tags": tags
            }),
        ),
        Commands::ComposeBoard {
            title,
            prompt,
            asset_ids,
            style,
            freeform,
        } => (
            "compose_moodboard",
            json!({
                "title": title.unwrap_or_default(),
                "prompt": prompt.unwrap_or_default(),
                "asset_ids": asset_ids,
                "layout_style": style,
                "use_freeform": freeform
            }),
        ),
        Commands::PatchBoard {
            id_or_title,
            new_title,
            add_ids,
            remove_ids,
            section,
            note,
        } => {
            let mut m = board_selector(&id_or_title);
            m["new_title"] = json!(new_title);
            m["add_asset_ids"] = json!(add_ids);
            m["remove_asset_ids"] = json!(remove_ids);
            m["add_section"] = json!(section);
            m["add_note"] = json!(note);
            ("patch_moodboard", m)
        }
        Commands::Trash { asset_ids, restore } => (
            "trash_assets",
            json!({ "asset_ids": asset_ids, "trashed": !restore }),
        ),
        Commands::Analyze {
            asset_ids,
            refresh_rich,
        } => (
            "analyze_assets",
            json!({ "asset_ids": asset_ids, "refresh_rich_metadata": refresh_rich }),
        ),
        Commands::Status | Commands::Doctor | Commands::Mcp | Commands::Completions { .. } => {
            unreachable!()
        }
    };

    let output = service
        .call_tool(tool_name, &args, ExternalAgentChannel::Cli)
        .await;
    let text = output.first_text();
    if output.is_error {
        eprintln!("{text}");
        std::process::exit(1);
    }
    if cli.compact {
        if let Ok(parsed) = serde_json::from_str::<Value>(&text) {
            println!("{}", serde_json::to_string(&parsed).unwrap_or(text));
            return;
        }
    }
    println!("{text}");
}

fn board_selector(raw: &str) -> Value {
    if uuid::Uuid::parse_str(raw.trim()).is_ok() {
        json!({ "board_id": raw.trim() })
    } else {
        json!({ "title": raw.trim() })
    }
}

fn folder_selector(raw: &str) -> Value {
    if uuid::Uuid::parse_str(raw.trim()).is_ok() {
        json!({ "folder_id": raw.trim() })
    } else {
        json!({ "folder_path": raw.trim() })
    }
}

fn print_completions(shell: &str) {
    let cmds = "status doctor mcp overview inbox search semantic-search similar jump suggest-folder asset contact-sheet boards board export-board organize create-folder update-folder folder ingest compose-board patch-board trash analyze completions";
    match shell.to_ascii_lowercase().as_str() {
        "bash" => println!(
            "complete -W \"{cmds}\" charkle-cli charkle-cli.exe"
        ),
        "zsh" => println!(
            "#compdef charkle-cli\n_arguments '1:command:({cmds})'"
        ),
        _ => println!(
            "Register-ArgumentCompleter -Native -CommandName charkle-cli,charkle-cli.exe -ScriptBlock {{\n  param($wordToComplete)\n  '{cmds}'.Split(' ') | Where-Object {{ $_ -like \"$wordToComplete*\" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}\n}}"
        ),
    }
}

const MAX_MCP_CONTENT_LENGTH: usize = 16 * 1024 * 1024;

/// Parses an LSP-style `Content-Length` header line case-insensitively with an upper bound.
fn parse_mcp_content_length(header_line: &str) -> Option<Result<usize, &'static str>> {
    let (name, value) = header_line.split_once(':')?;
    if !name.trim().eq_ignore_ascii_case("content-length") {
        return None;
    }
    match value.trim().parse::<usize>() {
        Ok(len) if len <= MAX_MCP_CONTENT_LENGTH => Some(Ok(len)),
        Ok(_) => Some(Err("Content-Length exceeds 16 MiB limit")),
        Err(_) => Some(Err("Invalid Content-Length header value")),
    }
}

/// Supports both newline-delimited JSON-RPC (MCP stdio spec) and LSP-style `Content-Length` framing.
async fn run_mcp_stdio(service: &CharkleExternalAgentService) {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut out = stdout.lock();
    let mut line = String::new();

    loop {
        line.clear();
        let Ok(n) = reader.read_line(&mut line) else {
            break;
        };
        if n == 0 {
            break;
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if let Some(parsed_len) = parse_mcp_content_length(trimmed) {
            // Consume remaining header lines until empty line
            loop {
                line.clear();
                if reader.read_line(&mut line).unwrap_or(0) == 0 || line.trim().is_empty() {
                    break;
                }
            }
            match parsed_len {
                Ok(content_len) => {
                    let mut buf = vec![0u8; content_len];
                    if reader.read_exact(&mut buf).is_err() {
                        break;
                    }
                    let body = String::from_utf8_lossy(&buf);
                    if let Some(reply) = service.handle_jsonrpc(&body).await {
                        let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                        let _ = out.flush();
                    }
                }
                Err(msg) => {
                    let reply = json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": { "code": -32600, "message": msg }
                    })
                    .to_string();
                    let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                    let _ = out.flush();
                    break;
                }
            }
            continue;
        }

        if let Some(reply) = service.handle_jsonrpc(trimmed).await {
            let _ = writeln!(out, "{reply}");
            let _ = out.flush();
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_mcp_content_length_case_insensitive_and_enforces_limit() {
        assert_eq!(
            parse_mcp_content_length("Content-Length: 128"),
            Some(Ok(128))
        );
        assert_eq!(parse_mcp_content_length("content-length: 42"), Some(Ok(42)));
        assert_eq!(parse_mcp_content_length("CONTENT-LENGTH: 0"), Some(Ok(0)));
        assert!(matches!(
            parse_mcp_content_length("Content-Length: 99999999999"),
            Some(Err(_))
        ));
        assert!(matches!(
            parse_mcp_content_length("Content-Length: not-a-number"),
            Some(Err(_))
        ));
        assert_eq!(
            parse_mcp_content_length("Content-Type: application/json"),
            None
        );
    }
}
