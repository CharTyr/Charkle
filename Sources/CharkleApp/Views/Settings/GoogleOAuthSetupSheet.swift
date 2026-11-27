import CharkleCore
import SwiftUI

/// Guided Google Drive OAuth desktop-client credential setup sheet.
/// Supports one-click local `gdirect` import, `client_secret.json` file import, or manual Client ID/Secret entry.
public struct GoogleOAuthSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    public let syncAndAI: SyncAndAIStore
    public let autoSignInAfterSave: Bool
    public let onCompleted: () -> Void

    @State private var clientIDInput: String = ""
    @State private var clientSecretInput: String = ""

    public init(
        syncAndAI: SyncAndAIStore,
        autoSignInAfterSave: Bool = true,
        onCompleted: @escaping () -> Void = {}
    ) {
        self.syncAndAI = syncAndAI
        self.autoSignInAfterSave = autoSignInAfterSave
        self.onCompleted = onCompleted
    }

    public var body: some View {
        let hasGDirect = syncAndAI.gdirectSnapshot.cliPath != nil

        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("配置 Google Drive 登录凭据")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Charkle 直连你自己的 Google Drive，仅首次需要配置一次桌面端凭据，密钥安全保存于 macOS 钥匙串。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            SettingsSheetFeedbackBanner(syncAndAI: syncAndAI)

            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Link(destination: SettingsHelpers.gdirectTutorialURL) {
                        HStack(spacing: 5) {
                            Image(systemName: "book.pages")
                            Text("查看 Google Cloud 桌面端凭据 3 分钟图文教程")
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 12, weight: .medium))
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    if hasGDirect {
                        Button {
                            Task {
                                let ok = await syncAndAI.importGoogleOAuthFromGDirect()
                                if ok {
                                    dismiss()
                                    onCompleted()
                                    if autoSignInAfterSave {
                                        _ = await syncAndAI.signInGoogleDrive()
                                    }
                                }
                            }
                        } label: {
                            Label("从本机 gdirect 一键导入", systemImage: "arrow.down.doc.fill")
                        }
                        .buttonStyle(SettingsPrimaryButtonStyle())
                        .disabled(syncAndAI.isBusy)
                    }

                    Button {
                        SettingsHelpers.presentOAuthSecretImporter(
                            syncAndAI: syncAndAI,
                            autoSignInAfterImport: autoSignInAfterSave
                        ) {
                            dismiss()
                            onCompleted()
                        }
                    } label: {
                        Label("导入 client_secret.json…", systemImage: "doc.badge.plus")
                    }
                    .buttonStyle(SettingsSecondaryButtonStyle())

                    Spacer()
                }
            }
            .padding(12)
            .background(
                SettingsPalette.subtleFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(SettingsPalette.border(for: colorScheme), lineWidth: CharkleTheme.hairlineWidth)
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("或手动粘贴创建的桌面端凭据")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Client ID")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("例如：1234567890-xxxx.apps.googleusercontent.com", text: $clientIDInput)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Client Secret")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    SecureField("例如：GOCSPX-xxxxxxxx", text: $clientSecretInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            HStack {
                Button("取消") {
                    dismiss()
                }
                .buttonStyle(SettingsSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button(autoSignInAfterSave ? "保存并前往 Google 登录" : "保存凭据") {
                    let cid = clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    let secret = clientSecretInput.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task {
                        let saved = await syncAndAI.saveGoogleOAuthClientConfig(clientID: cid, clientSecret: secret)
                        if saved {
                            dismiss()
                            onCompleted()
                            if autoSignInAfterSave {
                                _ = await syncAndAI.signInGoogleDrive()
                            }
                        }
                    }
                }
                .buttonStyle(SettingsPrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(clientIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || syncAndAI.isBusy)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            syncAndAI.errorMessage = nil
            syncAndAI.statusMessage = nil
        }
    }
}
