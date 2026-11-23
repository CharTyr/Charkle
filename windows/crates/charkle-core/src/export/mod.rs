//! High-DPI moodboard image compositor (`board_image.rs`) and offline lossless
//! `.charkleboard` Figma / FigJam Bridge ZIP exporter (`figma_bridge.rs`).

pub mod board_image;
pub mod figma_bridge;

pub use board_image::{BoardImageExporter, BoardImageFormat, MoodboardExportOptions};
pub use figma_bridge::{FigmaBridgeExportReport, FigmaBridgeExporter};
