//! Windows Credential Manager + DPAPI encrypted secret storage (`SecretVault`).
//!
//! Stores OAuth tokens, WebDAV passwords, and AI keys encrypted by Windows DPAPI
//! inside Windows Credential Manager (`CredWriteW` / `CredReadW` / `CredDeleteW`)
//! with strict RAII cleanup of all Win32 memory handles.

#![allow(unsafe_code)]

use async_trait::async_trait;
use charkle_core::traits::SecretVault;

#[cfg(target_os = "windows")]
use windows::core::{PCWSTR, PWSTR};
#[cfg(target_os = "windows")]
use windows::Win32::Foundation::{LocalFree, ERROR_NOT_FOUND, HLOCAL};
#[cfg(target_os = "windows")]
use windows::Win32::Security::Credentials::{
    CredDeleteW, CredFree, CredReadW, CredWriteW, CREDENTIALW, CRED_PERSIST_LOCAL_MACHINE,
    CRED_TYPE_GENERIC,
};
#[cfg(target_os = "windows")]
use windows::Win32::Security::Cryptography::{
    CryptProtectData, CryptUnprotectData, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
};

#[cfg(target_os = "windows")]
struct LocalMemGuard(*mut u8);

#[cfg(target_os = "windows")]
impl Drop for LocalMemGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: Pointer was allocated by CryptProtectData / CryptUnprotectData via LocalAlloc.
            unsafe {
                let _ = LocalFree(HLOCAL(self.0.cast()));
            }
        }
    }
}

#[cfg(target_os = "windows")]
struct CredGuard(*mut CREDENTIALW);

#[cfg(target_os = "windows")]
impl Drop for CredGuard {
    fn drop(&mut self) {
        if !self.0.is_null() {
            // SAFETY: Pointer was allocated by CredReadW and must be released via CredFree.
            unsafe {
                CredFree(self.0.cast());
            }
        }
    }
}

#[cfg(target_os = "windows")]
fn to_wide_null(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// Encrypts raw bytes for the current Windows user account using DPAPI (`CryptProtectData`).
#[cfg(target_os = "windows")]
pub fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(plaintext.len()).map_err(|_| "Secret exceeds DPAPI size limit")?,
        pbData: plaintext.as_ptr() as *mut u8,
    };
    let mut out_blob = CRYPT_INTEGER_BLOB::default();
    // SAFETY: `in_blob` points to valid slice memory for the duration of the call; `out_blob`
    // receives an OS-allocated buffer guarded immediately by `LocalMemGuard`.
    unsafe {
        CryptProtectData(
            &in_blob,
            PCWSTR::null(),
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
        .map_err(|e| format!("CryptProtectData failed: {e}"))?;
    }
    let _guard = LocalMemGuard(out_blob.pbData);
    if out_blob.pbData.is_null() || out_blob.cbData == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: `out_blob.pbData` is valid for `out_blob.cbData` bytes until `_guard` drops.
    let protected =
        unsafe { std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize) }.to_vec();
    Ok(protected)
}

/// Decrypts DPAPI-protected bytes for the current Windows user account (`CryptUnprotectData`).
#[cfg(target_os = "windows")]
pub fn dpapi_unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    if ciphertext.is_empty() {
        return Ok(Vec::new());
    }
    let in_blob = CRYPT_INTEGER_BLOB {
        cbData: u32::try_from(ciphertext.len()).map_err(|_| "Ciphertext exceeds DPAPI limit")?,
        pbData: ciphertext.as_ptr() as *mut u8,
    };
    let mut out_blob = CRYPT_INTEGER_BLOB::default();
    // SAFETY: `in_blob` references valid slice bytes; `out_blob` is released by `LocalMemGuard`.
    unsafe {
        CryptUnprotectData(
            &in_blob,
            None,
            None,
            None,
            None,
            CRYPTPROTECT_UI_FORBIDDEN,
            &mut out_blob,
        )
        .map_err(|e| format!("CryptUnprotectData failed: {e}"))?;
    }
    let _guard = LocalMemGuard(out_blob.pbData);
    if out_blob.pbData.is_null() || out_blob.cbData == 0 {
        return Ok(Vec::new());
    }
    // SAFETY: `out_blob.pbData` is valid for `out_blob.cbData` bytes until `_guard` drops.
    let plain =
        unsafe { std::slice::from_raw_parts(out_blob.pbData, out_blob.cbData as usize) }.to_vec();
    Ok(plain)
}

#[cfg(not(target_os = "windows"))]
pub fn dpapi_protect(plaintext: &[u8]) -> Result<Vec<u8>, String> {
    Ok(plaintext.to_vec())
}

#[cfg(not(target_os = "windows"))]
pub fn dpapi_unprotect(ciphertext: &[u8]) -> Result<Vec<u8>, String> {
    Ok(ciphertext.to_vec())
}

/// Concrete Windows Credential Manager + DPAPI implementation of `SecretVault`.
#[derive(Debug, Clone)]
pub struct WinCredentialVault {
    target_prefix: String,
    #[cfg(not(target_os = "windows"))]
    fallback: std::sync::Arc<charkle_core::traits::InMemorySecretVault>,
}

impl Default for WinCredentialVault {
    fn default() -> Self {
        Self::new()
    }
}

impl WinCredentialVault {
    pub fn new() -> Self {
        Self::with_prefix("Charkle:")
    }

    pub fn with_prefix(prefix: impl Into<String>) -> Self {
        Self {
            target_prefix: prefix.into(),
            #[cfg(not(target_os = "windows"))]
            fallback: std::sync::Arc::new(charkle_core::traits::InMemorySecretVault::new()),
        }
    }

    fn target_name(&self, key: &str) -> String {
        format!("{}{}", self.target_prefix, key.trim())
    }
}

#[async_trait]
impl SecretVault for WinCredentialVault {
    async fn get_secret(&self, key: &str) -> Result<Option<String>, String> {
        #[cfg(target_os = "windows")]
        {
            let target = self.target_name(key);
            tokio::task::spawn_blocking(move || read_credential(&target))
                .await
                .map_err(|e| format!("Credential read task failed: {e}"))?
        }
        #[cfg(not(target_os = "windows"))]
        {
            self.fallback.get_secret(key).await
        }
    }

    async fn set_secret(&self, key: &str, value: &str) -> Result<(), String> {
        #[cfg(target_os = "windows")]
        {
            let target = self.target_name(key);
            let value_owned = value.to_string();
            tokio::task::spawn_blocking(move || write_credential(&target, &value_owned))
                .await
                .map_err(|e| format!("Credential write task failed: {e}"))?
        }
        #[cfg(not(target_os = "windows"))]
        {
            self.fallback.set_secret(key, value).await
        }
    }

    async fn delete_secret(&self, key: &str) -> Result<(), String> {
        #[cfg(target_os = "windows")]
        {
            let target = self.target_name(key);
            tokio::task::spawn_blocking(move || delete_credential(&target))
                .await
                .map_err(|e| format!("Credential delete task failed: {e}"))?
        }
        #[cfg(not(target_os = "windows"))]
        {
            self.fallback.delete_secret(key).await
        }
    }
}

#[cfg(any(target_os = "windows", test))]
const MAX_CREDENTIAL_BLOB_BYTES: usize = 2560;
#[cfg(any(target_os = "windows", test))]
const CREDENTIAL_CHUNK_BYTES: usize = 2048;
#[cfg(any(target_os = "windows", test))]
const MAX_CREDENTIAL_CHUNKS: usize = 32;
#[cfg(any(target_os = "windows", test))]
const CHUNK_MANIFEST_PREFIX: &[u8] = b"CHARKLE_CRED_CHUNKED_V1:";

#[cfg(any(target_os = "windows", test))]
fn build_chunk_manifest(count: usize) -> Vec<u8> {
    format!(
        "{}{}",
        std::str::from_utf8(CHUNK_MANIFEST_PREFIX).unwrap_or("CHARKLE_CRED_CHUNKED_V1:"),
        count
    )
    .into_bytes()
}

#[cfg(any(target_os = "windows", test))]
fn parse_chunk_manifest(blob: &[u8]) -> Option<usize> {
    let rest = blob.strip_prefix(CHUNK_MANIFEST_PREFIX)?;
    let count_str = std::str::from_utf8(rest).ok()?;
    let count = count_str.parse::<usize>().ok()?;
    if (1..=MAX_CREDENTIAL_CHUNKS).contains(&count) {
        Some(count)
    } else {
        None
    }
}

#[cfg(any(target_os = "windows", test))]
fn chunk_target_name(target: &str, idx: usize) -> String {
    format!("{target}#part:{idx}")
}

#[cfg(target_os = "windows")]
fn read_raw_credential_blob(target: &str) -> Result<Option<Vec<u8>>, String> {
    let target_wide = to_wide_null(target);
    let mut cred_ptr: *mut CREDENTIALW = std::ptr::null_mut();
    // SAFETY: `target_wide` is NUL-terminated UTF-16; returned pointer is released by `CredGuard`.
    let res = unsafe {
        CredReadW(
            PCWSTR(target_wide.as_ptr()),
            CRED_TYPE_GENERIC,
            0,
            &mut cred_ptr,
        )
    };
    if let Err(err) = res {
        if err.code() == ERROR_NOT_FOUND.to_hresult() {
            return Ok(None);
        }
        return Err(format!("CredReadW failed: {err}"));
    }
    let _guard = CredGuard(cred_ptr);
    if cred_ptr.is_null() {
        return Ok(None);
    }
    // SAFETY: `cred_ptr` was populated by `CredReadW` and stays live until `_guard` drops.
    let blob = unsafe {
        let cred = &*cred_ptr;
        if cred.CredentialBlob.is_null() || cred.CredentialBlobSize == 0 {
            Vec::new()
        } else {
            std::slice::from_raw_parts(cred.CredentialBlob, cred.CredentialBlobSize as usize)
                .to_vec()
        }
    };
    Ok(Some(blob))
}

#[cfg(target_os = "windows")]
fn write_raw_credential_blob(target: &str, blob: &[u8]) -> Result<(), String> {
    if blob.len() > MAX_CREDENTIAL_BLOB_BYTES {
        return Err(format!(
            "Credential blob ({} bytes) exceeds Windows CRED_MAX_CREDENTIAL_BLOB_SIZE ({})",
            blob.len(),
            MAX_CREDENTIAL_BLOB_BYTES
        ));
    }
    let mut owned_blob = blob.to_vec();
    let mut target_wide = to_wide_null(target);
    let mut user_wide = to_wide_null("charkle");

    let cred = CREDENTIALW {
        Type: CRED_TYPE_GENERIC,
        TargetName: PWSTR(target_wide.as_mut_ptr()),
        CredentialBlobSize: u32::try_from(owned_blob.len())
            .map_err(|_| "Encrypted credential exceeds limit")?,
        CredentialBlob: owned_blob.as_mut_ptr(),
        Persist: CRED_PERSIST_LOCAL_MACHINE,
        UserName: PWSTR(user_wide.as_mut_ptr()),
        ..Default::default()
    };

    // SAFETY: All pointers inside `cred` reference live stack-owned buffers for this call.
    unsafe { CredWriteW(&cred, 0) }.map_err(|e| format!("CredWriteW failed: {e}"))?;
    Ok(())
}

#[cfg(target_os = "windows")]
fn delete_raw_credential_blob(target: &str) -> Result<(), String> {
    let target_wide = to_wide_null(target);
    // SAFETY: `target_wide` is a valid NUL-terminated UTF-16 string.
    let res = unsafe { CredDeleteW(PCWSTR(target_wide.as_ptr()), CRED_TYPE_GENERIC, 0) };
    if let Err(err) = res {
        if err.code() == ERROR_NOT_FOUND.to_hresult() {
            return Ok(());
        }
        return Err(format!("CredDeleteW failed: {err}"));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn read_credential(target: &str) -> Result<Option<String>, String> {
    let Some(raw_blob) = read_raw_credential_blob(target)? else {
        return Ok(None);
    };
    let ciphertext = if let Some(chunk_count) = parse_chunk_manifest(&raw_blob) {
        let mut combined = Vec::with_capacity(chunk_count * CREDENTIAL_CHUNK_BYTES);
        for idx in 0..chunk_count {
            let part_target = chunk_target_name(target, idx);
            let part = read_raw_credential_blob(&part_target)?.ok_or_else(|| {
                format!("Incomplete chunked credential: missing part {idx} of {chunk_count}")
            })?;
            combined.extend_from_slice(&part);
        }
        combined
    } else {
        raw_blob
    };

    // Fail closed if DPAPI decryption fails rather than returning unverified/corrupted bytes.
    let plain = dpapi_unprotect(&ciphertext)
        .map_err(|e| format!("Credential DPAPI decryption failed: {e}"))?;
    String::from_utf8(plain)
        .map(Some)
        .map_err(|e| format!("Credential UTF-8 decode failed: {e}"))
}

#[cfg(target_os = "windows")]
fn write_credential(target: &str, value: &str) -> Result<(), String> {
    let encrypted = dpapi_protect(value.as_bytes())?;
    let old_chunk_count = read_raw_credential_blob(target)
        .ok()
        .flatten()
        .and_then(|blob| parse_chunk_manifest(&blob))
        .unwrap_or(0);

    if encrypted.len() <= MAX_CREDENTIAL_BLOB_BYTES {
        write_raw_credential_blob(target, &encrypted)?;
        for idx in 0..old_chunk_count {
            let _ = delete_raw_credential_blob(&chunk_target_name(target, idx));
        }
        return Ok(());
    }

    let chunks: Vec<&[u8]> = encrypted.chunks(CREDENTIAL_CHUNK_BYTES).collect();
    if chunks.len() > MAX_CREDENTIAL_CHUNKS {
        return Err(format!(
            "Encrypted credential ({} bytes) exceeds maximum chunked vault capacity",
            encrypted.len()
        ));
    }

    for (idx, chunk) in chunks.iter().enumerate() {
        write_raw_credential_blob(&chunk_target_name(target, idx), chunk)?;
    }
    let manifest = build_chunk_manifest(chunks.len());
    write_raw_credential_blob(target, &manifest)?;

    for idx in chunks.len()..old_chunk_count {
        let _ = delete_raw_credential_blob(&chunk_target_name(target, idx));
    }
    Ok(())
}

#[cfg(target_os = "windows")]
fn delete_credential(target: &str) -> Result<(), String> {
    let old_chunk_count = read_raw_credential_blob(target)
        .ok()
        .flatten()
        .and_then(|blob| parse_chunk_manifest(&blob))
        .unwrap_or(0);
    for idx in 0..old_chunk_count {
        let _ = delete_raw_credential_blob(&chunk_target_name(target, idx));
    }
    delete_raw_credential_blob(target)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dpapi_encrypts_and_decrypts_round_trip() {
        let secret = b"charkle-secret-token-2026-\xe4\xb8\xad\xe6\x96\x87";
        let cipher = dpapi_protect(secret).expect("dpapi protect");
        #[cfg(target_os = "windows")]
        assert_ne!(cipher.as_slice(), secret);
        let plain = dpapi_unprotect(&cipher).expect("dpapi unprotect");
        assert_eq!(plain.as_slice(), secret);
    }

    #[tokio::test]
    async fn credential_manager_vault_round_trips_and_deletes_cleanly() {
        let vault = WinCredentialVault::with_prefix("CharkleTest:");
        let key = format!("test-key-{}", std::process::id());

        vault.set_secret(&key, "s3cr3t-value").await.expect("set");
        let loaded = vault.get_secret(&key).await.expect("get");
        assert_eq!(loaded.as_deref(), Some("s3cr3t-value"));

        vault.delete_secret(&key).await.expect("delete");
        let after = vault.get_secret(&key).await.expect("get after delete");
        assert_eq!(after, None);
    }
}
