import Foundation
import SwiftUI

/// User preferences, persisted in UserDefaults.
@MainActor
@Observable
final class AppSettings {
    var stillSeconds: Double {
        didSet { UserDefaults.standard.set(stillSeconds, forKey: Keys.still) }
    }
    var minimumClipSeconds: Double {
        didSet { UserDefaults.standard.set(minimumClipSeconds, forKey: Keys.minClip) }
    }
    var playSoundOnSave: Bool {
        didSet { UserDefaults.standard.set(playSoundOnSave, forKey: Keys.sound) }
    }
    /// The Setup Guide has been finished (or dismissed) once.
    var hasCompletedSetup: Bool {
        didSet { UserDefaults.standard.set(hasCompletedSetup, forKey: Keys.setupDone) }
    }
    /// The user says they've allowed App Management (macOS doesn't let apps check this directly).
    var appManagementConfirmed: Bool {
        didSet { UserDefaults.standard.set(appManagementConfirmed, forKey: Keys.appManagement) }
    }

    var tuning: CaptureTuning {
        CaptureTuning(stillSeconds: stillSeconds, minimumClipSeconds: minimumClipSeconds)
    }

    private enum Keys {
        static let still = "settings.stillSeconds"
        static let minClip = "settings.minimumClipSeconds"
        static let sound = "settings.playSoundOnSave"
        static let setupDone = "settings.hasCompletedSetup"
        static let appManagement = "settings.appManagementConfirmed"
    }

    init() {
        let defaults = UserDefaults.standard
        stillSeconds = defaults.object(forKey: Keys.still) as? Double ?? CaptureTuning().stillSeconds
        minimumClipSeconds = defaults.object(forKey: Keys.minClip) as? Double ?? CaptureTuning().minimumClipSeconds
        playSoundOnSave = defaults.object(forKey: Keys.sound) as? Bool ?? true
        hasCompletedSetup = defaults.bool(forKey: Keys.setupDone)
        appManagementConfirmed = defaults.bool(forKey: Keys.appManagement)
    }

    func resetRecordingDefaults() {
        stillSeconds = CaptureTuning().stillSeconds
        minimumClipSeconds = CaptureTuning().minimumClipSeconds
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            RecordingSettings(settings: model.settings)
                .tabItem { Label("Recording", systemImage: "record.circle") }
            ShortcutsSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            YouTubeSettings(account: model.youtube)
                .tabItem { Label("YouTube", systemImage: "play.rectangle") }
            UpdateSettings(updater: model.updater)
                .tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct RecordingSettings: View {
    @Bindable var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Save a clip after") {
                    HStack {
                        Slider(value: $settings.stillSeconds, in: 1.5...8, step: 0.5)
                            .frame(width: 200)
                        Text("\(settings.stillSeconds, specifier: "%.1f")s paused")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                    }
                }
                LabeledContent("Ignore clips shorter than") {
                    HStack {
                        Slider(value: $settings.minimumClipSeconds, in: 0.5...6, step: 0.5)
                            .frame(width: 200)
                        Text("\(settings.minimumClipSeconds, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 90, alignment: .leading)
                    }
                }
                Toggle("Play a sound when a clip is saved", isOn: $settings.playSoundOnSave)
            } header: {
                Text("Record When Video Plays")
            } footer: {
                Text("If quiet stretches of game film split one play into two clips, wait longer before saving. The clip always ends where you paused, so a longer wait doesn't add dead time.")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Restore Defaults") { settings.resetRecordingDefaults() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}

private struct ShortcutsSettings: View {
    var body: some View {
        Form {
            Section {
                shortcut(AppModel.hotKeyHint, "Record the same region again, or finish recording")
                shortcut(AppModel.fullScreenHotKeyHint, "Record the full screen, or finish recording")
                shortcut(AppModel.newRegionHotKeyHint, "Select a new region to record")
            } header: {
                Text("Work from any app, even with the video in fullscreen")
            }
            Section("In Cocut") {
                shortcut("⇧⌘R", "Record Region…")
                shortcut("⇧⌘F", "Record Full Screen")
                shortcut("⇧⌘L", "Record Same Region")
                shortcut("⌘I", "Import Videos…")
                shortcut("⌘E", "Export Highlight Reel")
            }
            Section("Video players (click the video first)") {
                LabeledContent("YouTube", value: "Space play/pause · ← → 5s · J L 10s · , . frame · F fullscreen")
                LabeledContent("Hudl", value: "Space play/pause · film-study player: C play/pause, Z B −2s/+5s, X V frame, D F clip")
                LabeledContent("Any site", value: "⏯ (F8) plays or pauses the browser's video without clicking it")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func shortcut(_ keys: String, _ action: String) -> some View {
        LabeledContent {
            Text(keys)
                .font(.system(.body, design: .rounded).weight(.semibold))
                .monospacedDigit()
        } label: {
            Text(action)
        }
    }
}

private struct UpdateSettings: View {
    @Bindable var updater: Updater

    var body: some View {
        Form {
            Section {
                Toggle("Check for updates automatically", isOn: $updater.checksAutomatically)
                Text("Cocut checks when it opens and every few hours, and offers new versions as they come out. It never interrupts a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Current version", value: updater.currentVersion)
                if let last = updater.lastChecked {
                    LabeledContent("Last checked", value: last.formatted(.relative(presentation: .named)))
                }
            }
            HStack {
                Spacer()
                Button("Check Now") { updater.checkNow() }
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
