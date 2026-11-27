# Charkle Android 架构与工程契约（Kotlin + Compose + Rust Core）

> **适用范围**：`android/`（Kotlin / Jetpack Compose UI 与 Android 平台适配层）及 `android/rust/charkle-android-ffi/`（面向 Android 的 UniFFI 桥接层）。  
> **前置必读**：[`DESIGN.md`](../../../DESIGN.md)、[`m3-expressive-design-system.md`](./m3-expressive-design-system.md)、[`cross-platform/index.md`](../cross-platform/index.md)。

---

## 1. 总体架构：方案 A（原生 Compose UI + 复用 Rust `charkle-core`）

遵循与 iOS 端（共享 Swift `CharkleCore`）完全一致的**「统一核心 + 宿主原生壳层」**策略，Android 直接复用仓库中已成熟且平台无关的 [`windows/crates/charkle-core`](../../../windows/crates/charkle-core/Cargo.toml)（~5.8 万行 Rust，内置 `rustls-tls` 与 `bundled` SQLite，零 Windows 系统依赖）：

```text
┌─────────────────────────────────────────────────────────────────────────┐
│                    android/app  (Kotlin + Jetpack Compose)              │
│  ┌──────────────────────┐ ┌─────────────────────┐ ┌──────────────────┐  │
│  │ Material 3 Expressive│ │ Adaptive Shell      │ │ Android Native   │  │
│  │ Theme + DynamicColor │ │ Phone / Foldable /  │ │ ShareActivity /  │  │
│  │ FloatingToolbar /    │ │ Tablet + SharedElem │ │ QS Tile / Glance │  │
│  │ ConnectedButtonGroup │ │ Transitions         │ │ Media3 / Coil 3  │  │
│  └──────────┬───────────┘ └──────────┬──────────┘ └────────┬─────────┘  │
│             └────────────────────────┼─────────────────────┘            │
│                             CharkleAppStore (StateFlow)                 │
│                                      │                                  │
│                 UniFFI Generated Kotlin Bindings + Callbacks            │
│        (AndroidSecretVault · MlKitOcrProvider · WebSnapshotBridge)      │
├──────────────────────────────────────┼──────────────────────────────────┤
│      android/rust/charkle-android-ffi (cdylib -> libcharkle_android.so) │
│   Tokio multi-thread runtime · UniFFI exports · Event stream callback   │
├──────────────────────────────────────┼──────────────────────────────────┤
│         windows/crates/charkle-core (Shared Platform-Agnostic Core)     │
│  SQLite+FTS5+Pinyin · CIELAB · /.charkle/ HLC Sync · GDrive/WebDAV/SAF  │
│  6-Platform Social & Universal Parser · EXIF/AI Prompt · Moodboard ·    │
│  Pinterest Infinite Spatial Layout & Import · Smart Dedup · Thumbnails  │
└─────────────────────────────────────────────────────────────────────────┘
```

### 1.1 工作区解耦红线（绝不破坏 Windows 构建）

- `android/rust/charkle-android-ffi/` 作为独立 Rust crate（通过相对路径 `charkle-core = { path = "../../../windows/crates/charkle-core" }` 引用），**不修改 `windows/Cargo.toml` 的 workspace 成员列表**，确保 Windows 端 `cargo check` / `cargo test` 零额外依赖负担。
- 若因 Android 平台能力（如自定义 URI Scheme PKCE Google OAuth 或 SAF 目录桥接）需向 `charkle-core` 增加极少量通用辅助方法，必须保持纯平台无关、附带单元测试，并确保 `charkle-core` 零编译警告。

---

## 2. 技术栈与目标版本

| 维度 | 选型 | 理由与约束 |
| :--- | :--- | :--- |
| **SDK / 语言** | `minSdk = 26` (Android 8.0+), `targetSdk = 36` (Android 16), `compileSdk = 36`, Kotlin `2.1+`, AGP `9.x` | 完整支持 `enableEdgeToEdge`、Adaptive Icons、Predictive Back、Android 16 Expressive 系统体验 |
| **UI 框架** | Jetpack Compose + `androidx.compose.material3:material3:1.5.0` + `material3-adaptive` + `material3-adaptive-navigation-suite` | 生产级稳定 M3 Expressive API：`MaterialExpressiveTheme`、`MotionScheme.expressive()`、`HorizontalFloatingToolbar`、`ButtonGroup`、`LoadingIndicator`、`LinearWavyProgressIndicator` |
| **作品动态取色** | `com.materialkolor:material-kolor-material3` + `material-kolor-palette`（或 Google `material-color-utilities`） | 在 Quick Look 与收件箱按作品主色实时生成 `PaletteStyle.Expressive` / `Content` 主题并做弹簧颜色插值 |
| **图片与媒体** | **Coil 3**（自定义 `CharkleThumbnailFetcher` 直连本地/同步缓存，支持静态图、GIF/WebP 动图与内存二级缓存）+ **AndroidX Media3 (ExoPlayer)** 视频/音频播放 + `PdfRenderer` PDF 预览 | 120Hz 瀑布流零丢帧加载，严禁在滑动中主线程解码大图 |
| **Rust 跨编译** | **UniFFI 0.28+**（Proc-macro 模式）+ `cargo-ndk` 编译 `arm64-v8a`（真机必选）与 `x86_64`（本地模拟器） | 自动生成类型安全、支持 `suspend` 协程的 Kotlin 异步接口与回调接口 |
| **平台 Trait 注入** | • `SecretVault` → Android Keystore + Tink AEAD / Encrypted Prefs<br>• `NativeOcrProvider` → Google ML Kit Text Recognition (Chinese + Latin 离线模型)<br>• `WebPageSnapshotProvider` → 离屏 `WebView` 静默截图（可选 Tier-2）<br>• `GoogleOAuth` → AndroidX `CustomTabsIntent` + 自定义回调 Scheme PKCE (`S256`) | 无缝接入 `charkle-core::traits`，与 Windows / macOS 共用同一套引擎逻辑 |
| **后台与存储** | AndroidX `WorkManager`（周期后台增量同步与待入库队列消费）+ Android Photo Picker + CameraX + SAF (`ACTION_OPEN_DOCUMENT_TREE`) | 遵循 Android 作用域存储，无需申请敏感全盘存储权限即可完成照片/文件导入与本地目录同步 |

---

## 3. 工程目录规划

```text
android/
├── build.gradle.kts / settings.gradle.kts / gradle/libs.versions.toml
├── scripts/
│   ├── build-rust-android.sh          # cargo-ndk 编译 .so + uniffi-bindgen 生成 Kotlin 绑定
│   └── verify-android.sh              # 统一 Rust 单测 + Kotlin lint/test + Debug APK 编译检查
├── rust/
│   └── charkle-android-ffi/
│       ├── Cargo.toml                 # cdylib + rlib，依赖 ../../../windows/crates/charkle-core
│       └── src/
│           ├── lib.rs                 # UniFFI AndroidEngineHandle、事件监听回调、平台 Trait 桥
│           ├── dto.rs                 # 面向 Kotlin 的稳定轻量记录/枚举 DTO
│           └── oauth.rs               # Android Custom Tabs PKCE 授权 URL 生成与回调码换取 Token
└── app/
    └── src/main/
        ├── AndroidManifest.xml        # MainActivity + ShareReceiveActivity + OAuthRedirectActivity + QSTile + GlanceWidget
        ├── res/                       # 48 枚双色 VectorDrawable、Roboto Flex 字体、Adaptive Icon、中英资源
        └── java/com/charkle/android/
            ├── CharkleApplication.kt
            ├── core/                  # UniFFI 封装、AndroidSecretVault、MlKitOcrBridge、ThumbnailFetcher
            ├── store/                 # CharkleAppStore (StateFlow 统一状态管理，对标 MobileAppStore)
            ├── designsystem/          # M3 Expressive Theme、Zone A/B 色彩引擎、ConnectedButtonGroup、
            │                          # ExpressiveFloatingBar、SegmentedListCard、MiniatureEmptyState
            ├── ui/
            │   ├── shell/             # AdaptiveRootShell (Phone FloatingToolbar / Tablet Rail+Inspector)
            │   ├── gallery/           # VirtualizedMasonryGallery (双指锚定缩放 + 滑动多选 + ContextMenu)
            │   ├── inbox/             # InboxTriageScreen (作品主色聚焦卡 + 自动推荐目录 + 瀑布流双模)
            │   ├── detail/            # AssetDetailScreen (作品主色沉浸 Quick Look + 原色校对 + 检查器 + 相似图)
            │   ├── search/            # MorphingSearchSheet + StudioColorFilterPanel (10色盘+色轮+HEX+容差)
            │   ├── sidebar/           # DirectoryDrawer & TabletSidebar (快筛+2列快选+可折叠树+标签云)
            │   ├── capture/           # CaptureBottomSheet + ShareReceiveActivity (系统分享无感接收)
            │   ├── moodboard/         # MoodboardsListScreen + MoodboardStudioScreen (自由/自动排版+墨水+导出)
            │   ├── pinterest/         # PinterestExploreScreen + 120Hz 无限2D画布 + 托盘 + 按板批量导入
            │   └── settings/          # SettingsScreen + MultiBackendSyncScreen (GDrive/WebDAV/本地目录)
            └── system/                # QuickCaptureTileService (通知栏磁贴) + InspirationGlanceWidget + SyncWorker
```

---

## 4. 与 iOS v1.5.0 功能 1:1 对齐矩阵

| 模块 | iOS (`CharkleMobile` v1.5.0) 现有能力 | Android 实现映射与原生增强 |
| :--- | :--- | :--- |
| **导航外壳** | iPhone 双胶囊 Liquid Glass 变形底栏 + iPad `NavigationSplitView` | 手机 `HorizontalFloatingToolbar` + 伴生形变搜索 FAB；折叠屏/平板 `NavigationSuiteScaffold` + 320dp 检查器 |
| **纯图瀑布流** | 确定性虚拟化布局、锚定双指缩放 (`1..5` / `2..7` 列)、滑动多选、情绪板定位高亮脉冲、长按菜单 | Compose 自定义确定性虚拟化坐标瀑布流 + 双指焦点缩放补偿 + 滑动多选 + 共享元素缩放转场 |
| **目录与筛选** | 顶栏快搜、2 列快速范围磁贴、可折叠多级目录树（自动展开激活路径）、智能文件夹、标签云、底栏同步状态 | 分段圆角抽屉 / 侧栏，支持文件夹新建/重命名/删空、层级选择器（`HierarchicalFolderPicker`） |
| **搜图与筛色** | 全文/CJK/拼音/OCR、10 枚 `DESIGN.md` 标定色块 + 系统取色轮 + `#RRGGBB` 输入 + CIELAB 容差滑块 (`10..55`)、格式/纵横比/评分/排序、快速跳转 | 底部可拉伸搜索栏 + 4 模切换芯片（`全部` / `主色调` / `当前目录` / `Pinterest`）+ M3 Expressive 色盘与连接分段筛选器 |
| **收件箱清理** | `逐张归档`（大卡片 + 自动推荐文件夹 + 一键入库/跳过/回收站）与 `瀑布流` 切换、空态缩影 | **Zone B 作品主色动态主题** + 卡片手势滑动归档（左滑回收/右滑归入推荐目录/上滑选目录）+ 双模切换 |
| **单图沉浸预览** | 无遮挡纵向布局、原图高倍缩放、长图全宽滚动、非破坏旋转/镜像、视频/GIF/音频/PDF/Markdown/GitHub/社媒富预览、胶片缩略条、2 页检查器（`信息` 含 EXIF/AI Prompt/色板/标签/备注/离线置顶 + `相似素材`） | **Zone B 作品主色动态主题 + 一键「原色校对」**、Media3 视频与波浪音频条、Connected Action Group、Predictive Back 缩回原位 |
| **情绪板工作室** | 1:1 读写 `/.charkle/boards/<UUID>.json`、自由画布（平移缩放/拖移/四角缩放/旋转/镜像/锁定/层级）与自动排版（均衡/杂志/紧凑）切换、5 套便签、6 色分组框、板内色卡带、连线、触控/手写笔墨水、定位回库、导出高清 PNG / PureRef `.pur` / `.charkleboard` | Compose 高帧率自由画布 + Stylus / 手指压感墨水 + 底部 Floating Toolbar 工具坞 + 全部导出格式与系统分享直出 |
| **Pinterest 无限空间** | 120Hz 全向 2D 无限画布（锚定双指连续缩放）、快选模式、购物车式「托盘」、浮层 Pin 详情 + 相似 Pin、WebView 登录与按 Board 批量建文件夹导入 | 复用 Rust `charkle-core::pinterest` 布局与解析 + Compose 硬件加速 2D 无限画布 + Android `WebView` Cookie 桥接 |
| **采集与系统分享** | 相册多选、相机、文件导入、一键剪贴板、小红书/X/GitHub/网页链接与社媒图集提取、`CharkleShareExtension` | Photo Picker + CameraX + SAF + 剪贴板 + **免权限痛点 `ShareReceiveActivity`（支持单图/多图/文字/链接直达目录）** + **下拉通知栏快捷磁贴** + **Glance 灵感微件** |
| **多后端云同步** | Google Drive (OAuth PKCE + 共享目录)、WebDAV、本地目录（iOS 另有 iCloud Drive）、渐进式元数据/缩略图流式拉取、防复活墓碑、LRU 缓存上限与离线置顶 | Google Drive (Custom Tabs PKCE，导入 `client_secret.json` 或 Client ID) + WebDAV + 本地/SAF 目录（Syncthing/NAS 友好）+ `WorkManager` 后台增量同步 |

---

## 5. UniFFI 桥接与线程安全契约

1. **单 Tokio 运行时常驻**：`charkle-android-ffi` 内部维护全局共享的 `tokio::runtime::Runtime`，所有 IO / 同步 / 抓取 / 解析方法均以 UniFFI `async fn` 暴露给 Kotlin `suspend` 函数，绝不阻塞 Android 主线程。
2. **增量事件推送**：通过 UniFFI `callback_interface` (`EngineEventListener`) 将 `LiveCharkleEngine::subscribe_events()` 广播的 `SyncStatus`、`SyncProgressiveMetadata`、`SyncProgressiveThumbnails`、`LibraryChanged`、`AssetEnriched`、`BoardUpdated` 实时桥接到 Kotlin `MutableSharedFlow`，驱动 UI 渐进刷新。
3. **二进制零拷贝路径优先**：缩略图与原图尽量通过文件系统绝对路径（`<appFilesDir>/Charkle/Thumbnails/...` 与 `Originals/...`）交由 Coil 3 / Media3 直接流式读取，避免跨 JNI 反复拷贝数兆字节图片数组。
4. **Google OAuth Android 回调契约**：支持导入 Google Cloud Console 的 Android / Desktop `client_secret.json` 或直接粘贴 Client ID，使用 RFC 8252 PKCE (`S256`) 通过 Chrome Custom Tabs 完成授权并写入 `AndroidSecretVault`（Android Keystore 加密），严禁使用嵌入式 WebView 登录 Google 账号。
