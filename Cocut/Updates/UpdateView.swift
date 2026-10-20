import AppKit
import SwiftUI

struct UpdateView: View {
    let updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch updater.state {
            case .idle, .checking:
                status(icon: nil, title: "Checking for updates…", detail: nil)
                HStack { Spacer(); Button("Cancel") { updater.dismiss() } }

            case .upToDate:
                status(icon: "checkmark.seal.fill", tint: .green,
                       title: "You're up to date",
                       detail: "Cocut \(updater.currentVersion) is the newest version.")
                HStack {
                    Spacer()
                    Button("OK") { updater.dismiss() }.keyboardShortcut(.defaultAction)
                }

            case .available(let release):
                available(release)

            case .downloading(let release):
                status(icon: nil, title: "Downloading Cocut \(release.version)…", detail: nil)

            case .installing(let release):
                status(icon: nil, title: "Installing Cocut \(release.version)…",
                       detail: "Cocut will reopen in a moment.")

            case .blocked(let path):
                status(icon: "lock.shield.fill", tint: .orange,
                       title: "macOS blocked the update",
                       detail: "Cocut downloaded the new version but isn't allowed to replace itself yet. Turn on Cocut in System Settings › Privacy & Security › App Management, then quit and reopen Cocut (macOS applies the permission on relaunch) and choose Check for Updates again. Or drag the downloaded Cocut into Applications yourself.")
                HStack {
                    Button("Show Download") { updater.revealDownloadedApp(path) }
                    Spacer()
                    Button("Close") { updater.dismiss() }
                    Button("Open App Management") { updater.openAppManagementSettings() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }

            case .failed(let message):
                status(icon: "exclamationmark.triangle.fill", tint: .orange,
                       title: "Update problem", detail: message)
                HStack {
                    Button("Open Releases Page") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repo)/releases/latest")!)
                    }
                    Spacer()
                    Button("Close") { updater.dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(24)
        .frame(width: 520)
        .animation(.snappy, value: updater.state)
    }

    @ViewBuilder
    private func available(_ release: Updater.Release) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 56, height: 56)
            VStack(alignment: .leading, spacing: 4) {
                Text("Cocut \(release.version) is available")
                    .font(.title3.weight(.semibold))
                Text("You have version \(updater.currentVersion).")
                    .foregroundStyle(.secondary)
            }
        }

        if !release.whatsNew.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("What's new").font(.headline)
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(release.whatsNew) { changes in
                            VStack(alignment: .leading, spacing: 5) {
                                if release.whatsNew.count > 1 {
                                    Text("Version \(changes.version)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                ForEach(changes.items, id: \.self) { item in
                                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                                        Text("•").foregroundStyle(.secondary)
                                        Text(Self.markdown(item))
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                }
                .frame(maxHeight: 280)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
        } else {
            Button("See What's New on GitHub") { NSWorkspace.shared.open(release.pageURL) }
                .buttonStyle(.link)
        }

        HStack {
            Button("Skip This Version") { updater.skip(release) }
            Spacer()
            Button("Later") { updater.later(release) }
                .keyboardShortcut(.cancelAction)
                .help("Remind me tomorrow")
            Button("Install and Relaunch") { updater.install(release) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
    }

    private func status(icon: String?, tint: Color = .accentColor, title: String, detail: String?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let icon {
                    Image(systemName: icon).font(.system(size: 30)).foregroundStyle(tint)
                } else {
                    ProgressView().controlSize(.regular)
                }
            }
            .frame(width: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let detail {
                    Text(detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}
