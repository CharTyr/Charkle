//! Windows mounted volume health inspector (`GetDriveTypeW` / `GetVolumeInformationW`)
//! and optional `gdirect.exe` sidecar detection.

#![allow(unsafe_code)]

use std::path::{Component, Path, PathBuf};

use charkle_core::traits::VolumeMountInspector;
use serde::{Deserialize, Serialize};

#[cfg(target_os = "windows")]
use windows::core::PCWSTR;
#[cfg(target_os = "windows")]
use windows::Win32::Storage::FileSystem::{GetDriveTypeW, GetVolumeInformationW};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WindowsDriveKind {
    Unknown,
    NoRootDir,
    Removable,
    Fixed,
    Remote,
    CdRom,
    RamDisk,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MountInspection {
    pub path: String,
    pub available: bool,
    pub drive_kind: WindowsDriveKind,
    pub volume_label: Option<String>,
    pub file_system: Option<String>,
}

/// Concrete Win32 `VolumeMountInspector` verifying mounted drives (Google Drive Desktop `G:\`,
/// `rclone`, WinFsp, UNC shares, and local folders).
#[derive(Debug, Default, Clone, Copy)]
pub struct WinVolumeMountInspector;

impl WinVolumeMountInspector {
    pub fn new() -> Self {
        Self
    }
}

impl VolumeMountInspector for WinVolumeMountInspector {
    fn is_mount_available(&self, path: &Path) -> bool {
        inspect_mount(path).available
    }
}

fn extract_root_drive(path: &Path) -> Option<String> {
    let mut comps = path.components();
    match comps.next() {
        Some(Component::Prefix(prefix)) => {
            let raw = prefix.as_os_str().to_string_lossy();
            let clean = if let Some(unc) = raw.strip_prefix(r"\\?\UNC\") {
                format!(r"\\{unc}")
            } else if let Some(verbatim) = raw.strip_prefix(r"\\?\") {
                verbatim.to_string()
            } else {
                raw.into_owned()
            };
            if clean.ends_with('\\') {
                Some(clean)
            } else {
                Some(format!("{clean}\\"))
            }
        }
        _ => None,
    }
}

/// Inspects a mount path via `GetDriveTypeW` + `GetVolumeInformationW` and directory readability.
pub fn inspect_mount(path: &Path) -> MountInspection {
    #[cfg(target_os = "windows")]
    {
        let root_str = extract_root_drive(path);
        let mut drive_kind = WindowsDriveKind::Unknown;
        let mut volume_label = None;
        let mut file_system = None;

        if let Some(ref root) = root_str {
            let wide: Vec<u16> = root.encode_utf16().chain(std::iter::once(0)).collect();
            // SAFETY: `wide` is a NUL-terminated UTF-16 root path.
            let raw_type = unsafe { GetDriveTypeW(PCWSTR(wide.as_ptr())) };
            drive_kind = match raw_type {
                1 => WindowsDriveKind::NoRootDir,
                2 => WindowsDriveKind::Removable,
                3 => WindowsDriveKind::Fixed,
                4 => WindowsDriveKind::Remote,
                5 => WindowsDriveKind::CdRom,
                6 => WindowsDriveKind::RamDisk,
                _ => WindowsDriveKind::Unknown,
            };

            if matches!(
                drive_kind,
                WindowsDriveKind::Fixed
                    | WindowsDriveKind::Remote
                    | WindowsDriveKind::Removable
                    | WindowsDriveKind::RamDisk
            ) {
                let mut label_buf = [0u16; 261];
                let mut fs_buf = [0u16; 64];
                // SAFETY: Output UTF-16 slices live on the stack for the duration of the call.
                let ok = unsafe {
                    GetVolumeInformationW(
                        PCWSTR(wide.as_ptr()),
                        Some(&mut label_buf),
                        None,
                        None,
                        None,
                        Some(&mut fs_buf),
                    )
                };
                if ok.is_ok() {
                    let lbl = utf16_cstr_to_string(&label_buf);
                    if !lbl.is_empty() {
                        volume_label = Some(lbl);
                    }
                    let fs = utf16_cstr_to_string(&fs_buf);
                    if !fs.is_empty() {
                        file_system = Some(fs);
                    }
                }
            }
        }

        let dir_readable = path.is_dir() && std::fs::read_dir(path).is_ok();
        let drive_ok = root_str.is_none()
            || !matches!(
                drive_kind,
                WindowsDriveKind::Unknown | WindowsDriveKind::NoRootDir
            );

        MountInspection {
            path: path.to_string_lossy().into_owned(),
            available: dir_readable && drive_ok,
            drive_kind,
            volume_label,
            file_system,
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        MountInspection {
            path: path.to_string_lossy().into_owned(),
            available: path.is_dir() && std::fs::read_dir(path).is_ok(),
            drive_kind: WindowsDriveKind::Fixed,
            volume_label: None,
            file_system: None,
        }
    }
}

#[cfg(target_os = "windows")]
fn utf16_cstr_to_string(buf: &[u16]) -> String {
    let len = buf.iter().position(|&c| c == 0).unwrap_or(buf.len());
    String::from_utf16_lossy(&buf[..len])
}

/// Searches standard locations and `PATH` for an optional Windows `gdirect.exe` sidecar binary.
pub fn detect_gdirect_binary() -> Option<PathBuf> {
    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let candidate = dir.join("gdirect.exe");
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }

    let mut extra_roots = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        extra_roots.push(PathBuf::from(&local).join("Charkle").join("bin"));
        extra_roots.push(PathBuf::from(local).join("gdirect"));
    }
    if let Some(pf) = std::env::var_os("ProgramFiles") {
        extra_roots.push(PathBuf::from(pf).join("gdirect"));
    }

    for dir in extra_roots {
        let candidate = dir.join("gdirect.exe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }

    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn mount_inspector_validates_existing_dir_and_rejects_unmounted_drive() {
        let dir = tempdir().expect("tempdir");
        let inspector = WinVolumeMountInspector::new();
        assert!(inspector.is_mount_available(dir.path()));

        let info = inspect_mount(dir.path());
        assert!(info.available);
        #[cfg(target_os = "windows")]
        assert_ne!(info.drive_kind, WindowsDriveKind::NoRootDir);

        let missing = Path::new(r"Z:\__charkle_nonexistent_mount_probe__");
        assert!(!inspector.is_mount_available(missing));
    }

    #[test]
    fn gdirect_detection_completes_without_error() {
        let _ = detect_gdirect_binary();
    }
}
