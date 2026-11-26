import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it, vi } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import { AdvancedAboutSettingsPane } from '../features/settings/SettingsPanesCaptureSystem';
import { SyncSettingsPane } from '../features/settings/SettingsPanesFoundation';
import { AppUpdateModal } from '../features/updates/AppUpdateModal';
import { useAppUpdateStore, useCoordinatorStore, useSyncAIStore } from '../stores';
import { isDirectGoogleDriveAccount, type AppReleaseUpdate } from '../types/domain';

const SAMPLE_UPDATE: AppReleaseUpdate = {
  tagName: 'v1.5.0',
  version: '1.5.0',
  title: 'Charkle 1.5.0',
  releaseNotes:
    '## Windows 11\n- 新增应用内自动检查更新与 SHA-256 校验\n- 修复云同步账号显示<script>alert(1)</script>',
  htmlUrl: 'https://github.com/CharTyr/Charkle/releases/tag/v1.5.0',
  publishedAt: '2026-11-26T12:00:00Z',
  assetName: 'Charkle_1.5.0_x64-setup.exe',
  downloadUrl:
    'https://github.com/CharTyr/Charkle/releases/download/v1.5.0/Charkle_1.5.0_x64-setup.exe',
  assetSizeBytes: 21_400_000,
  expectedSha256: '1dc089f37e073529daeb95cb4709896132ebe045b557bb03ac8326c3ee00620b',
};

describe('Windows In-App Updater, Cloud Sync Account Isolation & gdirect Installer', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    mock = new InMemoryMockTransport(false);
    setTransport(mock);
    useAppUpdateStore.getState().resetForTests();
    useCoordinatorStore.setState({ toasts: [] });
    useSyncAIStore.setState({
      syncConfig: null,
      syncStatus: null,
      diagnostics: null,
      installingGDirect: false,
      gdirectInstallProgress: null,
      hasGoogleOAuthClient: false,
    });
  });

  it('runs manual check, downloads with SHA-256 verification, and falls back to manual install on launch error', async () => {
    mock.mockAvailableUpdate = SAMPLE_UPDATE;
    mock.mockInstallError = 'Access denied launching setup';

    const store = useAppUpdateStore.getState();
    await store.checkForUpdatesManually({ presentSheet: true });

    expect(useAppUpdateStore.getState().sheetOpen).toBe(true);
    expect(useAppUpdateStore.getState().state.status).toBe('available');

    await useAppUpdateStore.getState().startDownload();
    const ready = useAppUpdateStore.getState().state;
    expect(ready.status).toBe('readyToInstall');
    if (ready.status === 'readyToInstall') {
      expect(ready.installer.checksumVerifiedAgainstRelease).toBe(true);
      expect(ready.installer.verifiedSha256).toBe(SAMPLE_UPDATE.expectedSha256);
    }

    await useAppUpdateStore.getState().installAndRelaunch();
    const fallback = useAppUpdateStore.getState().state;
    expect(fallback.status).toBe('manualInstallRequired');

    await useAppUpdateStore.getState().openDownloadedInstaller();
    await useAppUpdateStore.getState().revealDownloadedInstaller();
    expect(mock.mockOpenedInstallerPaths).toHaveLength(1);
    expect(mock.mockRevealedInstallerPaths).toHaveLength(1);
  });

  it('supports skip version and respects 6-hour deferred launch throttle', async () => {
    mock.mockAvailableUpdate = SAMPLE_UPDATE;
    await useAppUpdateStore.getState().checkForUpdatesManually({ presentSheet: true });
    await useAppUpdateStore.getState().skipCurrentUpdate();

    expect(useAppUpdateStore.getState().skippedVersion).toBe('1.5.0');
    expect(useAppUpdateStore.getState().sheetOpen).toBe(false);

    // Clear skip and verify automatic check notifies once when outside throttle window
    await useAppUpdateStore.getState().clearSkippedVersion();
    expect(useAppUpdateStore.getState().skippedVersion).toBeNull();

    // Force fresh transport without prior lastUpdateCheckAtMs
    const freshMock = new InMemoryMockTransport(false);
    freshMock.mockAvailableUpdate = SAMPLE_UPDATE;
    setTransport(freshMock);
    useAppUpdateStore.getState().resetForTests();

    const discovered = vi.fn();
    useAppUpdateStore.getState().scheduleDeferredLaunchCheck(discovered, 5);
    await waitFor(() => expect(discovered).toHaveBeenCalledTimes(1));
    expect(discovered).toHaveBeenCalledWith(SAMPLE_UPDATE);
  });

  it('renders AppUpdateModal with sanitized Markdown notes and verified SHA-256 badge', async () => {
    mock.mockAvailableUpdate = SAMPLE_UPDATE;
    await useAppUpdateStore.getState().checkForUpdatesManually({ presentSheet: true });

    render(<AppUpdateModal />);

    expect(await screen.findByText('发现新版本 v1.5.0')).toBeInTheDocument();
    expect(screen.getByText(/v1\.4\.0 → v1\.5\.0/)).toBeInTheDocument();
    expect(screen.getByText(/新增应用内自动检查更新与 SHA-256 校验/)).toBeInTheDocument();
    // Script tag must be stripped by DOMPurify
    expect(document.querySelector('script')).toBeNull();

    fireEvent.click(screen.getByRole('button', { name: /下载更新/ }));
    expect(await screen.findByText(/SHA-256 校验已通过/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '安装并重启' })).toBeInTheDocument();
  });

  it('never treats a Local Folder path as a connected Google Drive account', () => {
    expect(
      isDirectGoogleDriveAccount({
        email: 'C:\\Users\\demo\\Pictures',
        displayName: 'C:\\Users\\demo\\Pictures',
        source: 'Local Folder',
      }),
    ).toBe(false);

    expect(
      isDirectGoogleDriveAccount({
        email: 'G:\\My Drive',
        displayName: 'G:\\My Drive',
        source: 'Mounted Drive',
      }),
    ).toBe(false);

    expect(
      isDirectGoogleDriveAccount({
        email: 'designer@example.com',
        displayName: 'Designer',
        source: 'Google Drive API v3',
      }),
    ).toBe(true);

    useSyncAIStore.setState({
      syncConfig: {
        mode: 'directAPIWithGDirect',
        rootFolderName: 'Charkle',
        sharedFolderURLOrID: '',
        mountPath: 'G:\\',
        selectedGDirectAccount: null,
        useGDirectIPAcceleration: true,
        webDAVServerURL: '',
        webDAVUsername: '',
        webDAVRemotePath: '/Charkle',
        localLibraryPath: 'C:\\Users\\demo\\Pictures\\Charkle',
        autoSyncIntervalSeconds: 120,
        syncThumbnails: true,
        syncEmbeddings: true,
      },
      syncStatus: {
        phase: 'idle',
        pendingOpCount: 0,
        activeMode: 'directAPIWithGDirect',
        account: {
          email: 'C:\\Users\\demo\\Pictures',
          displayName: 'C:\\Users\\demo\\Pictures',
          source: 'Local Folder',
        },
      },
    });

    render(<SyncSettingsPane />);
    expect(screen.getByText('未登录 Google 账号')).toBeInTheDocument();
    expect(screen.queryByText('已直连')).not.toBeInTheDocument();
    expect(screen.queryByText('C:\\Users\\demo\\Pictures')).not.toBeInTheDocument();
  });

  it('installs gdirect CLI in-app and checks updates inline inside AdvancedAboutSettingsPane', async () => {
    await act(async () => {
      await useSyncAIStore.getState().refreshSettingsData();
    });

    render(<AdvancedAboutSettingsPane />);

    // gdirect starts uninstalled -> one-click install button is enabled and visible
    const installBtn = screen.getByRole('button', { name: /一键安装 gdirect/ });
    expect(installBtn).not.toBeDisabled();
    fireEvent.click(installBtn);

    // After install, diagnostics refresh reveals installed v0.13.2 + toggle switch
    expect(await screen.findByText(/已安装 v0\.13\.2/)).toBeInTheDocument();
    expect(screen.getByRole('button', { name: '更新 / 重装' })).toBeInTheDocument();

    // Inline software update check (up-to-date case)
    const checkBtn = screen.getByRole('button', { name: /立即检查更新/ });
    fireEvent.click(checkBtn);
    expect(await screen.findByText(/当前已是最新正式版本 v1\.4\.0/)).toBeInTheDocument();
  });
});
