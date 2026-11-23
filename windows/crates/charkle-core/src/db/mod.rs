//! SQLite WAL + FTS5 + Chinese pinyin + CIELAB + vector database layer.

pub mod library_db;
pub mod search_text;

pub use library_db::{stable_uuid, LibraryDatabase, MigrationRequeueCounts};
