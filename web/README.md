# Charkle Web

Self-hosted full-stack TypeScript visual reference library & rapid moodboard studio — featuring 1:1 domain parity and lossless bidirectional `/.charkle/` sync with Charkle for macOS, built-in MCP server, and bundled Figma / FigJam bridge plugin.

## Workspace Architecture

| Package | Path | Responsibility |
| --- | --- | --- |
| `@charkle/shared` | `packages/shared` | Canonical domain models (`AssetRecord`, `MoodboardDocument`, `DriveSyncConfig`, `AuthStatus`), CIELAB/CIEDE2000 color math, `SmartFolderRule` evaluator, `EditorialLayoutSolver`, CJK/Pinyin search text utilities, lossless Swift `/.charkle/` wire codec, and typed REST + SSE API contracts. |
| `@charkle/server` | `packages/server` | Hono HTTP + SSE server, Node.js built-in `node:sqlite` WAL + FTS5 database, `sharp` media pipeline & 2-tier thumbnail cache, authentication & API tokens, bidirectional Google Drive / WebDAV / local sync engine, Cloud AI & visual grounding integration, and MCP stdio server. |
| `@charkle/client` | `packages/client` | React + Tailwind CSS v4 + Zustand visual reference gallery (vertical masonry, horizontal justified, gallery filmstrip), infinite dual-mode moodboard canvas (Auto Editorial ↔ Freeform, notes, smart group frames, connectors, ink annotations, 3D viewer), quick jump, and settings. |
| `@charkle/worker` | `packages/worker` | Cloudflare Workers edge deployment entrypoint: Static Assets SPA + SQLite-backed Durable Object (`CharkleLibraryDO`) + R2 streaming media store (`R2BlobStore`) + DO Alarm auto-sync + build-time bundled extension & Figma plugin ZIPs. |
| Figma Bridge | `figma-plugin` | Bundled Figma / FigJam bridge plugin (`manifest.json`, `code.js`, `ui.html`) for importing exported moodboard packages with editable layers. |

## Prerequisites

- **Node.js 22.13+** (tested on **Node.js 26.11.0**, using built-in `node:sqlite` — no native SQLite addon compilation required).

## Quick Start

```bash
# Install all workspace dependencies
npm install

# Start development servers (API server on :3417 + Vite client on :5173)
npm run dev

# Type-check all packages
npm run typecheck

# Run test suites
npm test

# Build production bundles
npm run build

# Start production server
npm start

# Launch MCP stdio server for external AI agents
npm run mcp
```

## Docker Deployment

```bash
docker build -t charkle-web .
docker run -d \
  --name charkle-web \
  -p 3417:3417 \
  -v charkle_data:/data \
  -e CHARKLE_DATA_DIR=/data \
  charkle-web
```

## Cloudflare Workers 部署指南

Charkle Web 支持零服务器一键部署至 **Cloudflare Workers**，完整架构如下：

- **前端静态资源**：通过 Workers Static Assets 托管 `packages/client/dist`（SPA 路由回退，`/api/*` 优先路由至 Worker）。
- **数据库、鉴权与加密密钥库**：运行在单个 SQLite-backed Durable Object（`CharkleLibraryDO`）内，原生持久化素材索引、情绪板、会话、API Token 与 AES-256-GCM `SecretVault`。
- **原图与缩略图存储**：全部存储于 Cloudflare **R2**（`MEDIA_BUCKET`），原生支持 HTTP `206 Partial Content` 视频/音频分段流式播放。
- **后台定时同步**：使用 Durable Object **Alarm** 按配置的间隔自动触发 Google Drive / WebDAV 双向同步。
- **插件包下载**：通过 `npm run cf:pack` 在构建阶段预打包浏览器剪藏扩展与 Figma 桥接插件 ZIP，运行时零 `node:fs` 依赖。

### 1. 登录 Wrangler 并创建 R2 存储桶

> 需要已开通 Workers（含 Durable Objects SQLite）与 R2 功能的 Cloudflare 账号。

```bash
npm install
npx wrangler login

# 创建生产与预览 R2 Bucket（名称需与 packages/worker/wrangler.jsonc 一致）
npx wrangler r2 bucket create charkle-media
npx wrangler r2 bucket create charkle-media-preview
```

### 2. 配置生产密钥（Wrangler Secrets）

在部署前设置 AES-256-GCM 密钥库主密钥 `CHARKLE_VAULT_KEY`（强烈建议随机生成 32 字节以上高熵字符串，如 `openssl rand -base64 32`）：

```bash
# 必填（生产环境）：用于加密存储 AI Key、Google OAuth Token、WebDAV 密码
npx wrangler secret put CHARKLE_VAULT_KEY --cwd packages/worker

# 可选：首次启动自动初始化管理员账号（不设置则通过网页引导页完成注册）
npx wrangler secret put CHARKLE_ADMIN_USERNAME --cwd packages/worker
npx wrangler secret put CHARKLE_ADMIN_PASSWORD --cwd packages/worker
```

> 本地开发时可在 `packages/worker/.dev.vars` 中写入 `CHARKLE_VAULT_KEY=...`（已加入 `.gitignore`，切勿提交至版本库）。

### 3. 本地开发、打包校验与部署

```bash
# 仅预打包扩展与 Figma 插件 ZIP 到 packages/worker/src/generated/bundles.ts
npm run cf:pack

# 单独校验 Worker 包 TypeScript 类型
npm run cf:typecheck

# 本地启动完整 workerd 仿真环境（含真实 DO SQLite + 本地 R2 模拟 + SPA 前端）
npm run cf:dev

# 完整构建并执行部署干跑（检查打包体积、DO 迁移、R2 与静态资源绑定）
npm run cf:dry-run

# 正式构建并部署到 Cloudflare Workers
npm run cf:deploy
```

### 4. 配置 Google Drive / WebDAV 双向同步

部署完成后，登录 Charkle Web 进入 **设置 → 云端同步**：

- **Google Drive 同步**：在 Google Cloud Console 创建 Web 应用 OAuth 2.0 客户端，将以下地址添加到 **Authorized redirect URIs**：
  ```text
  https://<your-domain>/api/v1/sync/google/oauth/callback
  ```
  随后在网页设置界面（或通过 `wrangler secret put CHARKLE_GOOGLE_CLIENT_ID` / `CHARKLE_GOOGLE_CLIENT_SECRET`）填入凭据并完成授权。Charkle Web 会与 Charkle macOS 共享同一个 `/.charkle/` 目录，并由 Durable Object Alarm 自动保持双向同步。
- **WebDAV 同步**：直接在设置界面填写 WebDAV 服务器 URL、用户名、密码与远端目录（如 `/Charkle`），点击测试连接后保存即可启用自动同步。
- **可选优化（Cloudflare Images）**：若账号已开通 Cloudflare Images，可取消注释 `packages/worker/wrangler.jsonc` 中的 `images` 绑定以启用边缘端光栅缩略图缩放；未开通时自动无缝回退至客户端预处理与内置纯 TS 解析管线。

## Environment Variables

Copy `.env.example` to `.env` and adjust as needed. All AI provider keys, Google Drive OAuth settings, and WebDAV credentials can also be configured securely from the Web UI once signed in.
