//! Bidirectional `/.charkle/` sync engine, 6 storage transports, Google PKCE OAuth, and migration.

pub mod direct_api;
pub mod engine;
pub mod gdirect;
pub mod google_oauth;
pub mod icloud_drive;
pub mod in_memory;
pub mod local_folder;
pub mod transport;
pub mod webdav;

pub use direct_api::DirectAPITransport;
pub use engine::{
    validate_path_segments, DriveSyncEngine, StorageMigration, SyncExecutionOptions,
    SyncProgressiveEvent,
};
pub use google_oauth::{GoogleOAuthClient, GoogleOAuthClientConfig, GoogleOAuthToken};
pub use icloud_drive::{
    detect_windows_icloud_drive_root, probe_icloud_drive_availability, ICloudDriveTransport,
    ICLOUD_PATH_ID_PREFIX,
};
pub use in_memory::InMemoryDriveTransport;
pub use local_folder::{LocalFolderTransport, MountedVolumeTransport, MOUNTED_PATH_ID_PREFIX};
pub use transport::{
    sanitize_windows_filename, validate_drive_name, DriveTransport, DRIVE_ROOT_ID,
};
pub use webdav::WebDAVTransport;
