//! Pinterest infinite spatial exploration, JSON/HTML parsing, bidirectional layout math,
//! and batch pin/board ingestion mirroring `Sources/CharkleCore/Services/Pinterest/`.

pub mod import_service;
pub mod models;
pub mod parser;

pub use import_service::{PinterestImportService, PinterestMediaPayload};
pub use models::{
    InfiniteSpatialCamera, PinterestAccount, PinterestBatchImportReport, PinterestBoard,
    PinterestBoardImportDestination, PinterestBoardImportProgress, PinterestBoardsImportReport,
    PinterestBoardsPage, PinterestFeedPage, PinterestFeedSource, PinterestPin,
    PinterestPinDetailResult, PinterestSpatialCard, PinterestSpatialLayout, SpatialPoint,
    SpatialRect, SpatialSize,
};
pub use parser::PinterestJSONParser;
