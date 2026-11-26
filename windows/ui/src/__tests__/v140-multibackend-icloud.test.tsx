import { act, fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  LibrarySettingsPane,
  StorageLocationWizardModal,
  SyncSettingsPane,
} from '../features/settings/SettingsPanesFoundation';
import { useCoordinatorStore, useSyncAIStore } from '../stores';
import {
  LEGACY_PRIMARY_BACKEND_ID,
  isDirectGoogleDriveAccount,
  type DriveSyncConfig,
} from '../types/domain';

describe('Charkle v1.4.0 Multi-Backend Sync & iCloud Drive UI', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    mock = new InMemoryMockTransport(false);
    setTransport(mock);
    useCoordinatorStore.setState({ toasts: [] });
    useSyncAIStore.setState({
      syncConfig: null,
      syncStatus: null,
      iCloudAvailability: {
        isUbiquityContainerAvailable: false,
        ubiquityDocumentsPath: null,
        systemCloudDocsPath: '%USERPROFILE%\\iCloudDrive',
        defaultDisplayLocation: 'iCloud Drive / Charkle',
      },
      lastSyncReport: null,
      lastMigrationReport: null,
      diagnostics: null,
      syncing: false,
      syncingBackendId: null,
      migrating: false,
      testingWebdav: false,
      testingBackend: false,
      signingInGoogle: false,
      hasGoogleOAuthClient: false,
      hasWebdavPassword: false,
      statusMessage: null,
      errorMessage: null,
    });
  });

  it('never classifies an iCloud Drive account as a Google Drive Direct API account', () => {
    expect(
      isDirectGoogleDriveAccount({
        email: 'iCloud Drive / Charkle',
        displayName: 'iCloud Drive',
        source: 'iCloud Drive',
      }),
    ).toBe(false);
  });

  it('allows enabling iCloud Drive directly from local-only onboarding and shows iCloud status card', async () => {
    const localCfg: DriveSyncConfig = {
      mode: 'localOnly',
      rootFolderName: 'Charkle',
      sharedFolderURLOrID: '',
      mountPath: 'G:\\',
      selectedGDirectAccount: null,
      useGDirectIPAcceleration: true,
      iCloudFolderName: 'Charkle',
      iCloudCustomFolderPath: '',
      webDAVServerURL: '',
      webDAVUsername: '',
      webDAVRemotePath: '/Charkle',
      localLibraryPath: 'D:\\CharkleLocal',
      autoSyncIntervalSeconds: 120,
      syncThumbnails: true,
      syncEmbeddings: true,
      backends: [],
    };
    await mock.saveSyncConfig(localCfg);
    await useSyncAIStore.getState().refreshSyncAndCache();

    render(<SyncSettingsPane />);

    expect(screen.getByText('iCloud Drive 云同步')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '启用 iCloud Drive' }));

    await waitFor(() => {
      expect(useSyncAIStore.getState().syncConfig?.mode).toBe('iCloudDrive');
    });

    expect(await screen.findByTestId('sync-backends-section')).toBeInTheDocument();
    expect(screen.getByTestId('sync-icloud-status-section')).toBeInTheDocument();
    expect(screen.getByText(/%USERPROFILE%\\iCloudDrive/)).toBeInTheDocument();
  });

  it('supports simultaneous multi-backend management (add secondary iCloud, toggle, set primary, remove) and multi-backend Library headline', async () => {
    const googleCfg: DriveSyncConfig = {
      mode: 'directAPIWithGDirect',
      rootFolderName: 'StudioLib',
      sharedFolderURLOrID: '',
      mountPath: 'G:\\',
      selectedGDirectAccount: null,
      useGDirectIPAcceleration: true,
      iCloudFolderName: 'Charkle',
      iCloudCustomFolderPath: '',
      webDAVServerURL: '',
      webDAVUsername: '',
      webDAVRemotePath: '/Charkle',
      localLibraryPath: '',
      autoSyncIntervalSeconds: 120,
      syncThumbnails: true,
      syncEmbeddings: true,
      backends: [],
    };
    await mock.saveSyncConfig(googleCfg);
    await useSyncAIStore.getState().refreshSyncAndCache();

    const { rerender } = render(<SyncSettingsPane />);

    // Initially 1 primary backend row
    expect(screen.getAllByTestId('sync-backend-row')).toHaveLength(1);

    // Add a secondary iCloud Drive backend via store action (same path as BackendProfileEditorModal)
    let ok = false;
    await act(async () => {
      ok = await useSyncAIStore.getState().upsertBackend({
        id: '11111111-2222-3333-4444-555555555555',
        name: 'iCloud 同步镜像',
        mode: 'iCloudDrive',
        isEnabled: true,
        isPrimary: false,
        rootFolderName: 'Charkle',
        sharedFolderURLOrID: '',
        mountPath: 'G:\\',
        selectedGDirectAccount: null,
        useGDirectIPAcceleration: true,
        iCloudFolderName: 'CharkleMirror',
        iCloudCustomFolderPath: '',
        iCloudContainerIdentifier: '',
        webDAVServerURL: '',
        webDAVUsername: '',
        webDAVRemotePath: '/Charkle',
        localLibraryPath: '',
      });
    });
    expect(ok).toBe(true);

    await waitFor(() => {
      expect(screen.getAllByTestId('sync-backend-row')).toHaveLength(2);
    });
    expect(screen.getByText('iCloud 同步镜像')).toBeInTheDocument();
    expect(screen.getByText('并行镜像')).toBeInTheDocument();
    expect(screen.getByTestId('sync-icloud-status-section')).toBeInTheDocument();

    // Library pane displays multi-backend headline
    rerender(<LibrarySettingsPane />);
    expect(screen.getByText('多后端同时同步（2 个）')).toBeInTheDocument();

    // Promote secondary iCloud backend to primary
    let promoted = false;
    await act(async () => {
      promoted = await useSyncAIStore
        .getState()
        .setPrimaryBackend('11111111-2222-3333-4444-555555555555');
    });
    expect(promoted).toBe(true);
    expect(useSyncAIStore.getState().syncConfig?.mode).toBe('iCloudDrive');

    // Remove the old Google backend -> leaves 1 active primary iCloud backend
    let removed = false;
    await act(async () => {
      removed = await useSyncAIStore.getState().removeBackend(LEGACY_PRIMARY_BACKEND_ID);
    });
    expect(removed).toBe(true);
    expect(useSyncAIStore.getState().syncConfig?.backends).toHaveLength(1);
  });

  it('includes iCloud Drive option inside StorageLocationWizardModal and migrates cleanly', async () => {
    const localCfg: DriveSyncConfig = {
      mode: 'localOnly',
      rootFolderName: 'Charkle',
      sharedFolderURLOrID: '',
      mountPath: 'G:\\',
      selectedGDirectAccount: null,
      useGDirectIPAcceleration: true,
      iCloudFolderName: 'Charkle',
      iCloudCustomFolderPath: '',
      webDAVServerURL: '',
      webDAVUsername: '',
      webDAVRemotePath: '/Charkle',
      localLibraryPath: 'D:\\LocalLib',
      autoSyncIntervalSeconds: 120,
      syncThumbnails: true,
      syncEmbeddings: true,
      backends: [],
    };
    await mock.saveSyncConfig(localCfg);
    await useSyncAIStore.getState().refreshSyncAndCache();

    let closed = false;
    render(<StorageLocationWizardModal open onClose={() => { closed = true; }} />);

    const icloudBtn = screen.getByRole('radio', { name: 'iCloud Drive' });
    fireEvent.click(icloudBtn);

    const folderInput = screen.getByPlaceholderText('Charkle');
    fireEvent.change(folderInput, { target: { value: 'StudioICloud' } });

    fireEvent.click(screen.getByRole('button', { name: '开始无损迁移' }));

    await waitFor(() => {
      expect(closed).toBe(true);
      expect(useSyncAIStore.getState().syncConfig?.mode).toBe('iCloudDrive');
      expect(useSyncAIStore.getState().lastMigrationReport?.targetMode).toBe('iCloudDrive');
    });
  });
});
