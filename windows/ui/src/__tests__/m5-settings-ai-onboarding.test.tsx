import { fireEvent, render, screen, waitFor } from '@testing-library/react';
import { beforeEach, describe, expect, it } from 'vitest';
import { App } from '../App';
import { InMemoryMockTransport, setTransport } from '../api/transport';
import {
  useCoordinatorStore,
  useLibraryStore,
  useMoodboardStore,
  useSyncAIStore,
} from '../stores';
import { createDefaultFilterCriteria } from '../types/domain';

function resetStores() {
  useCoordinatorStore.setState({
    themeMode: 'light',
    surfaceState: null,
    sidebarOpen: true,
    inspectorOpen: true,
    layoutMode: 'verticalMasonry',
    cardScale: 236,
    destination: { type: 'allItems' },
    selectedAssetIds: [],
    lastSelectedAssetId: null,
    quickLookAssetId: null,
    quickLookOriginRect: null,
    jumpOpen: false,
    captureOpen: false,
    settingsOpen: false,
    settingsTab: 'general',
    onboardingOpen: false,
    onboardingDone: true,
    activeMoodboardId: null,
    toasts: [],
  });
  useLibraryStore.setState({
    assets: [],
    folders: [],
    smartFolders: [],
    tagCounts: [],
    inboxCount: 0,
    criteria: createDefaultFilterCriteria(),
    semanticSearch: false,
    loading: false,
    bootstrapped: false,
    error: null,
  });
  useMoodboardStore.setState({
    boards: [],
    activeBoard: null,
    loading: false,
    curating: false,
    agentTrace: [],
    candidatePool: [],
    selectedNodeIds: [],
    historyPast: [],
    historyFuture: [],
  });
  useSyncAIStore.setState({
    syncConfig: null,
    syncStatus: null,
    cacheStats: null,
    syncing: false,
    migrating: false,
    aiState: null,
    typesafeState: null,
    agentState: null,
    diagnostics: null,
  });
}

describe('Charkle Windows M5 9-Pane Settings Overlay, Hybrid AI, TypeSafe Jev, External Agent & Onboarding Studio', () => {
  let mock: InMemoryMockTransport;

  beforeEach(() => {
    localStorage.clear();
    mock = new InMemoryMockTransport(true);
    setTransport(mock);
    resetStores();
  });

  it('opens centered 9-pane Settings via Ctrl+, navigates all 9 panes, configures Cloud AI / Jev / External Agent / Lossless Migration, and re-runs skippable Onboarding Studio', async () => {
    render(<App />);

    await waitFor(() => {
      expect(screen.getByRole('button', { name: '打开设置中心' })).toBeInTheDocument();
    });

    // Open via Ctrl+,
    fireEvent.keyDown(window, { key: ',', ctrlKey: true });
    await waitFor(() => {
      expect(screen.getByTestId('settings-overlay')).toBeInTheDocument();
      expect(screen.getByTestId('settings-pane-general')).toBeInTheDocument();
    });

    // All 4 section headings exist
    expect(screen.getByText('基础与存储')).toBeInTheDocument();
    expect(screen.getByText('采集与操作')).toBeInTheDocument();
    expect(screen.getByText('生态与智能')).toBeInTheDocument();
    expect(screen.getByText('系统')).toBeInTheDocument();

    // Pane 2: Library (LRU slider + CacheStats)
    fireEvent.click(screen.getByRole('tab', { name: '素材库' }));
    expect(screen.getByTestId('settings-pane-library')).toBeInTheDocument();
    expect(screen.getByLabelText('本地缓存预算 GB')).toBeInTheDocument();

    // Pane 3: Sync + Lossless Storage Migration Wizard
    fireEvent.click(screen.getByRole('tab', { name: '云同步' }));
    expect(screen.getByTestId('settings-pane-sync')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('radio', { name: 'WebDAV' }));
    const migrateBtn = await screen.findByRole('button', { name: /无损迁移现有素材/ });
    fireEvent.click(migrateBtn);
    await waitFor(() => {
      expect(screen.getByTestId('storage-migration-report')).toBeInTheDocument();
    });

    // Pane 4 & 5: Drop Shelf + Capture Shortcuts
    fireEvent.click(screen.getByRole('tab', { name: '顶部悬浮窗' }));
    expect(screen.getByTestId('settings-pane-dropShelf')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('tab', { name: '采集与快捷键' }));
    expect(screen.getByTestId('settings-pane-captureShortcuts')).toBeInTheDocument();

    // Pane 6: Hybrid Cloud AI + Usage Telemetry + WinRT OCR + TypeSafe Jev
    fireEvent.click(screen.getByRole('tab', { name: 'AI 智能' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-ai')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole('button', { name: 'Gemini' }));
    const keyInput = screen.getByLabelText('云端 AI API 密钥');
    fireEvent.change(keyInput, { target: { value: 'AIza-mock-secret' } });
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => {
      expect(screen.getByTestId('ai-test-result')).toBeInTheDocument();
    });
    expect(useSyncAIStore.getState().aiState?.hasApiKey).toBe(true);

    // Enable TypeSafe Jev
    fireEvent.click(screen.getByLabelText('启用 TypeSafe Jev'));
    fireEvent.change(screen.getByLabelText('TypeSafe API 密钥'), {
      target: { value: 'ts-mock-key' },
    });
    fireEvent.click(screen.getByRole('button', { name: '保存 Jev 配置' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().typesafeState?.config.enabled).toBe(true);
      expect(useSyncAIStore.getState().typesafeState?.hasApiKey).toBe(true);
    });

    // Pane 7: External Agent independent MCP / CLI toggles + access policy + MCP JSON
    fireEvent.click(screen.getByRole('tab', { name: '外部 Agent' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-externalAgents')).toBeInTheDocument();
    });
    expect(screen.getByTestId('mcp-config-json-snippet').textContent).toContain('charkle-cli.exe');

    fireEvent.click(screen.getByLabelText('启用 MCP 服务'));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.mcpEnabled).toBe(false);
      expect(useSyncAIStore.getState().agentState?.config.cliEnabled).toBe(true);
    });

    fireEvent.click(screen.getByRole('radio', { name: '允许整理与生成情绪板' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.accessLevel).toBe('readWriteOrganize');
    });

    // Pane 8: Extensions (Figma Plugin bundle)
    fireEvent.click(screen.getByRole('tab', { name: '插件与扩展' }));
    expect(screen.getByTestId('settings-pane-extensions')).toBeInTheDocument();

    // Pane 9: Advanced & About -> Re-run Skippable Onboarding Studio
    fireEvent.click(screen.getByRole('tab', { name: '高级与关于' }));
    expect(screen.getByTestId('settings-pane-advancedAbout')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('button', { name: /重新运行新手引导/ }));
    await waitFor(() => {
      expect(screen.getByTestId('onboarding-studio')).toBeInTheDocument();
      expect(screen.queryByTestId('settings-overlay')).not.toBeInTheDocument();
    });

    // Step through and skip Onboarding cleanly
    fireEvent.click(screen.getByRole('button', { name: '下一步' }));
    expect(screen.getByText(/第 1 步 · 素材库存储/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: '跳过引导' }));
    await waitFor(() => {
      expect(screen.queryByTestId('onboarding-studio')).not.toBeInTheDocument();
    });
  });
});
