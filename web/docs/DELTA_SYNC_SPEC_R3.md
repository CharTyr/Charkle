# Charkle-Web Round 3 Delta Sync Specification

> **Audit Scope**: All uncommitted Round 3 changes in the macOS repository root (`..`, read-only audit) mapped onto `./web`.
>
> **Summary of Upstream Changes Audited**:
> 1. **Core / AI / Engine**: Live AI connection testing (`testAIConnection` across ChatGPT Subscription, Gemini, Anthropic Messages, OpenAI Chat Completions, OpenAI Responses via authenticated `GET /models` + 404/405 JSON-ping fallback), plus offline batched visual-index rebuild (`rebuildLocalVisualIndex`).
> 2. **Figma Plugin**: `Resources/FigmaPlugin/ui.html` vs `Charkle-Web/figma-plugin/ui.html` has **0 diff** (byte-for-byte identical). For Web parity with macOS's "Reveal manifest.json in Finder", add `GET /api/v1/figma-plugin/download` (`.zip` download) on server.
> 3. **New Layered Hero Icons & Motion**: `layered-ai-spark.svg`, `layered-gallery.svg`, `layered-ready.svg`; tactile keycap CTA style (`CharkleSkeuoButtonStyle`) and onboarding step/shockwave motion tokens (`CharkleMotion.swift`).
> 4. **First-Launch & Re-Runnable Onboarding**: 6-step skippable onboarding modal (`OnboardingView.swift`), adapted for Web (replacing macOS Notch & Screen Recording with Browser Clipper Extension + default capture target; keeping Web AuthGate before workspace mount).
> 5. **Overhauled Modular Settings**: Calm neutral 4-section, 9-pane centered overlay (`SettingsOverlayView`, `SettingsChrome`, 9 focused single-purpose panes), keeping Web's `账号与安全` pane and Browser Clipper Extension while dropping macOS Notch and `gdirect` CLI/NFS mount controls.
> 6. **Main Shell / Sidebar / Generator Deep-Links**: Dedicated bottom-left Settings entry in collapsed & expanded `SidebarView` (`⌘,`), deep-link tab routing (`ai`, `extensions`, `library`/`sync`), and re-runnable onboarding triggers.

---

## Explicit Exclusions & Product Rules

1. **NO macOS Notch / `gdirect` / AppKit Code**:
   - Skip `layered-notch.svg`, `NotchShelf*.swift`, `NotchShelfSettingsPane.swift`, `ScreenCapturePermissionChecker.swift`, `AppIconManager.swift` (`NSApp` guard), `CharkleAppEntry.swift` AppKit bootstrap, and all `gdirect` CLI / local NFS mount UI.
   - Keep `DriveTransportMode`'s `'gdirectMount'` union variant in `@charkle/shared` untouched for macOS `.charkle/` sync codec compatibility (display it as Google Drive in Web UI).
2. **Web-Specific Features to Preserve & Integrate**:
   - Keep **Auth Login** (`AuthGate` before `CharkleWorkspace`) and the **`账号与安全`** (`accountSecurity`) Settings pane (password change, active sessions, `chk_...` PAT management).
   - Keep the **Browser Clipper Extension** (`packages/extension/`, `/api/v1/extension/download`) + Safari/Mobile Bookmarklet, now cleanly housed in the new **`插件与扩展`** (`extensions`) Settings pane and Step 2 of Onboarding.
3. **STRICT USER-FACING COPY RULE**:
   - **FORBIDDEN** in any user-facing label, title, subtitle, badge, tooltip, guide step, or toast: `Gallery-First`, `Liquid Glass`, `16-Grid`, `Layered`, `Duotone`, `Manifest V3`, `scrypt`, `FTS5`, `CIELAB`, `MMR`, `Agent Harness`.
   - **NO** macOS-only terms in Web copy: replace `Apple Vision` → `内置视觉分析`, `macOS 钥匙串` → `服务端加密保存`, `访达` / `程序坞` / `每台 Mac` → `浏览器` / `多设备`.
   - **NO** developer icon showcase wall and **NO** verbose marketing slogans. Keep only genuinely useful user controls and crisp plain Chinese labels.

---

## File Ownership Map & Cross-Builder Contracts

| Builder | Exclusive File Ownership |
| --- | --- |
| **`server-sync`** | `packages/shared/**`, `packages/server/**` (`figma-plugin/ui.html` verified 0 diff — no edits) |
| **`client-sync`** | `packages/client/public/icons/**`, `packages/client/src/{App.tsx,design-system/**,api/**,stores/**,features/{auth,onboarding,sidebar,gallery,quicklook,inspector,jump,capture}/**}` |
| **`studio-sync`** | `packages/client/src/features/{moodboard/**,settings/**}` |

### Frozen Cross-Builder Type Contracts (Implement Verbatim for Conflict-Free Parallel Build)

```ts
// 1. packages/shared/src/api/contracts.ts (server-sync)
export interface TestAIConnectionRequest {
  config: AIProviderConfig;
  apiKey?: string | null;
}

export interface TestAIConnectionResponse {
  ok: true;
  summary: string;
  models?: ChatGPTModelInfo[];
}

export interface AnalyzeAssetsRequest {
  ids: UUID[];
  /** When true, runs offline color + visual fingerprint rebuild only (never calls cloud AI). */
  localOnly?: boolean;
}

// 2. packages/client/src/stores/coordinatorStore.ts (client-sync)
export type SettingsTabID =
  | 'general'
  | 'accountSecurity'
  | 'library'
  | 'sync'
  | 'captureShortcuts'
  | 'ai'
  | 'externalAgents'
  | 'extensions'
  | 'advancedAbout';

// Additional coordinatorStore fields/actions:
// hasCompletedOnboarding: boolean (persisted in localStorage['charkle.hasCompletedOnboarding'], default false)
// onboardingOpen: boolean
// onboardingRunID: number
// presentOnboardingIfFirstLaunch: () => void
// presentOnboarding: () => void
// completeOnboarding: () => void

// 3. packages/client/src/api/client.ts (client-sync)
// apiClient.testAIConnection(req: TestAIConnectionRequest): Promise<TestAIConnectionResponse>
// apiClient.connectChatGPT(req: { accessToken: string; email?: string | null; name?: string | null }): Promise<{ session: ChatGPTAccountSession; config: AIProviderConfig }>
// apiClient.disconnectChatGPT(): Promise<{ session: ChatGPTAccountSession }>
// apiClient.figmaPluginDownloadURL(): string   // `${API_BASE}/figma-plugin/download`

// 4. packages/client/src/stores/syncAIStore.ts (client-sync)
// isTestingAI: boolean
// isRebuildingVisualIndex: boolean
// rebuildVisualIndexProgress: { completed: number; total: number } | null
// chatGPTModels: ChatGPTModelInfo[]
// isLoadingChatGPTModels: boolean
// testAIConnection: (config: AIProviderConfig, apiKey?: string | null) => Promise<string>
// connectChatGPT: (req: { accessToken: string; email?: string | null; name?: string | null }) => Promise<void>
// disconnectChatGPT: () => Promise<void>
// refreshChatGPTModels: () => Promise<ChatGPTModelInfo[]>
// rebuildLocalVisualIndex: (assetIDs: UUID[]) => Promise<number>
```

> **Isolation Rule**: `OnboardingModal.tsx` (`client-sync`) MUST NOT import from `features/settings/*` (keep its compact `client_secret.json` / OAuth credential modal inline or local to `features/onboarding/`) so `client-sync` and `studio-sync` compile independently with zero cross-feature coupling.

---

## 1. Shared & Server Delta (for `server-sync`)

### 1.1 Shared API Contracts (`packages/shared/src/api/contracts.ts`)
- Add `TestAIConnectionRequest` (`{ config: AIProviderConfig; apiKey?: string | null }`) and `TestAIConnectionResponse` (`{ ok: true; summary: string; models?: ChatGPTModelInfo[] }`).
- Extend `AnalyzeAssetsRequest` with `localOnly?: boolean`.

### 1.2 Authenticated `GET` + Live AI Connection Tester (`packages/server/src/intelligence/cloud-ai-provider.ts`)
Mirror `CloudAIProvider.swift` (`AIHTTPClient.get`) and `LiveCharkleEngine.swift` (`testAIConnection`):
- Add `async get(path: string, timeoutMs = 20_000): Promise<{ status: number; text: string }>` on `AIHTTPClient` (sends `authHeader` + `extraHeaders`, returns raw `{ status, text }` without throwing on non-2xx so callers can inspect `404`/`405`).
- Export `testCloudAIConnection(params: { config: AIProviderConfig; apiKey?: string | null; vault: SecretVaultLike; chatGPTClient?: ChatGPTSubscriptionClient | null; usage?: CloudAIUsageTracker | null; fetchFn?: FetchLike }): Promise<{ summary: string; models?: ChatGPTModelInfo[] }>`:
  - `disabled`: throw `CloudAIError('请先选择要测试的云端 AI 服务。', 'provider_disabled', 400)`.
  - `chatGPTSubscription`: check `session.status === 'connected'` (`"尚未连接 ChatGPT 订阅账号，请先完成登录。"`) and `session.sharingEnabled` (`"已登录 ChatGPT，但尚未开启订阅额度共享授权。"`), call `chatGPTClient.listModels()`, return `{ summary: \`ChatGPT 订阅连接正常（可用模型 ${models.length} 个）\`, models }`.
  - `gemini`: resolve key from `apiKey?.trim()` or `vault.get(SECRET_KEYS.GEMINI_API_KEY)`; require non-empty key (`"请先填写 Gemini API 密钥后再测试连接。"`). Normalize model (strip leading `models/`, default `'gemini-2.5-flash'`). Use `resolveProviderBaseURL(config.baseURL || 'https://generativelanguage.googleapis.com', 'v1beta', false)` + `x-goog-api-key`:
    - `GET models/${targetModel}`: if `200..299` → `{ summary: \`Gemini 连接成功 · 模型 ${targetModel} 可用\` }`.
    - If `status === 404`: fallback `GET models`; if `200..299` → throw `CloudAIError(\`API 密钥有效，但未找到模型「${targetModel}」，请检查模型名称。\`, 'model_not_found', 400)`.
    - Otherwise throw `CloudAIError(\`Gemini 服务返回 HTTP ${status}，请检查 API 密钥或服务地址。\`, 'http_error', status)`.
  - `openAICompatible`: resolve key from `apiKey?.trim()` or `vault.get(SECRET_KEYS.OPENAI_API_KEY)` (nullable for localhost/Ollama); resolve `labelModel = config.chatModel.trim() || customAIEndpointDefaultChatModel(config.customEndpointFormat)`:
    - `anthropicMessages`: require non-empty key (`"请先填写 Anthropic API 密钥后再测试连接。"`). `GET models` against `resolveProviderBaseURL(config.baseURL || 'https://api.anthropic.com', 'v1', false)` with `x-api-key` + `anthropic-version: 2023-06-01`:
      - `200..299` → `{ summary: \`Anthropic 连接成功 · 目标模型 ${labelModel}\` }`.
      - `404` or `405` → instantiate `AnthropicMessagesProvider(config, key, deps)` and call `completeJSON('Reply with {"ok":true}', 'ping', [])` → `{ summary: \`Anthropic 兼容接口连通正常 · 模型 ${labelModel}\` }`.
      - Else throw `CloudAIError(\`Anthropic 接口返回 HTTP ${status}，请检查 API 密钥与服务地址。\`, 'http_error', status)`.
    - `openAIChatCompletions` / `openAIResponses`: `GET models` against `resolveProviderBaseURL(config.baseURL || 'https://api.openai.com', 'v1', key === null)` with optional `Authorization: Bearer ${key}`:
      - `200..299` → `{ summary: \`连接成功 · ${customAIEndpointLocalizedLabel(config.customEndpointFormat)}（${labelModel}）\` }`.
      - `404` or `405` → instantiate `OpenAIResponsesProvider` or `OpenAICompatibleProvider` and call `completeJSON('Reply with {"ok":true}', 'ping', [])` → `{ summary: \`连接成功 · 模型 ${labelModel} 响应正常\` }`.
      - Else throw `CloudAIError(\`服务返回 HTTP ${status}，请检查服务地址、端点格式或 API 密钥。\`, 'http_error', status)`.

### 1.3 AI Routes (`packages/server/src/api/routes-ai.ts`)
- **Add `POST /api/v1/ai/test`**:
  - Parses `TestAIConnectionRequest` (`config` defaults to `ctx.configStore.getAIConfig()`, `apiKey` optional).
  - Calls `testCloudAIConnection({ config, apiKey: body.apiKey ?? null, vault: vaultWithEnvFallback, chatGPTClient: rt.chatGPT, usage: rt.usage, fetchFn: rt.fetchFn })`.
  - Returns `200 { ok: true, summary, models }` on success, or `{ error }` with `errorStatusFor(err)` on failure.
- **Update `POST /api/v1/ai/analyze`** (L339):
  - Change `if (aiCfg.provider === 'disabled')` → **`if (body.localOnly || aiCfg.provider === 'disabled')`** so the offline dominant-color & perceptual-fingerprint rebuild works even when Cloud AI is enabled!

### 1.4 Figma Plugin ZIP Download (`packages/server/src/api/routes-core.ts`)
- Mirror `GET /api/v1/extension/download` with **`GET /api/v1/figma-plugin/download`**:
  - Add `resolveFigmaPluginDir()` checking `process.env.CHARKLE_FIGMA_PLUGIN_DIR`, `../../../figma-plugin`, `path.resolve(process.cwd(), 'figma-plugin')`, `path.resolve(process.cwd(), '../../figma-plugin')` for `manifest.json`.
  - Bundle `manifest.json`, `code.js`, `ui.html`, `jszip.min.js`, `sha256.min.js`, `JSZIP-LICENSE.md`, `SHA256-LICENSE.txt` (excluding dotfiles and `ui-template.html`) via `JSZip`.
  - Respond with `Content-Type: application/zip`, `Content-Disposition: attachment; filename="charkle-figma-bridge-plugin.zip"`, `Cache-Control: private, no-cache`.

### 1.5 Figma Plugin Static Assets (`figma-plugin/ui.html`)
- **No action required** — verified byte-for-byte identical to `../Resources/FigmaPlugin/ui.html`.

### 1.6 Tests (`packages/server/tests/*`)
- In `ai-routes-integration.test.ts` (or `ai-cloud-provider.test.ts`):
  - Test `POST /api/v1/ai/test` for `disabled` (400), `gemini` (200 model hit, 404 model missing with 200 list fallback, 401 bad key), `openAICompatible` (`openAIChatCompletions` 200 + 404 ping fallback, `openAIResponses` 405 ping fallback, `anthropicMessages` 200 + 404 ping fallback, Ollama localhost keyless 200), and `chatGPTSubscription` (disconnected 400, connected 200 returning model count).
  - Test `POST /api/v1/ai/analyze` with `{ ids, localOnly: true }` while Cloud AI is configured: verifies cloud provider is NOT called and local visual fingerprints / dominant colors refresh cleanly.
- In `core-delta-extension.test.ts`:
  - Test `GET /api/v1/figma-plugin/download` returns `200 application/zip` containing `manifest.json`, `code.js`, `ui.html`.

---

## 2. Design System, Icons, Stores, Shell & Onboarding Delta (for `client-sync`)

### 2.1 Layered Hero Icons (`packages/client/public/icons/**` & `CharkleIcon.tsx`)
- Copy byte-for-byte from `../Sources/CharkleApp/Resources/Icons/`:
  - `layered-ai-spark.svg` → `packages/client/public/icons/layered-ai-spark.svg`
  - `layered-gallery.svg` → `packages/client/public/icons/layered-gallery.svg`
  - `layered-ready.svg` → `packages/client/public/icons/layered-ready.svg`
  - *(Do NOT copy `layered-notch.svg`.)*
- In `packages/client/src/design-system/CharkleIcon.tsx`:
  - Import `CheckCircle2` from `lucide-react`.
  - Add to `LUCIDE_FALLBACK_MAP`: `'ai-spark': Sparkles`, `'gallery': LayoutGrid`, `'ready': CheckCircle2`.

### 2.2 Calibrated Settings Surface Tokens, Tactile Keycap Button & Onboarding Motion (`packages/client/src/design-system/tokens.css`, `Button.tsx`)
- **Settings/Onboarding Neutral Palette** in `tokens.css`:
  - `:root` (Light):
    ```css
    --settings-rail: #F0EFEA;
    --settings-content: #F6F6F4;
    --settings-card: #FFFFFF;
    --settings-subtle: rgba(0, 0, 0, 0.04);
    --settings-label: rgba(0, 0, 0, 0.48);
    --settings-divider: rgba(0, 0, 0, 0.065);
    --settings-border: rgba(0, 0, 0, 0.08);
    --settings-positive: #15803D;
    --settings-warning: #B45309;
    --settings-destructive: #DC2626;
    ```
  - `:root[data-theme="dark"], .dark`:
    ```css
    --settings-rail: #17181B;
    --settings-content: #121316;
    --settings-card: #1B1C20;
    --settings-subtle: rgba(255, 255, 255, 0.05);
    --settings-label: rgba(255, 255, 255, 0.46);
    --settings-divider: rgba(255, 255, 255, 0.065);
    --settings-border: rgba(255, 255, 255, 0.085);
    --settings-positive: #4ADE80;
    --settings-warning: #FBBF24;
    --settings-destructive: #F87171;
    ```
- **Onboarding Motion & Shockwave Keyframes** in `tokens.css`:
  - `--duration-onboarding-step: 280ms;` (`--ease-out`)
  - `--duration-onboarding-delight: 480ms;` (`--ease-spring`)
  - `--duration-onboarding-shockwave: 680ms;` (`--ease-out-strong`)
  - `@keyframes charkle-step-from-right` (`translateX(24px) scale(0.985) opacity(0) -> none opacity(1)`) and `@keyframes charkle-step-from-left` (`translateX(-24px) ...`).
  - `@keyframes charkle-shockwave-primary` (`scale(0.88) opacity(0.45) -> scale(1.85) opacity(0)`) & `@keyframes charkle-shockwave-secondary` (`scale(0.92) opacity(0.25) -> scale(2.25) opacity(0)`, `80ms` delay).
  - Under `@media (prefers-reduced-motion: reduce)`: collapse all onboarding animations to `150ms` opacity-only fade and hide shockwave rings.
- **5-Layer Tactile Keycap Button** (`.charkle-skeuo-primary` & `.charkle-skeuo-secondary` in `tokens.css`, plus optional `variant="skeuoPrimary" | "skeuoSecondary"` in `Button.tsx` — porting `CharkleSkeuoButtonStyle`):
  - Light primary: gradient `#404859 → #273042` (hover `#4A5366 → #2F394D`), `1px solid #12161F`, inset `0 1px 0 rgba(255,255,255,0.18), 0 -1px 0 rgba(0,0,0,0.24)`, dual shadow `0 3px 7px rgba(18,22,31,0.28), 0 1px 1.5px rgba(0,0,0,0.18)`, white semibold text with `0 -1px 0 rgba(0,0,0,0.26)` text-shadow, `:active` gradient inversion + `translateY(1px)` (disabled under reduced-motion).
  - Dark primary: gradient `#414B60 → #283144` (hover `#4D5870 → #313A4D`), `1px solid #151923`, inset `0 1px 0 rgba(255,255,255,0.22), 0 -1px 0 rgba(0,0,0,0.32)`.
  - Secondary light/dark variants matching `CharkleMotion.swift` L350–369.

### 2.3 API Client & Stores (`api/client.ts`, `coordinatorStore.ts`, `syncAIStore.ts`)
- **`packages/client/src/api/client.ts`**:
  - Add `figmaPluginDownloadURL()` returning `${API_BASE}/figma-plugin/download` and expose on `apiClient`.
  - Add `testAIConnection: (req: TestAIConnectionRequest) => requestJson<TestAIConnectionResponse>('/ai/test', { method: 'POST', body: JSON.stringify(req) })`.
  - Add `connectChatGPT: (req: { accessToken: string; email?: string | null; name?: string | null }) => requestJson<{ session: ChatGPTAccountSession; config: AIProviderConfig }>('/ai/chatgpt/connect', { method: 'POST', body: JSON.stringify(req) })`.
  - Add `disconnectChatGPT: () => requestJson<{ session: ChatGPTAccountSession }>('/ai/chatgpt/disconnect', { method: 'POST' })`.
- **`packages/client/src/stores/coordinatorStore.ts`**:
  - Update `SettingsTabID` to the 9-tab union in the Cross-Builder Contract; default `settingsTab: 'general'`.
  - Persist `sidebarCollapsed` in `localStorage['charkle.sidebarCollapsed']` (both `setSidebarCollapsed` and `toggleSidebar`).
  - Update `openSettings(tab?)` to set `{ settingsOpen: true, jumpAnywhereOpen: false, settingsTab: tab ?? s.settingsTab }`.
  - Add onboarding state (`hasCompletedOnboarding`, `onboardingOpen`, `onboardingRunID`) and actions (`presentOnboardingIfFirstLaunch`, `presentOnboarding` which also sets `settingsOpen: false`, `completeOnboarding`).
- **`packages/client/src/stores/syncAIStore.ts`**:
  - Add `isTestingAI`, `isRebuildingVisualIndex`, `rebuildVisualIndexProgress: { completed: number; total: number } | null`, `chatGPTModels: ChatGPTModelInfo[]`, `isLoadingChatGPTModels: boolean`.
  - Add `testAIConnection(config, apiKey)`: sets `isTestingAI`, calls `apiClient.testAIConnection({ config, apiKey })`, updates `chatGPTModels` if returned, returns `res.summary` (throws on failure).
  - Add `connectChatGPT(req)` & `disconnectChatGPT()` & `refreshChatGPTModels()`: call respective endpoints and refresh `loadAIConfig()`.
  - Add `rebuildLocalVisualIndex(assetIDs: UUID[]): Promise<number>`: batches `assetIDs` in chunks of `16`, calls `apiClient.analyzeAssets({ ids: slice, localOnly: true })`, updates `rebuildVisualIndexProgress: { completed: end, total: assetIDs.length }`, clears progress in `finally`, returns processed count.

### 2.4 First-Launch & Re-Runnable Onboarding Modal (`packages/client/src/features/onboarding/OnboardingModal.tsx` & `index.ts`)
Portal modal (`z-[120]`, `w-[min(840px,calc(100vw-48px))] h-[min(636px,calc(100vh-48px))]`, `rounded-[20px]`, `bg-[var(--settings-content)]`, `1px solid var(--settings-border)`). Every step and the full flow are explicitly skippable (`Esc` closes & marks completed unless an inline sub-modal is open).

- **Header Bar**: `CharkleBrandMark(22)` + `"Charkle"`, centered interactive 6-step pill rail (`欢迎`, `素材库`, `采集`, `AI 智能`, `外观`, `完成`) with checkmark on completed past steps, hollow ring on skipped past steps, active white/card capsule, and right-aligned `"跳过引导 ×"` button (hidden on `完成`).
- **Footer Bar**: Left shows `"上一步"` button (or quiet hint `"每一步都可跳过 · 随时可在「设置 (⌘,) → 通用」重新查看"` on Step 0); right shows step counter `N / 6` + contextual buttons:
  - Step 0: `"跳过，直接使用"` + `.charkle-skeuo-primary` `"开始快速配置 →"`
  - Steps 1–4: `"跳过此步"` + `.charkle-skeuo-primary` (`"下一步 →"`, or `"查看配置摘要 →"` on Step 4)
  - Step 5: `"打开完整设置 (⌘,)"` + `.charkle-skeuo-primary` `"进入 Charkle 工作台 →"`
- **6 Steps (all plain Chinese, zero jargon, zero macOS Notch)**:
  1. **`welcome` (欢迎)**: Brand mark hero + `"欢迎使用 Charkle"` + 4 staggered clickable pillar cards jumping to their respective steps:
     - `layered-inbox` (`#3B74E8`): `"浏览器与剪贴板随手收"` → `capture`
     - `layered-library` (`#D96B43`): `"本地与云盘灵活切换"` → `storage`
     - `layered-ai-spark` (`#2A8F9D`): `"基础识图 + 可选云 AI"` → `intelligence`
     - `layered-moodboard` (`#3D9970`): `"自由画布与 Figma 导出"` → `workspace`
  2. **`storage` (素材库)**: 2-column layout (`234px` left pedestal with `layered-folder` / `layered-drive`; right radio cards):
     - `"本地文件夹"` (`默认推荐`): editable server directory path + `"保存路径"`.
     - `"Google Drive 云端直连"` (`已连接` if signed in): `"使用 Google 登录"` (when OAuth client configured) or `"配置凭据并登录…"` (inline compact dialog supporting `.json` file import parsing `installed ?? web` + manual Client ID/Secret).
     - `"WebDAV 云盘 / NAS"`: Server URL, username, password, `"测试并保存"`.
  3. **`capture` (采集 — Web-Native)**: 2-column layout:
     - Left pedestal: `layered-inbox` icon disc, badge `"跨网页随手收集"`, caption explaining browser clipper + global paste, button `"打开快速采集 (⇧⌘N)"`.
     - Right content:
       - Card 1 (**浏览器采集扩展**): `"下载扩展 (.zip)"` (`/api/v1/extension/download`), `"生成扩展令牌"` (one-click `read, write` PAT with copy-once box + current origin readout), and quiet expandable 3-step install instructions.
       - Card 2 (**默认采集去向**): `captureTarget` selector (`收件箱` / `指定文件夹` / `当前活跃情绪板`) persisted immediately to `coordinatorStore`, plus quiet tip about full-window drag-and-drop & global `⌘V`.
  4. **`intelligence` (AI 智能)**: 2-column layout:
     - Left pedestal: `layered-ai-spark` icon disc + `"基础离线能力免费内置"` checklist (`自动提取主色调配色`, `视觉相似素材推荐`, `图内文字与标签检索`, `中文与拼音首字母快搜`).
     - Right radio cards:
       - `"仅使用内置能力"` (`默认`)
       - `"连接 ChatGPT 订阅账号"` (`/icons/chatgpt-mark.svg` icon, connected badge OR access-token input + `"连接"` button)
       - `"Google Gemini 或自定义 API"`: 5 quick preset pills (`Gemini`, `OpenAI`, `Claude`, `DeepSeek`, `Ollama 本地`), model + conditional baseURL inputs, API key input, `"测试"` (calls `syncAIStore.testAIConnection`) and `"保存"` buttons.
  5. **`workspace` (外观)**: 2-column layout:
     - Left pedestal: `layered-gallery` icon disc + live miniature **Gallery Layout Wireframe Preview** switching smoothly among `纵向瀑布流`, `横向等高行`, and `画廊视图`.
     - Right controls (all instant-apply):
       - 主题模式 (`浅色` / `深色` / `跟随系统`)
       - 应用图标风格 (`跟随主题` / `浅色` / `深色` with `CharkleBrandMark` preview)
       - 画廊默认排布 (`纵向瀑布流` / `横向等高行` / `画廊视图`)
       - 开关: `"默认收起侧边栏为精简图标栏"` (`随时可用 ⌘\ 切换`).
  6. **`ready` (完成)**:
     - Centered `layered-ready` (64px) seal with one-shot `.charkle-shockwave-primary` + `.charkle-shockwave-secondary` rings on entry.
     - `"一切准备就绪"` + 2×2 clickable summary grid (`素材库与云同步`, `采集与扩展`, `AI 智能`, `外观与画廊排布`) showing live values & `"已跳过"` pill when skipped.

### 2.5 Main Shell, Sidebar, Quick Capture & Jump Deep-Links
- **`packages/client/src/App.tsx`**:
  - Mount `<OnboardingModal />` inside `CharkleWorkspace`.
  - After `bootstrap()` completes, call `useCoordinatorStore.getState().presentOnboardingIfFirstLaunch()` (also load sync/AI config lazily if needed, or let `OnboardingModal` load them on open).
  - Add `coord.onboardingOpen` to the modal guard in the global `keydown` listener (L197–205).
- **`packages/client/src/features/sidebar/SidebarView.tsx`**:
  - Bottom sync status pill (L657): route to `openSettings(syncConfig?.mode === 'localOnly' ? 'library' : 'sync')` (matching macOS `MainWindowView.swift`).
  - Bottom-left Settings trigger (matching `SidebarView.swift`):
    - **Collapsed rail**: hairline divider + dedicated duotone `settings` icon button (`38×34`, subtle active fill when `settingsOpen`, tooltip `"设置 (⌘,)"`) calling `openSettings()`.
    - **Expanded sidebar**: hairline divider + clean Settings row (`CharkleIcon name="settings" style="duotone" size={17} isActive={settingsOpen}` + `"设置"` + right-aligned monospaced `"⌘,"`) alongside the compact user menu button.
    - Inside User Account popover: keep `"账号与安全设置"` (`openSettings('accountSecurity')`), add `"重新查看新手引导"` (`presentOnboarding()`), keep `"退出登录"`.
- **`packages/client/src/features/capture/QuickCaptureModal.tsx`** (L851):
  - Change `openSettings('captureShortcuts')` → **`openSettings('extensions')`**.
- **`packages/client/src/features/jump/JumpAnywhereModal.tsx`**:
  - Change `installExtension` → **`openSettings('extensions')`** (L235).
  - Change `openSettings` → **`openSettings('general')`** (L236).
  - Add quick command `rerunOnboarding`: title `"重新运行首次使用引导"`, subtitle `"快速配置素材库、浏览器扩展、AI 与外观"`, invokes `presentOnboarding()`.

---

## 3. Moodboard Deep-Links & Overhauled 9-Pane Modular Settings (for `studio-sync`)

### 3.1 Moodboard Deep-Links (`packages/client/src/features/moodboard/*`)
- **`MoodboardGeneratorModal.tsx`** (L303): change `openSettings('intelligence')` → **`openSettings('ai')`**.
- **`ExportBoardModal.tsx`** (L405–447): add a subtle `"打开插件与扩展设置 →"` button in the Figma guide block that calls `onClose(); openSettings('extensions')` so users can one-click download the Figma plugin zip.

### 3.2 Modular Settings Architecture (`packages/client/src/features/settings/*`)
Replace the old monolithic 7-tab implementation (`SettingsModal.tsx`, `SettingsPrimitives.tsx`, `AccountSecurityTab.tsx`, `CloudSyncTab.tsx`, `IntelligenceTab.tsx`, `AppearanceAndOtherTabs.tsx`, `StorageMigrationModal.tsx`) with the calm **4-section, 9-pane** architecture matching `Sources/CharkleApp/Views/Settings/*.swift` (adapted cleanly for Web). Keep `export { SettingsModal } from './SettingsModal'` in `features/settings/index.ts`.

#### Shared Chrome (`SettingsChrome.tsx`)
- `SettingsSection`: external `11.5px` muted section label (`var(--settings-label)`) + optional caption above `SettingsCard`.
- `SettingsCard`: `rounded-[12px] bg-[var(--settings-card)] border border-[var(--settings-border)] overflow-hidden`.
- `SettingsCardDivider`: `mx-4 border-t border-[var(--settings-divider)]`.
- `SettingsRow`: `px-4 py-3`, `13px font-medium` title, optional `11.5px` subtitle with `subtitleTone?: 'default' | 'positive' | 'warning' | 'destructive'`, right-aligned control slot.
- `InlineGuideDisclosure`: quiet inline trigger (`如何… >`) with smooth `90°` chevron rotation expanding an inset `rounded-[9px] bg-[var(--settings-subtle)]` step container.
- `SettingsGuideStep`: `18×18` monochrome numbered badge + `12px font-medium` title + optional `11px` detail.
- `SettingsStatusBadge`: `6px` dot + `10.5px` tinted capsule (`positive` / `warning` / `destructive` / `neutral`).
- `SettingsCodeSnippet`: selectable `11px` monospaced block inside subtle inset box.
- `SettingsButton`: monochrome high-contrast `primary` (`#18191D` light / `#FFFFFF` dark), subtle `secondary`, soft `destructive`.
- `SettingsSwitch`, `SettingsInput`, `ChatGPTBrandMark` (renders `/icons/chatgpt-mark.svg` with `currentColor` mask or crisp img).

#### Centered Two-Pane Shell (`SettingsModal.tsx`)
- Centered portal overlay (`max-w-[860px] w-full h-[min(80vh,640px)]`, `rounded-[16px]`, `border-[var(--settings-border)]`, Esc & backdrop dismiss).
- **Left Navigation Rail (`204px`, `bg-[var(--settings-rail)]`)**:
  - Top header (`h-[52px]`): `"设置"` (`14.5px font-semibold`).
  - **4 Grouped Sections & 9 Tabs**:
    - `基础与存储`:
      1. `general` — `通用` (`settings`)
      2. `accountSecurity` — `账号与安全` (`ShieldCheck`)
      3. `library` — `素材库` (`library`)
      4. `sync` — `云同步` (`drive-sync`)
    - `采集与操作`:
      5. `captureShortcuts` — `采集与快捷键` (`screenshot`)
    - `生态与智能`:
      6. `ai` — `AI 智能` (`sparkle-board`)
      7. `externalAgents` — `外部 Agent` (`connector`)
      8. `extensions` — `插件与扩展` (`export`)
    - `系统`:
      9. `advancedAbout` — `高级与关于` (`filter`)
  - Active item uses calm neutral monochrome fill (`bg-black/[0.075]` light / `bg-white/[0.10]` dark) + semibold text.
- **Right Content Column (`bg-[var(--settings-content)]`)**:
  - Fixed `52px` header showing active tab label (`15px font-semibold`) + circular `26×26` close button (`×`, tooltip `"关闭设置 (Esc)"`), hairline divider, scrollable pane (`px-6 py-5`, `gap-[22px]`).
  - Triggers `syncAIStore.loadSyncConfig()`, `loadAIConfig()`, `loadTypeSafeConfig()`, `loadCacheStats()`, `loadExternalAgentConfig()` on open.

#### Reusable Modal (`GoogleOAuthSetupModal.tsx`)
- Mirrors `GoogleOAuthSetupSheet.swift` for Web:
  - Link to Google Cloud OAuth setup tutorial (`https://github.com/mizorewww/gdirect/blob/main/docs/configuration/google-cloud.md`).
  - **One-click `client_secret.json` file importer** (`<input type="file" accept=".json">`, reads JSON, extracts `(json.installed ?? json.web ?? json).client_id` & `client_secret`, populates or saves immediately).
  - Manual `Client ID` + `Client Secret` inputs, `"保存凭据"` / `"保存并前往 Google 登录"` button (optionally triggers `apiClient.startGoogleOAuth()` after save).

#### The 9 Focused Panes
1. **`GeneralSettingsPane.tsx` (`通用`)**:
   - `外观与图标` section: Theme mode cards (`浅色` / `深色` / `跟随系统`), App icon cards (`跟随主题` / `浅色` / `深色` using `CharkleBrandMark` preview — NO icon gallery wall!), `画廊默认排布` segmented control (`纵向瀑布流` / `横向等高行` / `画廊视图`).
   - `入门与帮助` section: `快速上手引导` row + `"重新查看"` primary button (`closeSettings(); presentOnboarding()`).
2. **`AccountSecurityPane.tsx` (`账号与安全`)**:
   - Preserves 100% of existing `AccountSecurityTab.tsx` functionality (current admin + logout, change password, active sessions list + revoke / revoke-others, personal access tokens `chk_...` creation with scopes + copy-once banner + revocation) restyled with `SettingsChrome` (`SettingsSection`, `SettingsCard`, `SettingsRow`, `SettingsButton`).
3. **`LibrarySettingsPane.tsx` (`素材库`)**:
   - `当前存储位置` section: active storage headline + location summary (`activeStorageSummary`), `"同步设置"` button (when cloud, switches to `sync`) + `"更改或转移…"` primary button opening **Unified Location Migration / Switch Wizard** (supports segmented `"完整无损迁移（推荐）"` vs `"仅切换指向位置"`, 3 target modes `Google Drive` / `WebDAV 云盘` / `本地文件夹`, live migration report), plus `"本地目录同步检查 → 立即扫描"` row when `localOnly`, and `InlineGuideDisclosure("切换存储方式会丢失素材吗？怎么安全搬家")`.
   - `缓存空间` section: 3-segment visual bar (`画廊预览图`, `临时原件`, `常驻离线`), `2–100 GB` budget slider, `"清理临时原件缓存 → 立即清理"`.
4. **`SyncSettingsPane.tsx` (`云同步`)**:
   - **When `localOnly`**: `云端同步服务` onboarding section with `"管理素材库位置"` (`→ library`), `"Google Drive 云端直连"` (`启用 Google 同步` + `InlineGuideDisclosure`), and `"WebDAV 云盘"` (`配置 WebDAV…` opening WebDAV editor sheet).
   - **When Cloud active**:
     - `同步状态` section: status dot/spinner, phase title + `%`, linear progress bar when active, `"立即同步"` button, last synced relative time, pending count, last report summary (`↑ N  ↓ M  +K 新发现`).
     - `Google Drive 账号` section (when Google): account avatar + email + `已直连` badge + storage quota bar (when `storageUsedBytes`/`storageLimitBytes` present) + `切换账号` / `退出` (or `配置凭据并登录` / `使用 Google 登录`), `云端保存路径` input (`rootFolderName`), `团队共享协作（可选）` section (`sharedFolderURLOrID`, `"选择与我共享"` picker modal, `清除`, `InlineGuideDisclosure`).
     - `WebDAV 服务` section (when WebDAV): host/account summary + `"测试连接"` + `"编辑配置…"` (modal sheet with URL, username, password, remote path, test + save) + `InlineGuideDisclosure`.
     - `同步偏好` section: `自动同步周期` select, `同步轻量化预览图` switch, `同步智能搜索索引` switch.
5. **`CaptureShortcutsSettingsPane.tsx` (`采集与快捷键`)**:
   - `应用内采集` section: default capture target (`收件箱` / `指定文件夹` / `当前活跃情绪板`) + `"立即采集"` button; compact row summarizing window drag-and-drop, `⌘V` global paste, `⇧⌘N` quick capture + `"安装浏览器扩展"` button (`→ extensions`).
   - Cleanly grouped shortcut sections (`采集与全局`, `画廊与整理`, `预览与视图`, `情绪板画布`) with monospaced keycap badges + Windows/Linux `Ctrl` hint.
6. **`AISettingsPane.tsx` (`AI 智能`)**:
   - `基础离线能力` section (caption `"免费内置 · 无需下载模型"`): 4 compact badges (`自动配色提取`, `视觉相似推荐`, `图内文字检索`, `中文与拼音快搜`).
   - `云端增强智能` section:
     - Status-first header row: if not ready → `"Gemini / 自定义 API…"` + `"连接 ChatGPT…"` + `InlineGuideDisclosure("各方案怎么选？如何获取 API 密钥")`; if ready → provider & active model summary + **`"测试连接"`** (`syncAIStore.testAIConnection`) + `"更改配置…"`.
     - Below divider (when `provider !== 'disabled'`): `导入时自动分析` & `仅上传轻量化预览图` switches.
     - **`CloudAIConfigModal`**: 4-way provider segmented bar; ChatGPT connected status / token connect / model selector + refresh / disconnect; Gemini key + Google AI Studio link + collapsible advanced URL/models; Custom API with **5 one-click presets** (`OpenAI`, `Claude`, `OpenRouter`, `DeepSeek`, `Ollama 本地`), format picker, Base URL, API key, chat & embedding models; footer with **`"测试连接"`** + `"保存配置"`.
   - `进阶视觉定位（实验性）` section: master toggle `"精准画面定位与智能分拣"`, status row (`已开启 N/6 项增强场景` + `"测试连接"` + `"密钥与功能开关…"` opening `TypeSafeConfigModal`), `InlineGuideDisclosure("这是什么？和上方云端 AI 有什么区别？")`.
   - `用量统计` section: compact one-line summary (`今日 N 次 · 累计 M 次（X tokens）`) + `"查看明细…"` opening `UsageDetailModal` (`普通云端模型` & `视觉定位引擎` buckets, per-bucket `清零` + `全部清零`).
7. **`ExternalAgentsSettingsPane.tsx` (`外部 Agent`)**:
   - `访问与安全边界` section: `"允许外部 AI 工具接入"` switch, `"权限级别"` segmented picker (`仅只读` / `允许整理与生板`), `InlineGuideDisclosure("数据安全如何保障？")`.
   - `接入常用 AI 客户端` section:
     - `HTTP MCP 远程接入`: `"前往创建令牌"` (`→ accountSecurity`) + `"复制 JSON 配置"` + `InlineGuideDisclosure("查看 HTTP MCP 配置片段")` (with endpoint readout).
     - `本地命令行 (stdio) 接入`: `"复制 JSON 配置"` + `InlineGuideDisclosure("查看本地命令行配置片段")`.
     - `InlineGuideDisclosure("查看全部 14 个可用工具清单")` (folded clean table from `shortcuts.ts`).
   - `使用指南` section: `"不知道怎么跟 AI 开口？查看 3 条推荐对话示例"` (`InlineGuideDisclosure` with 3 copyable design-workflow prompts).
8. **`ExtensionsSettingsPane.tsx` (`插件与扩展`)**:
   - `浏览器采集扩展` section:
     - `Charkle 浏览器采集扩展` (`Chrome / Edge / Arc / Brave`): `"下载扩展 (.zip)"` (`/api/v1/extension/download`), `"复制当前服务地址"`, `"生成扩展令牌"` (one-time reveal box with copy), `InlineGuideDisclosure("如何安装并连接浏览器扩展（3 步）")`.
     - `Safari / 移动端书签小工具`: draggable `"收藏到 Charkle"` pill + `"复制书签代码"`.
   - `Figma 与 FigJam` section:
     - `Charkle → Figma / FigJam 插件`: subtitle (`"纯本地离线导入，无需 API 密钥，保留独立图层、原图像素与动图"`), `"下载 Figma 插件 (.zip)"` (`/api/v1/figma-plugin/download`), `InlineGuideDisclosure("如何在 Figma 桌面端导入（仅首次需要，3 步）")`, `InlineGuideDisclosure("查看情绪板导入 Figma / FigJam 完整流程")`.
9. **`AdvancedAboutSettingsPane.tsx` (`高级与关于`)**:
   - `Google Drive 凭据` section: status of `hasGoogleOAuthConfig` + `"管理凭据…"` / `"配置凭据…"` opening `GoogleOAuthSetupModal`.
   - `索引与数据维护` section: **`"重建本地视觉与配色索引"`** row (`开始扫描` calling `syncAIStore.rebuildLocalVisualIndex(Object.keys(libraryStore.assetsByID))` + live linear progress bar `已完成 X / Y`, followed by `libraryStore.loadAssets()`).
   - `关于 Charkle` section: `CharkleBrandMark(44)`, `Charkle` + `v1.0.0`, crisp plain-Chinese summary (`"视觉素材库与情绪板工作台 · 离线配色与相似检索 + 多端云同步"`).

---

## 4. Verification Gate (Post-Round-3)

1. `npm run typecheck` — 0 errors across `@charkle/shared`, `@charkle/server`, `@charkle/client`.
2. `npm test` — all existing + new server tests pass (`POST /api/v1/ai/test`, `POST /api/v1/ai/analyze` with `localOnly: true`, `GET /api/v1/figma-plugin/download`).
3. `npm run build` — clean production bundle.
4. **Copy & UI Audit**:
   - Grep `packages/client/src` user-facing strings to confirm **0 occurrences** of `Gallery-First`, `Liquid Glass`, `16-Grid`, `Layered`, `Duotone`, `Manifest V3`, `scrypt`, `FTS5`, `CIELAB`, `MMR`, `Agent Harness`, `Apple Vision`, `gdirect`, `刘海`.
   - Verify centered 9-pane Settings overlay opens via `⌘,` and bottom-left Sidebar Settings button (both expanded & collapsed rail), supports `Esc` & backdrop close, and switches cleanly between Light & Dark themes.
   - Verify 6-step Onboarding opens on first launch (when `charkle.hasCompletedOnboarding` is unset), every step and overall flow is skippable, shockwave seal plays on `完成`, and `"重新查看"` in `设置 → 通用` + `⌘J` re-opens it cleanly.
   - Verify all deep-links route to the exact pane (`MoodboardGeneratorModal` → `ai`, `ExportBoardModal` / `QuickCaptureModal` / `JumpAnywhereModal` install → `extensions`, Sidebar sync pill → `library`/`sync`, User menu → `accountSecurity`).
