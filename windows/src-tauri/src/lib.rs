//! Tauri v2 desktop shell skeleton (M1 scaffold; full Tauri IPC & WebView2 chrome land in M2).

pub fn init_platform_stubs() -> charkle_platform_win::WinSecretVaultStub {
    charkle_platform_win::WinSecretVaultStub::new()
}
