import Foundation
import SwiftUI

struct StatLine: Codable, Identifiable, Hashable {
    var id = UUID()
    var label: String
    var value: String
}

enum CardStyle: String, Codable, CaseIterable, Identifiable {
    case split, centered, poster, jersey, minimal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .split: return "Split"
        case .centered: return "Centered"
        case .poster: return "Poster"
        case .jersey: return "Jersey"
        case .minimal: return "Minimal"
        }
    }
}

/// The card's look: background, text colors and type.
enum CardTheme: String, Codable, CaseIterable, Identifiable {
    case night, light, team, varsity
    var id: String { rawValue }
    var title: String {
        switch self {
        case .night: return "Night"
        case .light: return "Light"
        case .team: return "Team Color"
        case .varsity: return "Varsity"
        }
    }
}

/// Team-color presets for the card's accent.
enum CardAccent: String, Codable, CaseIterable, Identifiable {
    case blue, sky, teal, green, gold, orange, red, maroon, purple, silver
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .blue: return Color(red: 0.16, green: 0.44, blue: 1.00)
        case .sky: return Color(red: 0.20, green: 0.70, blue: 1.00)
        case .teal: return Color(red: 0.10, green: 0.78, blue: 0.72)
        case .green: return Color(red: 0.20, green: 0.80, blue: 0.40)
        case .gold: return Color(red: 1.00, green: 0.76, blue: 0.16)
        case .orange: return Color(red: 1.00, green: 0.50, blue: 0.14)
        case .red: return Color(red: 0.95, green: 0.20, blue: 0.24)
        case .maroon: return Color(red: 0.62, green: 0.12, blue: 0.22)
        case .purple: return Color(red: 0.58, green: 0.32, blue: 0.98)
        case .silver: return Color(red: 0.78, green: 0.80, blue: 0.84)
        }
    }
}

struct PlayerProfile: Codable, Equatable {
    var firstName = ""
    var lastName = ""
    var position = ""
    var gradYear = ""
    var age = ""
    var height = ""
    var clubTeam = ""
    var clubNumber = ""
    var highSchool = ""
    var schoolNumber = ""
    var hometown = ""
    var gpa = ""
    var email = ""
    var phone = ""
    var social = ""
    var stats: [StatLine] = []
    var style: CardStyle = .split
    var theme: CardTheme = .night
    var accent: CardAccent = .blue
    /// A team color picked with the color picker (sRGB hex like "#1E90FF"); overrides `accent`.
    var customAccent: String?
    var showEndCard = true
    /// Which part of the headshot the cards center on (fractions of the photo, top-left origin),
    /// and how far in they zoom (1 just fills the frame).
    var photoX = 0.5
    var photoY = 0.5
    var photoZoom = 1.0

    /// The card's accent: the custom color when one is set, else the preset.
    var accentColor: Color {
        if let hex = customAccent, let color = Color(hex: hex) { return color }
        return accent.color
    }

    init() {}

    var fullName: String {
        [firstName, lastName].filter { !$0.isEmpty }.joined(separator: " ")
    }

    var isEmpty: Bool { fullName.isEmpty }

    /// Detail tiles in display order, skipping blanks.
    var details: [(label: String, value: String)] {
        var out: [(String, String)] = []
        func add(_ label: String, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespaces)
            if !v.isEmpty { out.append((label, v)) }
        }
        add("Height", height)
        add("Age", age)
        add("Club", [clubTeam, clubNumber.isEmpty ? "" : "#\(clubNumber)"].filter { !$0.isEmpty }.joined(separator: " · "))
        add("High School", [highSchool, schoolNumber.isEmpty ? "" : "#\(schoolNumber)"].filter { !$0.isEmpty }.joined(separator: " · "))
        add("Hometown", hometown)
        add("GPA", gpa)
        for stat in stats { add(stat.label.isEmpty ? "Stat" : stat.label, stat.value) }
        return out.map { (label: $0.0, value: $0.1) }
    }

    /// The number to feature on the card: club number, else school number.
    var featuredNumber: String {
        let n = clubNumber.trimmingCharacters(in: .whitespaces)
        return n.isEmpty ? schoolNumber.trimmingCharacters(in: .whitespaces) : n
    }

    var contactLines: [(icon: String, text: String)] {
        var out: [(String, String)] = []
        if !email.isEmpty { out.append(("envelope.fill", email)) }
        if !phone.isEmpty { out.append(("phone.fill", phone)) }
        if !social.isEmpty { out.append(("at", social)) }
        return out.map { (icon: $0.0, text: $0.1) }
    }

    // Tolerant decoding: missing keys (from older versions) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func str(_ key: CodingKeys) -> String { (try? c.decodeIfPresent(String.self, forKey: key)) ?? "" }
        firstName = str(.firstName)
        lastName = str(.lastName)
        position = str(.position)
        gradYear = str(.gradYear)
        age = str(.age)
        height = str(.height)
        clubTeam = str(.clubTeam)
        clubNumber = str(.clubNumber)
        highSchool = str(.highSchool)
        schoolNumber = str(.schoolNumber)
        hometown = str(.hometown)
        gpa = str(.gpa)
        email = str(.email)
        phone = str(.phone)
        social = str(.social)
        stats = (try? c.decodeIfPresent([StatLine].self, forKey: .stats)) ?? []
        style = (try? c.decodeIfPresent(CardStyle.self, forKey: .style)) ?? .split
        theme = (try? c.decodeIfPresent(CardTheme.self, forKey: .theme)) ?? .night
        accent = (try? c.decodeIfPresent(CardAccent.self, forKey: .accent)) ?? .blue
        showEndCard = (try? c.decodeIfPresent(Bool.self, forKey: .showEndCard)) ?? true
        customAccent = try? c.decodeIfPresent(String.self, forKey: .customAccent)
        photoX = (try? c.decodeIfPresent(Double.self, forKey: .photoX)) ?? 0.5
        photoY = (try? c.decodeIfPresent(Double.self, forKey: .photoY)) ?? 0.5
        photoZoom = (try? c.decodeIfPresent(Double.self, forKey: .photoZoom)) ?? 1
    }
}

/// Loads and saves the player profile and headshot in ~/Movies/Cocut.
@MainActor
@Observable
final class ProfileStore {
    var profile: PlayerProfile {
        didSet { if profile != oldValue { scheduleSave() } }
    }
    private(set) var headshot: PlatformImage?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    private var profileURL: URL { directory.appending(path: "profile.json") }
    private var headshotURL: URL { directory.appending(path: "headshot.png") }

    /// Opens the Player Card of the project in `directory`.
    init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        if let data = try? Data(contentsOf: directory.appending(path: "profile.json")),
           let decoded = try? JSONDecoder().decode(PlayerProfile.self, from: data) {
            profile = decoded
        } else {
            profile = PlayerProfile()
        }
        headshot = Platform.loadImage(at: directory.appending(path: "headshot.png"))
    }

    func setHeadshot(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let image = Platform.loadImage(at: url) else {
            Log.error("Couldn't read headshot at \(url.lastPathComponent)")
            return
        }
        setHeadshot(image)
    }

    func setHeadshot(_ image: PlatformImage) {
        guard let png = Platform.normalizedPNG(image, maxSide: 1200) else { return }
        do {
            try png.write(to: headshotURL, options: .atomic)
            headshot = Platform.image(from: png)
            // A new photo starts centered.
            profile.photoX = 0.5
            profile.photoY = 0.5
            profile.photoZoom = 1
        } catch {
            Log.error("Couldn't save headshot: \(error.localizedDescription)")
        }
    }

    func removeHeadshot() {
        try? FileManager.default.removeItem(at: headshotURL)
        headshot = nil
    }

    func addStat() {
        profile.stats.append(StatLine(label: "", value: ""))
    }

    private func scheduleSave() {
        saveTask?.cancel()
        let snapshot = profile
        let url = profileURL
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

extension Color {
    /// Parses "#RRGGBB" (sRGB).
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(.sRGB,
                  red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }

    /// "#RRGGBB" in sRGB.
    var hexString: String {
        let c = Platform.sRGB(self) ?? (0, 0, 0, 1)
        let r = Int((c.red * 255).rounded())
        let g = Int((c.green * 255).rounded())
        let b = Int((c.blue * 255).rounded())
        return String(format: "#%02X%02X%02X", max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
    }
}
