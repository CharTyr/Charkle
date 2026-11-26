# Charkle for iPadOS & iOS

Universal native SwiftUI + UIKit client for **iPadOS 18+** and **iOS 18+**, directly sharing [`CharkleCore`](../Sources/CharkleCore) and the lossless `/.charkle/` bidirectional sync protocol with Charkle macOS and Windows.

## MVP Scope

- **Universal Adaptive Shell**:
  - **iPad**: `NavigationSplitView` sidebar (Library, Inbox, Recent, Untagged, Trash, nested Folders, Smart Folders, Tags, Sync status) + multi-column pure-image masonry waterfall + docked 320pt Inspector + hardware keyboard shortcuts (`⌘N`, `⌘R`, `⇧⌘V`).
  - **iPhone**: 4-tab `TabView` (素材库 / 收件箱 / 搜图 / 同步) + swipe-up folder drawer + full-screen Quick Look with sheet Inspector.
- **Multi-Source Capture**:
  - System **Share Extension** (`CharkleShareExtension`) for one-tap saving from Xiaohongshu, X, Safari, Photos, and Files into Inbox or any synced Charkle folder.
  - In-app capture hub: Photos multi-select (images & videos), Camera capture, Files importer, one-tap Clipboard capture, and link/share-copy parser.
- **Browse & Visual Search**:
  - Full-text + CJK / Pinyin + OCR search, 10 calibrated `DESIGN.md` color swatches with adjustable tolerance, media kind / aspect shape / rating filters, and local Apple Vision **Similar Assets** search inside Quick Look.
- **Google Drive Bidirectional Sync**:
  - Native RFC 8252 `ASWebAuthenticationSession` + PKCE (`S256`) sign-in, synced root folder (`Charkle`) or shared Google Drive folder collaboration, progressive thumbnail-first loading, and LRU original cache budget with offline pinning.

## Quick Start in Xcode

1. Open `ios/CharkleMobile.xcodeproj` in Xcode.
2. In **Signing & Capabilities** for both `CharkleMobile` and `CharkleShareExtension`, select your Apple Development Team (and update the bundle identifier prefix / App Group `group.com.charkle.mobile` if deploying to a personal physical device).
3. Select an iPad or iPhone destination and press **Run (`⌘R`)**.

## Setting Up Google Drive Sign-In on iOS / iPadOS

Google OAuth on iOS/iPadOS requires an **iOS OAuth Client ID** (using PKCE with no client secret):

1. Open **Google Cloud Console → APIs & Services → Credentials → Create Credentials → OAuth client ID**.
2. Choose **iOS** as the application type and enter your app's Bundle Identifier (default `com.charkle.mobile`).
3. Download the `.plist` (or copy the generated `<prefix>.apps.googleusercontent.com` Client ID).
4. In the app, open **同步 → Google 账号与授权凭据**, import the `.plist` / `.json` file or paste the Client ID, then tap **使用 Google 账号登录**.

> Tip: For zero-config personal builds, you can also place your local `GoogleOAuthClient-iOS.plist` (gitignored) into `ios/CharkleMobile/` and add it to the app target's Copy Bundle Resources phase.
