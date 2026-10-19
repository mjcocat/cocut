import AppKit
import SwiftUI

/// First-run guide: the macOS permissions Cocut needs, with live status and one-click fixes,
/// plus a short how-to. Shown on first launch and from Help › Setup Guide.
struct SetupGuideView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let settings = model.settings
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    step(number: 1,
                         title: "Allow screen recording",
                         done: model.hasScreenPermission,
                         detail: "Cocut records the game film playing on your screen, so macOS needs your OK. Click Open Settings, turn on Cocut under Screen & System Audio Recording, then click Reopen Cocut. macOS only applies it after a restart.") {
                        Button("Open Settings") { model.requestPermission() }
                        Button("Reopen Cocut") { model.relaunch() }
                            .disabled(model.hasScreenPermission)
                    }

                    step(number: 2,
                         title: "Allow updates",
                         done: settings.appManagementConfirmed,
                         optional: true,
                         detail: "Cocut updates itself from GitHub. Because it isn't from the App Store, macOS asks before letting it replace its own app. Click Open Settings and turn on Cocut under App Management. If Cocut isn't listed, use + and pick it from Applications.") {
                        Button("Open Settings") { model.updater.openAppManagementSettings() }
                        Toggle("I've turned it on", isOn: Binding(
                            get: { settings.appManagementConfirmed },
                            set: { settings.appManagementConfirmed = $0 }
                        ))
                        .toggleStyle(.checkbox)
                    }

                    step(number: 3,
                         title: "Fill in the Player Card",
                         done: !model.profile.profile.isEmpty,
                         optional: true,
                         detail: "Name, photo, position, club and contact details for the intro and end cards of the reel.") {
                        Button("Open Player Card") {
                            model.requestedSection = .playerCard
                            dismiss()
                        }
                    }

                    howTo
                }
                .padding(22)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 640)
        .onAppear { model.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refreshPermission()
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Image("Logo")
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to Cocut").font(.title.weight(.bold))
                Text("A few one-time steps so recording and updates work smoothly.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(22)
    }

    private var howTo: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HOW IT WORKS")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            tip("record.circle", "Open the film on YouTube or Hudl, click **Record Region**, drag over the video, then **Start**.")
            tip("play.circle", "Each time you press play a clip starts. Pause and it saves. Click **Done** when finished.")
            tip("keyboard", "From any app, even with the video in fullscreen: **⌥⌘N** picks a region, **⌥⌘F** records the full screen, and **⌥⌘R** repeats the last region. Press the same keys again to finish.")
            tip("film.stack", "Reorder, trim, tag and group clips into sections. Then **Export** the reel with your Player Card.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
    }

    private var footer: some View {
        HStack {
            Text("Open this again any time from Help › Setup Guide.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(model.hasScreenPermission ? "Done" : "Finish Later") {
                model.settings.hasCompletedSetup = true
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
        }
        .padding(16)
    }

    private func step<Actions: View>(number: Int, title: String, done: Bool, optional: Bool = false,
                                     detail: String, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done ? Color.green : Color.accentColor.opacity(0.15))
                    .frame(width: 30, height: 30)
                if done {
                    Image(systemName: "checkmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.accentColor)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.headline)
                    if optional {
                        Text("Recommended")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().strokeBorder(Color.secondary.opacity(0.4)))
                    }
                    if done {
                        Text("Done").font(.caption.weight(.semibold)).foregroundStyle(.green)
                    }
                }
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) { actions() }
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(done ? Color.green.opacity(0.06) : Color.primary.opacity(0.04))
        )
    }

    private func tip(_ icon: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(Color.accentColor)
                .frame(width: 20)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
