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

    // Pane 3: Sync + Lossless Storage Migration Wizard (macOS modal sheet flow)
    fireEvent.click(screen.getByRole('tab', { name: '云同步' }));
    expect(screen.getByTestId('settings-pane-sync')).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /更改或转移…/ }));
    await waitFor(() => {
      expect(screen.getByText('更改或转移素材库位置')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole('radio', { name: 'WebDAV 云盘' }));
    fireEvent.change(screen.getByPlaceholderText(/服务器地址/), {
      target: { value: 'https://dav.example.com/dav/' },
    });
    fireEvent.click(screen.getByRole('button', { name: /开始无损迁移/ }));
    await waitFor(() => {
      expect(screen.getByTestId('storage-migration-report')).toBeInTheDocument();
    });

    // Pane 4 & 5: Drop Shelf + Capture Shortcuts
    fireEvent.click(screen.getByRole('tab', { name: '顶部悬浮窗' }));
    expect(screen.getByTestId('settings-pane-dropShelf')).toBeInTheDocument();

    fireEvent.click(screen.getByRole('tab', { name: '采集与快捷键' }));
    expect(screen.getByTestId('settings-pane-captureShortcuts')).toBeInTheDocument();

    // Pane 6: Hybrid Cloud AI + TypeSafe Visual Enhancement (macOS progressive modal sheets)
    fireEvent.click(screen.getByRole('tab', { name: 'AI 智能' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-ai')).toBeInTheDocument();
    });
    fireEvent.click(screen.getByRole('button', { name: /Gemini \/ 自定义 API…/ }));
    await waitFor(() => {
      expect(screen.getByText('配置云端 AI 服务')).toBeInTheDocument();
    });
    const keyInput = screen.getByLabelText('云端 AI API 密钥');
    fireEvent.change(keyInput, { target: { value: 'AIza-mock-secret' } });
    fireEvent.click(screen.getByRole('button', { name: '测试连接' }));
    await waitFor(() => {
      expect(screen.getByTestId('ai-test-result')).toBeInTheDocument();
    });
    expect(useSyncAIStore.getState().aiState?.hasApiKey).toBe(true);
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));
    await waitFor(() => {
      expect(screen.queryByText('配置云端 AI 服务')).not.toBeInTheDocument();
    });

    // Enable TypeSafe visual grounding & save API key in modal
    fireEvent.click(screen.getByLabelText('启用精准画面定位'));
    const tsModalBtn = await screen.findByRole('button', { name: /密钥与功能开关…/ });
    fireEvent.click(tsModalBtn);
    await waitFor(() => {
      expect(screen.getByText('进阶视觉定位引擎配置')).toBeInTheDocument();
    });
    fireEvent.change(screen.getByLabelText('TypeSafe API 密钥'), {
      target: { value: 'ts-mock-key' },
    });
    expect(screen.getByLabelText('零幻觉闭集自动打标')).toBeInTheDocument();
    fireEvent.click(screen.getByLabelText('高置信度自动写入正式标签'));
    fireEvent.click(screen.getByRole('button', { name: '保存配置' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().typesafeState?.config.enabled).toBe(true);
      expect(useSyncAIStore.getState().typesafeState?.config.enableClosedSetTagging).toBe(true);
      expect(useSyncAIStore.getState().typesafeState?.config.autoApplyHighConfidenceTags).toBe(
        true,
      );
      expect(useSyncAIStore.getState().typesafeState?.hasApiKey).toBe(true);
    });

    // Pane 7: Pure MCP v2 stdio + Streamable HTTP toggles, 3-tier access & Scoped Tokens
    fireEvent.click(screen.getByRole('tab', { name: '外部 Agent' }));
    await waitFor(() => {
      expect(screen.getByTestId('settings-pane-externalAgents')).toBeInTheDocument();
    });
    expect(screen.getByTestId('http-mcp-config-json-snippet').textContent).toContain('/api/v1/mcp');

    fireEvent.click(screen.getByLabelText('启用 MCP 服务'));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.mcpEnabled).toBe(false);
      expect(useSyncAIStore.getState().agentState?.config.httpMCPEnabled).toBe(true);
    });

    fireEvent.click(screen.getByRole('radio', { name: '仅收件箱与打标' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.accessLevel).toBe('inboxAndEnrich');
    });

    fireEvent.click(screen.getByRole('radio', { name: '全局整理与生板' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.accessLevel).toBe('readWriteOrganize');
    });

    // Mint, toggle, and revoke a Scoped HTTP MCP token
    fireEvent.change(screen.getByLabelText('HTTP MCP 令牌名称'), {
      target: { value: 'Remote Curator' },
    });
    fireEvent.click(screen.getByRole('button', { name: '签发令牌' }));
    await waitFor(() => {
      expect(screen.getByTestId('minted-token-plaintext').textContent).toMatch(/^ck_mcp_/);
      expect(useSyncAIStore.getState().agentState?.config.tokens).toHaveLength(1);
    });
    fireEvent.click(screen.getByLabelText('切换令牌 Remote Curator'));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.tokens[0]?.isEnabled).toBe(false);
    });
    fireEvent.click(screen.getByRole('button', { name: '吊销' }));
    await waitFor(() => {
      expect(useSyncAIStore.getState().agentState?.config.tokens).toHaveLength(0);
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
    fireEvent.click(screen.getByRole('button', { name: /开始快速配置/ }));
    expect(screen.getByText(/素材库保存在哪里？/)).toBeInTheDocument();
    fireEvent.click(screen.getByRole('button', { name: /跳过引导/ }));
    await waitFor(() => {
      expect(screen.queryByTestId('onboarding-studio')).not.toBeInTheDocument();
    });
  });

  it('unlocks pure-Jev closed-set tagging with VLM disabled, concurrency=6, and auto-apply formal tags', async () => {
    const { resolveEnrichEngineStatus, useLibraryStore } = await import('../stores');

    await useSyncAIStore.getState().refreshSettingsData();
    await useLibraryStore.getState().bootstrap({ type: 'allItems' });

    // VLM remains disabled; enable Jev closed-set tagging + API key + autoApply
    const baseTs = useSyncAIStore.getState().typesafeState!.config;
    await useSyncAIStore.getState().saveTypesafeConfig(
      {
        ...baseTs,
        enabled: true,
        enableClosedSetTagging: true,
        autoApplyHighConfidenceTags: true,
        highConfidenceTagThreshold: 0.85,
      },
      { apiKey: 'ts-pure-jev-key' },
    );

    const status = resolveEnrichEngineStatus(
      useSyncAIStore.getState().aiState,
      useSyncAIStore.getState().typesafeState,
    );
    expect(status.canEnrich).toBe(true);
    expect(status.jevReady).toBe(true);
    expect(status.vlmReady).toBe(false);
    expect(status.concurrency).toBe(6);
    expect(status.label).toBe('Jev 闭集打标');

    const target = useLibraryStore.getState().assets[0];
    expect(target).toBeDefined();
    const enriched = await useLibraryStore
      .getState()
      .enrichAssets([target.id], { type: 'allItems' });
    expect(enriched).toHaveLength(1);
    expect(enriched[0].tags.length).toBeGreaterThanOrEqual(target.tags.length);
  });
});
