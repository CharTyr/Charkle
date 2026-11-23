//! Native Windows `charkle-cli.exe` binary powering BOTH:
//! - MCP Server over JSON-RPC 2.0 stdio (`charkle-cli.exe mcp`)
//! - Grounded CLI subcommands (`status`, `overview`, `inbox`, `search`, `asset`,
//!   `contact-sheet`, `boards`, `board`, `export-board`, `organize`, `create-folder`,
//!   `ingest`, `compose-board`, `patch-board`, `trash`)
//!
//! Opens `Library.sqlite3` directly in SQLite WAL mode, enforces `ExternalAgentConfig`
//! (`mcpEnabled`, `cliEnabled`, `readOnly` / `readWriteOrganize`, soft-trash only), and
//! signals any running `charkle-desktop.exe` via `Local\CharkleLibraryChanged`.

use std::io::{self, BufRead, Write};
use std::path::PathBuf;
use std::sync::Arc;

use charkle_core::agent::{
    resolve_default_data_dir, CharkleExternalAgentService, ExternalAgentConfigStore,
};
use charkle_core::engine::LiveCharkleEngine;
use charkle_core::models::agent::ExternalAgentChannel;
use charkle_platform_win::wake::pulse_library_changed;
use clap::{Parser, Subcommand};
use serde_json::{json, Value};

#[derive(Debug, Parser)]
#[command(
    name = "charkle-cli",
    version = "1.0.1",
    about = "Charkle Windows Native CLI & MCP Server"
)]
struct Cli {
    /// Override Charkle library data directory (defaults to AppData / CHARKLE_LIBRARY_DIR).
    #[arg(long, global = true)]
    library_dir: Option<PathBuf>,

    /// Emit raw JSON output where applicable.
    #[arg(long, global = true)]
    json: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Print CLI readiness, library directory, and active External Agent policy.
    Status,
    /// Run JSON-RPC 2.0 Model Context Protocol (MCP) server on stdio.
    Mcp,
    /// Show library overview (folders, top tags, asset & board counts).
    Overview,
    /// List newest items waiting in Inbox.
    Inbox {
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
        #[arg(long, default_value_t = 30)]
        limit: u64,
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
    },
    /// [Write] Create a new folder.
    CreateFolder {
        name: String,
        #[arg(long)]
        parent_id: Option<String>,
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
    /// [Write] Patch an existing moodboard (rename, add/remove unlocked assets, add note).
    PatchBoard {
        id_or_title: String,
        #[arg(long)]
        new_title: Option<String>,
        #[arg(long = "add-id")]
        add_ids: Vec<String>,
        #[arg(long = "remove-id")]
        remove_ids: Vec<String>,
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
}

#[tokio::main]
async fn main() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    let cli = Cli::parse();
    let data_dir = cli.library_dir.unwrap_or_else(resolve_default_data_dir);

    if matches!(cli.command, None | Some(Commands::Status)) {
        let policy = ExternalAgentConfigStore::load(&data_dir);
        let status = json!({
            "name": "charkle-cli",
            "version": "1.0.1",
            "libraryDir": data_dir.display().to_string(),
            "databaseExists": data_dir.join("Library.sqlite3").exists(),
            "mcpEnabled": policy.mcp_enabled,
            "cliEnabled": policy.cli_enabled,
            "accessLevel": policy.access_level
        });
        if cli.json {
            println!("{}", serde_json::to_string_pretty(&status).unwrap());
        } else {
            println!(
                "charkle-cli 1.0.1 | library={} | mcp={} | cli={} | access={:?}",
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
        Commands::Inbox { limit } => ("list_inbox", json!({ "limit": limit })),
        Commands::Search {
            query,
            tags,
            color,
            folder,
            limit,
        } => (
            "search_assets",
            json!({
                "query": query,
                "tags": tags,
                "color_hex": color,
                "folder_path": folder,
                "limit": limit
            }),
        ),
        Commands::Asset { id } => ("get_asset", json!({ "asset_id": id })),
        Commands::ContactSheet {
            asset_ids,
            query,
            columns,
            output,
        } => (
            "render_contact_sheet",
            json!({
                "asset_ids": asset_ids,
                "query": query.unwrap_or_default(),
                "columns": columns,
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
            ("export_board_image", m)
        }
        Commands::Organize {
            asset_ids,
            folder,
            inbox,
            add_tags,
            remove_tags,
            rating,
        } => (
            "organize_assets",
            json!({
                "asset_ids": asset_ids,
                "folder_path": folder,
                "move_to_inbox": inbox,
                "add_tags": add_tags,
                "remove_tags": remove_tags,
                "rating": rating
            }),
        ),
        Commands::CreateFolder { name, parent_id } => (
            "create_folder",
            json!({ "name": name, "parent_id": parent_id }),
        ),
        Commands::Ingest {
            file,
            url,
            color,
            text,
            title,
            folder,
        } => (
            "ingest_asset",
            json!({
                "file_path": file.map(|p| p.display().to_string()),
                "url": url,
                "color_hex": color,
                "text": text,
                "title": title,
                "folder_path": folder
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
            note,
        } => {
            let mut m = board_selector(&id_or_title);
            m["new_title"] = json!(new_title);
            m["add_asset_ids"] = json!(add_ids);
            m["remove_asset_ids"] = json!(remove_ids);
            m["add_note"] = json!(note);
            ("patch_moodboard", m)
        }
        Commands::Trash { asset_ids, restore } => (
            "trash_assets",
            json!({ "asset_ids": asset_ids, "trashed": !restore }),
        ),
        Commands::Status | Commands::Mcp => unreachable!(),
    };

    let output = service
        .call_tool(tool_name, &args, ExternalAgentChannel::Cli)
        .await;
    let text = output.first_text();
    if output.is_error {
        eprintln!("{text}");
        std::process::exit(1);
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

async fn run_mcp_stdio(service: &CharkleExternalAgentService) {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut out = stdout.lock();

    for line_res in stdin.lock().lines() {
        let Ok(line) = line_res else { break };
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if let Some(reply) = service.handle_jsonrpc(trimmed).await {
            let _ = writeln!(out, "{reply}");
            let _ = out.flush();
        }
    }
}
