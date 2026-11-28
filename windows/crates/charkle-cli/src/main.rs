//! Native Windows `charkle-cli.exe` binary powering BOTH:
//! - MCP v2 Server over JSON-RPC 2.0 stdio (`charkle-cli.exe mcp`, supporting NDJSON & `Content-Length` framing + batch arrays)
//! - Grounded low-token CLI subcommands (`status`, `doctor`, `overview`, `inbox`, `search`,
//!   `semantic` / `semantic-search`, `similar`, `jump`, `suggest-folder`, `asset`, `contact-sheet`,
//!   `boards`, `board`, `export-board`, `organize`, `create-folder`, `update-folder`, `folder`,
//!   `ingest`, `compose-board`, `patch-board`, `trash`, `analyze`, `completions`)
//!
//! Opens `Library.sqlite3` directly in SQLite WAL mode, enforces `ExternalAgentConfig`
//! (`mcpEnabled`, `cliEnabled`, `readOnly` / `readWriteOrganize`, soft-trash only), auto-switches
//! piped stdout to compact single-line JSON, and signals any running `charkle-desktop.exe` via
//! `Local\CharkleLibraryChanged`.

use std::io::{self, BufRead, BufReader, IsTerminal, Read, Write};
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
use serde_json::{json, Map, Value};

#[derive(Debug, Parser)]
#[command(
    name = "charkle-cli",
    version = env!("CARGO_PKG_VERSION"),
    about = "Charkle Windows Native CLI & MCP v2 Server"
)]
struct Cli {
    /// Override Charkle library data directory (defaults to AppData / CHARKLE_LIBRARY_DIR).
    #[arg(long, global = true)]
    library_dir: Option<PathBuf>,

    /// Emit raw JSON output where applicable.
    #[arg(long, global = true)]
    json: bool,

    /// Force compact single-line JSON output (automatic when stdout is piped).
    #[arg(long, global = true)]
    compact: bool,

    /// Force pretty-printed JSON output even when stdout is piped.
    #[arg(long, global = true)]
    pretty: bool,

    /// Human-friendly formatted output (alias for `--pretty` on JSON commands).
    #[arg(long, global = true)]
    human: bool,

    #[command(subcommand)]
    command: Option<Commands>,
}

#[derive(Debug, Subcommand)]
enum FolderSubcommand {
    /// List all folders with paths, recursive counts, top tags, and palettes.
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
    /// Show library semantic atlas (folders + recursive counts + topTags + palettes + boards).
    Overview {
        /// Return full (non-compact) UUIDs and cache stats.
        #[arg(long)]
        full: bool,
        /// Omit per-folder semantic profiles.
        #[arg(long)]
        no_profiles: bool,
        /// Omit moodboard summaries.
        #[arg(long)]
        no_boards: bool,
        #[arg(long, default_value_t = 30)]
        top_tags_limit: u64,
    },
    /// List newest items waiting in Inbox.
    Inbox {
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 20)]
        limit: u64,
        /// Also compute folder suggestions for returned Inbox items.
        #[arg(long)]
        suggest: bool,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        contact_sheet: bool,
        #[arg(long = "out", alias = "output")]
        out: Option<PathBuf>,
        #[arg(long)]
        max_width: Option<u64>,
    },
    /// Search visual references by query, tags, CIELAB tone, shape, color, or folder.
    Search {
        #[arg(default_value = "")]
        query: String,
        #[arg(long = "tag")]
        tags: Vec<String>,
        #[arg(long = "any-tag")]
        any_tags: Vec<String>,
        #[arg(long = "exclude-tag")]
        exclude_tags: Vec<String>,
        #[arg(long = "exclude-ids", alias = "exclude-id")]
        exclude_ids: Vec<String>,
        #[arg(long)]
        color: Option<String>,
        #[arg(long)]
        tone: Option<String>,
        #[arg(long = "shape", alias = "aspect-shape")]
        shape: Option<String>,
        #[arg(long)]
        folder: Option<String>,
        /// Include nested subfolders (default: true).
        #[arg(long)]
        subfolders: bool,
        /// Restrict to direct children of `--folder` only.
        #[arg(long)]
        no_subfolders: bool,
        #[arg(long)]
        diversify: bool,
        #[arg(long)]
        facets: bool,
        #[arg(long)]
        no_facets: bool,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        contact_sheet: bool,
        #[arg(long = "out", alias = "output")]
        out: Option<PathBuf>,
        #[arg(long)]
        max_width: Option<u64>,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 20)]
        limit: u64,
    },
    /// Bilingual EN↔ZH + CIELAB tone + multi-direction `queries[]` + seed/unlike visual search.
    #[command(visible_alias = "semantic")]
    SemanticSearch {
        #[arg(default_value = "")]
        query: String,
        /// Multi-direction queries (comma-separated or repeated) merged into 1 Contact Sheet.
        #[arg(long = "queries", alias = "query")]
        queries: Vec<String>,
        #[arg(long = "seed-ids")]
        seed_ids: Vec<String>,
        #[arg(long = "unlike-ids")]
        unlike_ids: Vec<String>,
        #[arg(long = "exclude-ids")]
        exclude_ids: Vec<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long)]
        subfolders: bool,
        #[arg(long)]
        no_subfolders: bool,
        #[arg(long = "tag")]
        tags: Vec<String>,
        #[arg(long = "any-tag")]
        any_tags: Vec<String>,
        #[arg(long = "exclude-tag")]
        exclude_tags: Vec<String>,
        #[arg(long)]
        tone: Option<String>,
        #[arg(long = "shape", alias = "aspect-shape")]
        shape: Option<String>,
        #[arg(long)]
        color: Option<String>,
        /// Skip cloud visual rerank for instant local recall.
        #[arg(long, alias = "no-visual-rerank")]
        fast: bool,
        #[arg(long)]
        diversify: bool,
        #[arg(long)]
        facets: bool,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        contact_sheet: bool,
        #[arg(long = "out", alias = "output")]
        out: Option<PathBuf>,
        #[arg(long)]
        max_width: Option<u64>,
        #[arg(long, default_value_t = 16)]
        limit: u64,
    },
    /// Find visually similar assets to a reference asset UUID or 8+ char prefix.
    Similar {
        asset_id: String,
        #[arg(long = "unlike-ids")]
        unlike_ids: Vec<String>,
        #[arg(long = "exclude-ids")]
        exclude_ids: Vec<String>,
        #[arg(long)]
        diversify: bool,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        contact_sheet: bool,
        #[arg(long = "out", alias = "output")]
        out: Option<PathBuf>,
        #[arg(long)]
        max_width: Option<u64>,
        #[arg(long, default_value_t = 12)]
        limit: u64,
    },
    /// Unified fast fuzzy jump across folders, moodboards, tags, and assets.
    Jump {
        query: String,
        #[arg(long, default_value_t = 20)]
        limit: u64,
    },
    /// Recommend best folders for one or more asset UUIDs or 8+ char prefixes.
    SuggestFolder {
        #[arg(long = "id", alias = "ids")]
        asset_ids: Vec<String>,
        #[arg(value_name = "ASSET_ID")]
        positional_ids: Vec<String>,
    },
    /// Inspect full metadata for 1–12 finalist asset UUIDs or 8+ char prefixes.
    Asset {
        #[arg(required = true)]
        ids: Vec<String>,
        #[arg(long)]
        include_image: bool,
    },
    /// Render 1–24 asset thumbnails into a numbered JPEG contact sheet (`512..=1920` px wide).
    ContactSheet {
        #[arg(long = "id", alias = "ids")]
        asset_ids: Vec<String>,
        #[arg(long)]
        query: Option<String>,
        #[arg(long = "queries")]
        queries: Vec<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long)]
        inbox: bool,
        #[arg(long)]
        tone: Option<String>,
        #[arg(long = "shape", alias = "aspect-shape")]
        shape: Option<String>,
        #[arg(long = "any-tag")]
        any_tags: Vec<String>,
        #[arg(long = "exclude-tag")]
        exclude_tags: Vec<String>,
        #[arg(long)]
        diversify: bool,
        #[arg(long)]
        detail: Option<String>,
        #[arg(long)]
        columns: Option<u64>,
        #[arg(long, default_value_t = 1024)]
        max_width: u64,
        #[arg(long, default_value_t = 0)]
        offset: u64,
        #[arg(long, default_value_t = 16)]
        limit: u64,
        #[arg(long = "out", alias = "output")]
        output: Option<PathBuf>,
    },
    /// List all moodboards.
    Boards,
    /// Inspect nodes and palette of a moodboard by UUID/prefix or title.
    Board {
        id_or_title: String,
        #[arg(long)]
        detail: Option<String>,
    },
    /// Export a moodboard to PNG or JPEG.
    ExportBoard {
        id_or_title: String,
        #[arg(long, default_value = "png")]
        format: String,
        #[arg(long, default_value_t = 1.0)]
        scale: f64,
        #[arg(long)]
        width: Option<u64>,
        #[arg(long)]
        dark: bool,
        #[arg(long = "output", alias = "out")]
        output: PathBuf,
    },
    /// [Write] Move/tag/rate assets (supports 8+ char prefixes and `--ids a,b,c`).
    Organize {
        #[arg(long = "id", alias = "ids", required = true)]
        asset_ids: Vec<String>,
        #[arg(long)]
        folder: Option<String>,
        #[arg(long)]
        inbox: bool,
        #[arg(long = "add-tag", alias = "add-tags")]
        add_tags: Vec<String>,
        #[arg(long = "remove-tag", alias = "remove-tags")]
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
        #[arg(long = "tag", alias = "tags")]
        tags: Vec<String>,
    },
    /// [Write] Compose a moodboard from prompt or explicit asset UUIDs/prefixes.
    ComposeBoard {
        #[arg(long)]
        title: Option<String>,
        #[arg(long)]
        prompt: Option<String>,
        #[arg(long = "id", alias = "ids")]
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
        #[arg(long = "add-id", alias = "add-ids")]
        add_ids: Vec<String>,
        #[arg(long = "remove-id", alias = "remove-ids")]
        remove_ids: Vec<String>,
        #[arg(long)]
        section: Option<String>,
        #[arg(long, alias = "add-note")]
        note: Option<String>,
    },
    /// [Write] Soft-move assets to Trash (or --restore). Permanent delete is never permitted.
    Trash {
        #[arg(long = "id", alias = "ids", required = true)]
        asset_ids: Vec<String>,
        #[arg(long)]
        restore: bool,
    },
    /// [Write] Hydrate EXIF, AI prompts, OCR, and optional live rich metadata for up to 20 assets.
    Analyze {
        #[arg(long = "id", alias = "ids", required = true)]
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

fn expand_csv_list(items: Vec<String>) -> Vec<String> {
    let mut out = Vec::new();
    for item in items {
        for part in item.split([',', '，']) {
            let trimmed = part.trim();
            if !trimmed.is_empty() {
                out.push(trimmed.to_string());
            }
        }
    }
    out
}

fn should_pretty_print(cli: &Cli, stdout_is_tty: bool) -> bool {
    if cli.compact {
        return false;
    }
    cli.pretty || cli.human || stdout_is_tty
}

fn format_json_output(raw_text: &str, pretty: bool) -> String {
    match serde_json::from_str::<Value>(raw_text) {
        Ok(parsed) => {
            if pretty {
                serde_json::to_string_pretty(&parsed).unwrap_or_else(|_| raw_text.to_string())
            } else {
                serde_json::to_string(&parsed).unwrap_or_else(|_| raw_text.to_string())
            }
        }
        Err(_) => raw_text.to_string(),
    }
}

fn is_uuid_or_hex_prefix(raw: &str) -> bool {
    let trimmed = raw.trim();
    if uuid::Uuid::parse_str(trimmed).is_ok() {
        return true;
    }
    trimmed.len() >= 8 && trimmed.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-')
}

#[tokio::main]
async fn main() {
    let _ = tracing_subscriber::fmt()
        .with_writer(std::io::stderr)
        .try_init();

    let cli = Cli::parse();
    let stdout_is_tty = io::stdout().is_terminal();
    let pretty = should_pretty_print(&cli, stdout_is_tty);
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
            "version": env!("CARGO_PKG_VERSION"),
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
        if cli.json
            || cli.compact
            || !stdout_is_tty
            || matches!(cli.command, Some(Commands::Doctor))
        {
            let rendered = if pretty {
                serde_json::to_string_pretty(&status).unwrap_or_else(|_| "{}".to_string())
            } else {
                serde_json::to_string(&status).unwrap_or_else(|_| "{}".to_string())
            };
            println!("{rendered}");
        } else {
            println!(
                "charkle-cli {} (MCP v2: {} read / {} write tools) | library={} | mcp={} | cli={} | access={:?}",
                env!("CARGO_PKG_VERSION"),
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

    let mut inbox_suggest = false;
    let (tool_name, args) = match cmd {
        Commands::Overview {
            full,
            no_profiles,
            no_boards,
            top_tags_limit,
        } => (
            "library_overview",
            json!({
                "compact": !full,
                "include_folder_profiles": !no_profiles,
                "include_boards": !no_boards,
                "top_tags_limit": top_tags_limit
            }),
        ),
        Commands::Inbox {
            offset,
            limit,
            suggest,
            detail,
            contact_sheet,
            out,
            max_width,
        } => {
            inbox_suggest = suggest;
            let want_sheet = contact_sheet || out.is_some();
            let mut m = Map::new();
            m.insert("offset".into(), json!(offset));
            m.insert("limit".into(), json!(limit));
            if let Some(d) = detail {
                m.insert("detail".into(), json!(d));
            }
            if want_sheet {
                m.insert("render_contact_sheet".into(), json!(true));
                m.insert("include_image".into(), json!(false));
            }
            if let Some(p) = out {
                m.insert("output_path".into(), json!(p.display().to_string()));
            }
            if let Some(w) = max_width {
                m.insert("sheet_max_width".into(), json!(w));
            }
            ("list_inbox", Value::Object(m))
        }
        Commands::Search {
            query,
            tags,
            any_tags,
            exclude_tags,
            exclude_ids,
            color,
            tone,
            shape,
            folder,
            subfolders,
            no_subfolders,
            diversify,
            facets,
            no_facets,
            detail,
            contact_sheet,
            out,
            max_width,
            offset,
            limit,
        } => {
            let _ = subfolders;
            let include_subfolders = !no_subfolders;
            let want_sheet = contact_sheet || out.is_some();
            let mut m = Map::new();
            if !query.trim().is_empty() {
                m.insert("query".into(), json!(query));
            }
            let tags = expand_csv_list(tags);
            if !tags.is_empty() {
                m.insert("tags".into(), json!(tags));
            }
            let any_tags = expand_csv_list(any_tags);
            if !any_tags.is_empty() {
                m.insert("any_tags".into(), json!(any_tags));
            }
            let exclude_tags = expand_csv_list(exclude_tags);
            if !exclude_tags.is_empty() {
                m.insert("exclude_tags".into(), json!(exclude_tags));
            }
            let exclude_ids = expand_csv_list(exclude_ids);
            if !exclude_ids.is_empty() {
                m.insert("exclude_asset_ids".into(), json!(exclude_ids));
            }
            if let Some(c) = color {
                m.insert("color_hex".into(), json!(c));
            }
            if let Some(t) = tone {
                m.insert("tone".into(), json!(t));
            }
            if let Some(s) = shape {
                m.insert("aspect_shape".into(), json!(s));
            }
            if let Some(f) = folder {
                if is_uuid_or_hex_prefix(&f) {
                    m.insert("folder_id".into(), json!(f));
                } else {
                    m.insert("folder_path".into(), json!(f));
                }
            }
            m.insert("include_subfolders".into(), json!(include_subfolders));
            if diversify {
                m.insert("diversify".into(), json!(true));
            }
            if facets {
                m.insert("include_facets".into(), json!(true));
            } else if no_facets {
                m.insert("include_facets".into(), json!(false));
            }
            if let Some(d) = detail {
                m.insert("detail".into(), json!(d));
            }
            if want_sheet {
                m.insert("render_contact_sheet".into(), json!(true));
                m.insert("include_image".into(), json!(false));
            }
            if let Some(p) = out {
                m.insert("output_path".into(), json!(p.display().to_string()));
            }
            if let Some(w) = max_width {
                m.insert("sheet_max_width".into(), json!(w));
            }
            m.insert("offset".into(), json!(offset));
            m.insert("limit".into(), json!(limit));
            ("search_assets", Value::Object(m))
        }
        Commands::SemanticSearch {
            query,
            queries,
            seed_ids,
            unlike_ids,
            exclude_ids,
            folder,
            subfolders,
            no_subfolders,
            tags,
            any_tags,
            exclude_tags,
            tone,
            shape,
            color,
            fast,
            diversify,
            facets,
            detail,
            contact_sheet,
            out,
            max_width,
            limit,
        } => {
            let _ = subfolders;
            let include_subfolders = !no_subfolders;
            let want_sheet = contact_sheet || out.is_some();
            let mut m = Map::new();
            if !query.trim().is_empty() {
                m.insert("query".into(), json!(query));
            }
            let queries = expand_csv_list(queries);
            if !queries.is_empty() {
                m.insert("queries".into(), json!(queries));
            }
            let seed_ids = expand_csv_list(seed_ids);
            if !seed_ids.is_empty() {
                m.insert("seed_asset_ids".into(), json!(seed_ids));
            }
            let unlike_ids = expand_csv_list(unlike_ids);
            if !unlike_ids.is_empty() {
                m.insert("unlike_asset_ids".into(), json!(unlike_ids));
            }
            let exclude_ids = expand_csv_list(exclude_ids);
            if !exclude_ids.is_empty() {
                m.insert("exclude_asset_ids".into(), json!(exclude_ids));
            }
            if let Some(f) = folder {
                if is_uuid_or_hex_prefix(&f) {
                    m.insert("folder_id".into(), json!(f));
                } else {
                    m.insert("folder_path".into(), json!(f));
                }
            }
            m.insert("include_subfolders".into(), json!(include_subfolders));
            let tags = expand_csv_list(tags);
            if !tags.is_empty() {
                m.insert("tags".into(), json!(tags));
            }
            let any_tags = expand_csv_list(any_tags);
            if !any_tags.is_empty() {
                m.insert("any_tags".into(), json!(any_tags));
            }
            let exclude_tags = expand_csv_list(exclude_tags);
            if !exclude_tags.is_empty() {
                m.insert("exclude_tags".into(), json!(exclude_tags));
            }
            if let Some(t) = tone {
                m.insert("tone".into(), json!(t));
            }
            if let Some(s) = shape {
                m.insert("aspect_shape".into(), json!(s));
            }
            if let Some(c) = color {
                m.insert("color_hex".into(), json!(c));
            }
            if fast {
                m.insert("visual_rerank".into(), json!(false));
            }
            if diversify {
                m.insert("diversify".into(), json!(true));
            }
            if facets {
                m.insert("include_facets".into(), json!(true));
            }
            if let Some(d) = detail {
                m.insert("detail".into(), json!(d));
            }
            if want_sheet {
                m.insert("render_contact_sheet".into(), json!(true));
                m.insert("include_image".into(), json!(false));
            }
            if let Some(p) = out {
                m.insert("output_path".into(), json!(p.display().to_string()));
            }
            if let Some(w) = max_width {
                m.insert("sheet_max_width".into(), json!(w));
            }
            m.insert("limit".into(), json!(limit));
            ("semantic_search", Value::Object(m))
        }
        Commands::Similar {
            asset_id,
            unlike_ids,
            exclude_ids,
            diversify,
            detail,
            contact_sheet,
            out,
            max_width,
            limit,
        } => {
            let want_sheet = contact_sheet || out.is_some();
            let mut m = Map::new();
            m.insert("asset_id".into(), json!(asset_id));
            let unlike_ids = expand_csv_list(unlike_ids);
            if !unlike_ids.is_empty() {
                m.insert("unlike_asset_ids".into(), json!(unlike_ids));
            }
            let exclude_ids = expand_csv_list(exclude_ids);
            if !exclude_ids.is_empty() {
                m.insert("exclude_asset_ids".into(), json!(exclude_ids));
            }
            if diversify {
                m.insert("diversify".into(), json!(true));
            }
            if let Some(d) = detail {
                m.insert("detail".into(), json!(d));
            }
            if want_sheet {
                m.insert("render_contact_sheet".into(), json!(true));
                m.insert("include_image".into(), json!(false));
            }
            if let Some(p) = out {
                m.insert("output_path".into(), json!(p.display().to_string()));
            }
            if let Some(w) = max_width {
                m.insert("sheet_max_width".into(), json!(w));
            }
            m.insert("limit".into(), json!(limit));
            ("find_similar_assets", Value::Object(m))
        }
        Commands::Jump { query, limit } => {
            ("quick_jump", json!({ "query": query, "limit": limit }))
        }
        Commands::SuggestFolder {
            asset_ids,
            positional_ids,
        } => {
            let mut combined = expand_csv_list(asset_ids);
            combined.extend(expand_csv_list(positional_ids));
            ("suggest_folder", json!({ "asset_ids": combined }))
        }
        Commands::Asset { ids, include_image } => {
            let expanded = expand_csv_list(ids);
            if expanded.len() <= 1 {
                (
                    "get_asset",
                    json!({
                        "asset_id": expanded.first().cloned().unwrap_or_default(),
                        "include_image": include_image
                    }),
                )
            } else {
                (
                    "get_asset",
                    json!({
                        "asset_ids": expanded,
                        "include_image": include_image
                    }),
                )
            }
        }
        Commands::ContactSheet {
            asset_ids,
            query,
            queries,
            folder,
            inbox,
            tone,
            shape,
            any_tags,
            exclude_tags,
            diversify,
            detail,
            columns,
            max_width,
            offset,
            limit,
            output,
        } => {
            let mut m = Map::new();
            let ids = expand_csv_list(asset_ids);
            if !ids.is_empty() {
                m.insert("asset_ids".into(), json!(ids));
            }
            if let Some(q) = query {
                m.insert("query".into(), json!(q));
            }
            let qs = expand_csv_list(queries);
            if !qs.is_empty() {
                m.insert("queries".into(), json!(qs));
            }
            if let Some(f) = folder {
                if is_uuid_or_hex_prefix(&f) {
                    m.insert("folder_id".into(), json!(f));
                } else {
                    m.insert("folder_path".into(), json!(f));
                }
            }
            if inbox {
                m.insert("only_inbox".into(), json!(true));
            }
            if let Some(t) = tone {
                m.insert("tone".into(), json!(t));
            }
            if let Some(s) = shape {
                m.insert("aspect_shape".into(), json!(s));
            }
            let any_tags = expand_csv_list(any_tags);
            if !any_tags.is_empty() {
                m.insert("any_tags".into(), json!(any_tags));
            }
            let exclude_tags = expand_csv_list(exclude_tags);
            if !exclude_tags.is_empty() {
                m.insert("exclude_tags".into(), json!(exclude_tags));
            }
            if diversify {
                m.insert("diversify".into(), json!(true));
            }
            if let Some(d) = detail {
                m.insert("detail".into(), json!(d));
            }
            if let Some(cols) = columns {
                m.insert("columns".into(), json!(cols));
            }
            m.insert("max_width".into(), json!(max_width));
            m.insert("offset".into(), json!(offset));
            m.insert("limit".into(), json!(limit));
            m.insert("include_image".into(), json!(false));
            if let Some(p) = output {
                m.insert("output_path".into(), json!(p.display().to_string()));
            }
            ("render_contact_sheet", Value::Object(m))
        }
        Commands::Boards => ("list_boards", json!({})),
        Commands::Board {
            id_or_title,
            detail,
        } => {
            let mut m = board_selector(&id_or_title);
            if let Some(d) = detail {
                m["detail"] = json!(d);
            }
            ("get_board_context", m)
        }
        Commands::ExportBoard {
            id_or_title,
            format,
            scale,
            width,
            dark,
            output,
        } => {
            let mut m = board_selector(&id_or_title);
            m["format"] = json!(format);
            m["scale"] = json!(scale);
            if let Some(w) = width {
                m["width"] = json!(w);
            }
            if dark {
                m["dark_appearance"] = json!(true);
            }
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
        } => {
            let mut m = Map::new();
            m.insert("asset_ids".into(), json!(expand_csv_list(asset_ids)));
            if let Some(f) = folder {
                if is_uuid_or_hex_prefix(&f) {
                    m.insert("folder_id".into(), json!(f));
                } else {
                    m.insert("folder_path".into(), json!(f));
                }
            }
            m.insert("move_to_inbox".into(), json!(inbox));
            m.insert("add_tags".into(), json!(expand_csv_list(add_tags)));
            m.insert("remove_tags".into(), json!(expand_csv_list(remove_tags)));
            if let Some(r) = rating {
                m.insert("rating".into(), json!(r));
            }
            if let Some(desc) = ai_description {
                m.insert("ai_description".into(), json!(desc));
            }
            ("organize_assets", Value::Object(m))
        }
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
                "tags": expand_csv_list(tags)
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
                "asset_ids": expand_csv_list(asset_ids),
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
            m["add_asset_ids"] = json!(expand_csv_list(add_ids));
            m["remove_asset_ids"] = json!(expand_csv_list(remove_ids));
            m["add_section"] = json!(section);
            m["add_note"] = json!(note);
            ("patch_moodboard", m)
        }
        Commands::Trash { asset_ids, restore } => (
            "trash_assets",
            json!({ "asset_ids": expand_csv_list(asset_ids), "trashed": !restore }),
        ),
        Commands::Analyze {
            asset_ids,
            refresh_rich,
        } => (
            "analyze_assets",
            json!({
                "asset_ids": expand_csv_list(asset_ids),
                "refresh_rich_metadata": refresh_rich
            }),
        ),
        Commands::Status | Commands::Doctor | Commands::Mcp | Commands::Completions { .. } => {
            unreachable!()
        }
    };

    let output = service
        .call_tool(tool_name, &args, ExternalAgentChannel::Cli)
        .await;
    let mut text = output.first_text();
    if output.is_error {
        eprintln!("{text}");
        std::process::exit(1);
    }

    if inbox_suggest {
        if let Ok(mut parsed) = serde_json::from_str::<Value>(&text) {
            let ids: Vec<String> = parsed["assets"]
                .as_array()
                .map(|arr| {
                    arr.iter()
                        .filter_map(|item| item["id"].as_str().map(ToOwned::to_owned))
                        .take(20)
                        .collect()
                })
                .unwrap_or_default();
            if !ids.is_empty() {
                let sug = service
                    .call_tool(
                        "suggest_folder",
                        &json!({ "asset_ids": ids }),
                        ExternalAgentChannel::Cli,
                    )
                    .await;
                if !sug.is_error {
                    if let Ok(sug_val) = serde_json::from_str::<Value>(&sug.first_text()) {
                        parsed["folderSuggestions"] = sug_val["recommendations"].clone();
                        text = serde_json::to_string(&parsed).unwrap_or(text);
                    }
                }
            }
        }
    }

    println!("{}", format_json_output(&text, pretty));
}

fn board_selector(raw: &str) -> Value {
    let trimmed = raw.trim();
    if is_uuid_or_hex_prefix(trimmed) {
        json!({ "board_id": trimmed })
    } else {
        json!({ "title": trimmed })
    }
}

fn folder_selector(raw: &str) -> Value {
    let trimmed = raw.trim();
    if is_uuid_or_hex_prefix(trimmed) {
        json!({ "folder_id": trimmed })
    } else {
        json!({ "folder_path": trimmed })
    }
}

fn print_completions(shell: &str) {
    let cmds = "status doctor mcp overview inbox search semantic semantic-search similar jump suggest-folder asset contact-sheet boards board export-board organize create-folder update-folder folder ingest compose-board patch-board trash analyze completions";
    match shell.to_ascii_lowercase().as_str() {
        "bash" => println!("complete -W \"{cmds}\" charkle-cli charkle-cli.exe"),
        "zsh" => println!("#compdef charkle-cli\n_arguments '1:command:({cmds})'"),
        _ => println!(
            "Register-ArgumentCompleter -Native -CommandName charkle-cli,charkle-cli.exe -ScriptBlock {{\n  param($wordToComplete)\n  '{cmds}'.Split(' ') | Where-Object {{ $_ -like \"$wordToComplete*\" }} | ForEach-Object {{ [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_) }}\n}}"
        ),
    }
}

const MAX_MCP_CONTENT_LENGTH: usize = 16 * 1024 * 1024;
const MAX_MCP_LINE_BYTES: usize = MAX_MCP_CONTENT_LENGTH + 4096;

/// Reads one newline-terminated line with a hard byte bound so hostile stdin cannot cause OOM.
fn read_bounded_line<R: BufRead>(
    reader: &mut R,
    out: &mut String,
    max_bytes: usize,
) -> io::Result<Option<usize>> {
    out.clear();
    let mut raw = Vec::new();
    loop {
        let avail = reader.fill_buf()?;
        if avail.is_empty() {
            if raw.is_empty() {
                return Ok(None);
            }
            break;
        }
        if let Some(nl_pos) = avail.iter().position(|&b| b == b'\n') {
            let take = nl_pos + 1;
            if raw.len().saturating_add(take) > max_bytes {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Input line exceeds 16 MiB safety limit",
                ));
            }
            raw.extend_from_slice(&avail[..take]);
            reader.consume(take);
            break;
        }
        let take = avail.len();
        if raw.len().saturating_add(take) > max_bytes {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "Input line exceeds 16 MiB safety limit",
            ));
        }
        raw.extend_from_slice(avail);
        reader.consume(take);
    }
    let len = raw.len();
    *out = String::from_utf8_lossy(&raw).into_owned();
    Ok(Some(len))
}

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

fn looks_like_lsp_header(line: &str) -> bool {
    if line.starts_with('{') || line.starts_with('[') {
        return false;
    }
    let Some((name, _)) = line.split_once(':') else {
        return false;
    };
    !name.is_empty() && name.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

/// Supports both newline-delimited JSON-RPC (MCP stdio spec) and LSP-style `Content-Length` framing
/// regardless of header ordering (e.g. `Content-Type` before `Content-Length`).
async fn run_mcp_stdio(service: &CharkleExternalAgentService) {
    let stdin = io::stdin();
    let stdout = io::stdout();
    let mut reader = BufReader::new(stdin.lock());
    let mut out = stdout.lock();
    let mut line = String::new();

    loop {
        match read_bounded_line(&mut reader, &mut line, MAX_MCP_LINE_BYTES) {
            Ok(Some(_)) => {}
            Ok(None) => break,
            Err(err) => {
                let reply = json!({
                    "jsonrpc": "2.0",
                    "id": Value::Null,
                    "error": { "code": -32600, "message": err.to_string() }
                })
                .to_string();
                let _ = writeln!(out, "{reply}");
                let _ = out.flush();
                break;
            }
        }
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }

        if looks_like_lsp_header(trimmed) {
            let mut parsed_len = parse_mcp_content_length(trimmed);
            let mut header_count = 1usize;
            loop {
                let mut hdr = String::new();
                match read_bounded_line(&mut reader, &mut hdr, 16 * 1024) {
                    Ok(Some(_)) => {
                        let t = hdr.trim();
                        if t.is_empty() {
                            break;
                        }
                        header_count += 1;
                        if header_count > 32 {
                            parsed_len = Some(Err("Too many LSP framing headers"));
                            break;
                        }
                        if let Some(cl) = parse_mcp_content_length(t) {
                            parsed_len = Some(cl);
                        }
                    }
                    _ => break,
                }
            }
            match parsed_len {
                Some(Ok(content_len)) => {
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
                Some(Err(msg)) => {
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
                None => {
                    let reply = json!({
                        "jsonrpc": "2.0",
                        "id": Value::Null,
                        "error": { "code": -32600, "message": "Missing Content-Length header" }
                    })
                    .to_string();
                    let _ = write!(out, "Content-Length: {}\r\n\r\n{}", reply.len(), reply);
                    let _ = out.flush();
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

    #[test]
    fn piped_output_defaults_to_compact_single_line_json() {
        let cli_default = Cli::parse_from(["charkle-cli", "overview"]);
        assert!(!should_pretty_print(&cli_default, false));
        assert!(should_pretty_print(&cli_default, true));

        let cli_compact = Cli::parse_from(["charkle-cli", "--compact", "overview"]);
        assert!(!should_pretty_print(&cli_compact, true));

        let cli_pretty = Cli::parse_from(["charkle-cli", "--pretty", "overview"]);
        assert!(should_pretty_print(&cli_pretty, false));

        let raw = "{\n  \"a\": 1,\n  \"b\": 2\n}";
        let compact = format_json_output(raw, false);
        assert!(!compact.contains('\n'));
        assert_eq!(compact, r#"{"a":1,"b":2}"#);
    }

    #[test]
    fn parses_v122_cli_aliases_and_batch_asset_ids() {
        let sem = Cli::parse_from([
            "charkle-cli",
            "semantic",
            "--queries",
            "人物动态,夏日海边晴空,极简白底",
            "--tone",
            "cool",
            "--fast",
            "--diversify",
            "--out",
            "brief.jpg",
        ]);
        assert!(matches!(sem.command, Some(Commands::SemanticSearch { .. })));

        let batch = Cli::parse_from(["charkle-cli", "asset", "69ED8DCB", "A1B2C3D4"]);
        match batch.command {
            Some(Commands::Asset { ids, .. }) => {
                assert_eq!(ids, vec!["69ED8DCB".to_string(), "A1B2C3D4".to_string()]);
            }
            other => panic!("expected Asset command, got {other:?}"),
        }

        assert_eq!(board_selector("69ED8DCB")["board_id"], "69ED8DCB");
        assert_eq!(folder_selector("69ED8DCB")["folder_id"], "69ED8DCB");
        assert_eq!(
            folder_selector("插画/ClearLine")["folder_path"],
            "插画/ClearLine"
        );
    }
}
