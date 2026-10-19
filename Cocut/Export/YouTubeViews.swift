import AppKit
import SwiftUI

/// Settings › YouTube: one-time Google setup, then sign in.
struct YouTubeSettings: View {
    @Bindable var account: YouTubeAccount
    @State private var showingSetup = false

    var body: some View {
        Form {
            Section {
                statusRow
            } header: {
                Text("Upload reels to YouTube")
            } footer: {
                Text("Cocut uploads with your own Google sign-in. Nothing goes through anyone else's servers.")
                    .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup("One-time setup in Google Cloud (about 10 minutes)", isExpanded: $showingSetup) {
                    VStack(alignment: .leading, spacing: 8) {
                        step(1, "Open Google Cloud Console and create a project (any name, like “Cocut”).",
                             link: "https://console.cloud.google.com/projectcreate")
                        step(2, "Turn on “YouTube Data API v3” for that project.",
                             link: "https://console.cloud.google.com/apis/library/youtube.googleapis.com")
                        step(3, "Set up the OAuth consent screen: User type External, app name Cocut, your email. Under Test users, add the Google account that owns your YouTube channel.",
                             link: "https://console.cloud.google.com/apis/credentials/consent")
                        step(4, "Create credentials › OAuth client ID › Application type “Desktop app”. Copy the Client ID and Client secret into the fields below.",
                             link: "https://console.cloud.google.com/apis/credentials")
                        Text("While the Google project is in Testing, Google asks you to sign in again about once a week. That's normal.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 6)
                }
                TextField("Client ID", text: $account.clientID, prompt: Text("1234…apps.googleusercontent.com"))
                SecureField("Client secret", text: $account.clientSecret)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .onAppear { if !account.isConfigured { showingSetup = true } }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch account.status {
        case .notConfigured:
            Label("Finish the one-time setup below, then sign in.", systemImage: "gearshape")
        case .signedOut:
            HStack {
                Label("Not signed in", systemImage: "person.crop.circle.badge.xmark")
                Spacer()
                Button("Sign In with Google") { account.signIn() }
                    .buttonStyle(.borderedProminent)
            }
        case .signingIn:
            HStack {
                ProgressView().controlSize(.small)
                Text("Finish signing in in your browser…")
                Spacer()
                Button("Cancel") { account.cancelSignIn() }
            }
        case .signedIn(let channel):
            HStack {
                Label("Signed in: \(channel)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Sign Out") { account.signOut() }
            }
        case .failed(let message):
            HStack {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Spacer()
                Button("Try Again") { account.signIn() }
                    .disabled(!account.isConfigured)
            }
        }
    }

    private func step(_ n: Int, _ text: String, link: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n).").bold().monospacedDigit()
            VStack(alignment: .leading, spacing: 2) {
                Text(text).fixedSize(horizontal: false, vertical: true)
                Link("Open", destination: URL(string: link)!)
                    .font(.caption)
            }
        }
    }
}

/// Upload a finished reel: title and description from the Player Card, unlisted by default.
struct YouTubeUploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var title = ""
    @State private var details = ""
    @State private var privacy: YouTubePrivacy = .unlisted

    private var account: YouTubeAccount { model.youtube }
    private var uploader: YouTubeUploader { model.uploader }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.red).font(.title2)
                Text("Upload to YouTube").font(.title2.weight(.semibold))
            }
            switch uploader.state {
            case .finished(let id):
                finished(id)
            default:
                if account.isSignedIn {
                    form
                } else {
                    signInPrompt
                }
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            uploader.reset()
            title = YouTubeUploader.title(for: model.profile.profile)
            details = YouTubeUploader.description(for: model.profile.profile)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 12) {
            if case .signedIn(let channel) = account.status {
                Text("Uploading to \(channel)").font(.callout).foregroundStyle(.secondary)
            }
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
            Text("Description").font(.callout.weight(.medium))
            TextEditor(text: $details)
                .font(.body)
                .frame(height: 170)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            Picker("Visibility", selection: $privacy) {
                ForEach(YouTubePrivacy.allCases) { Text($0.title).tag($0) }
            }
            Text("Unlisted is usual for recruiting: coaches can watch with the link, but it won't show up in search.")
                .font(.caption)
                .foregroundStyle(.secondary)

            switch uploader.state {
            case .uploading(let fraction):
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: fraction)
                    Text("Uploading… \(Int(fraction * 100))%").font(.callout).monospacedDigit()
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }

            HStack {
                Text(file.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if uploader.isUploading {
                    Button("Cancel Upload") { uploader.cancel() }
                } else {
                    Button("Close") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Upload") {
                        uploader.upload(file: file, title: title, description: details, privacy: privacy, account: account)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var signInPrompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            if account.isConfigured {
                Text("Sign in with the Google account that owns your YouTube channel.")
                HStack {
                    if account.status == .signingIn {
                        ProgressView().controlSize(.small)
                        Text("Finish signing in in your browser…")
                    } else {
                        Button("Sign In with Google") { account.signIn() }
                            .buttonStyle(.borderedProminent)
                    }
                    Spacer()
                    Button("Close") { dismiss() }
                }
                if case .failed(let message) = account.status {
                    Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            } else {
                Text("Uploading needs a one-time setup in Google Cloud, so Cocut can sign in with your own account. It takes about 10 minutes, with step-by-step links.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    SettingsLink { Text("Open YouTube Settings…") }
                        .buttonStyle(.borderedProminent)
                    Spacer()
                    Button("Close") { dismiss() }
                }
                Text("Settings › YouTube").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func finished(_ id: String) -> some View {
        let link = "https://youtu.be/\(id)"
        return VStack(alignment: .leading, spacing: 12) {
            Label("Uploaded. YouTube may take a few minutes to finish processing it.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
            HStack {
                Text(link).font(.body.monospaced()).textSelection(.enabled)
                Spacer()
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
            HStack {
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(link, forType: .string)
                }
                Button("Open on YouTube") { NSWorkspace.shared.open(URL(string: link)!) }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
