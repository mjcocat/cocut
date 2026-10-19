import AppKit
import SwiftUI

/// Title and description for a reel's YouTube upload, from the Player Card.
enum YouTubeText {
    static func title(for profile: PlayerProfile) -> String {
        let year = Calendar.current.component(.year, from: .now)
        let parts = [profile.fullName, profile.position.isEmpty ? "Volleyball" : profile.position]
            .filter { !$0.isEmpty }
        return "\(parts.joined(separator: " – ")) Highlights \(year)"
    }

    static func description(for profile: PlayerProfile) -> String {
        var lines: [String] = []
        let headline = [profile.fullName, profile.position, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)"]
            .filter { !$0.isEmpty }
        if !headline.isEmpty { lines.append(headline.joined(separator: " · ")) }
        lines.append("")
        for item in profile.details { lines.append("\(item.label): \(item.value)") }
        let contact = [profile.email, profile.phone, profile.social].filter { !$0.isEmpty }
        if !contact.isEmpty {
            lines.append("")
            lines.append("Contact: " + contact.joined(separator: " · "))
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Guided upload, no setup: copy the title and description Cocut wrote, then open YouTube's
/// upload page with the video shown in Finder, ready to drag in.
struct YouTubeUploadSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let file: URL
    @State private var title = ""
    @State private var details = ""
    @State private var copied: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "play.rectangle.fill").foregroundStyle(.red).font(.title2)
                Text("Upload to YouTube").font(.title2.weight(.semibold))
            }

            step(1, "Copy the title and description. Cocut wrote them from your Player Card; edit them here first if you like.")
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.roundedBorder)
                copyButton("Title", title)
            }
            HStack(alignment: .top) {
                TextEditor(text: $details)
                    .font(.body)
                    .frame(height: 150)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                copyButton("Description", details)
            }

            step(2, "Open YouTube's upload page, then drag the video from the Finder window that opens onto it. Paste the title and description, and under Visibility choose **Unlisted**, so coaches can watch with the link but it won't show up in search.")

            HStack {
                Text(file.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file])
                    NSWorkspace.shared.open(URL(string: "https://www.youtube.com/upload")!)
                } label: {
                    Label("Open YouTube Upload", systemImage: "arrow.up.forward.square")
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560)
        .onAppear {
            title = YouTubeText.title(for: model.profile.profile)
            details = YouTubeText.description(for: model.profile.profile)
        }
    }

    private func step(_ n: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(n)")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Circle().fill(Color.accentColor))
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyButton(_ what: String, _ text: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = what
        } label: {
            Label(copied == what ? "Copied" : "Copy", systemImage: copied == what ? "checkmark" : "doc.on.doc")
                .frame(width: 70)
        }
        .help("Copy the \(what.lowercased())")
    }
}
