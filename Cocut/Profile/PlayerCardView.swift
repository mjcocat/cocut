import AppKit
import SwiftUI

/// The intro and end cards, designed on a 1920×1080 canvas. The editor shows them scaled down;
/// the exporter renders them with ImageRenderer at the reel's resolution.
enum CardKind: Hashable {
    case intro, end
    /// A divider before a section of the reel, e.g. "Kills".
    case section(String)
}

struct PlayerCardView: View {
    let profile: PlayerProfile
    let headshot: NSImage?
    let kind: CardKind

    static let canvas = CGSize(width: 1920, height: 1080)

    private var accent: Color { profile.accentColor }

    var body: some View {
        ZStack {
            background
            switch kind {
            case .intro:
                switch profile.style {
                case .split: splitIntro
                case .centered: centeredIntro
                }
            case .end:
                endCard
            case .section(let title):
                sectionCard(title)
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .clipped()
        .environment(\.colorScheme, .dark)
    }

    // MARK: Background

    private var background: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.16), Color(red: 0.01, green: 0.02, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [accent.opacity(0.45), .clear], center: .init(x: 0.18, y: 0.1),
                           startRadius: 0, endRadius: 1100)
            RadialGradient(colors: [accent.opacity(0.18), .clear], center: .init(x: 0.95, y: 1.0),
                           startRadius: 0, endRadius: 900)
            // Subtle diagonal court lines.
            Canvas { context, size in
                var path = Path()
                stride(from: -size.height, to: size.width, by: 120).forEach { x in
                    path.move(to: CGPoint(x: x, y: size.height))
                    path.addLine(to: CGPoint(x: x + size.height, y: 0))
                }
                context.stroke(path, with: .color(.white.opacity(0.025)), lineWidth: 2)
            }
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func photo(width: CGFloat, height: CGFloat, circle: Bool) -> some View {
        let shape = circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: 44, style: .continuous))
        ZStack {
            if let headshot {
                Image(nsImage: headshot)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                LinearGradient(colors: [accent.opacity(0.55), accent.opacity(0.2)], startPoint: .top, endPoint: .bottom)
                Text(initials)
                    .font(.system(size: min(width, height) * 0.36, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
        .frame(width: width, height: height)
        .clipShape(shape)
        .overlay(shape.stroke(accent, lineWidth: 8))
        .shadow(color: accent.opacity(0.55), radius: 40)
    }

    private var initials: String {
        let letters = [profile.firstName.first, profile.lastName.first].compactMap { $0 }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var classChip: some View {
        Group {
            if !profile.gradYear.isEmpty {
                Text("CLASS OF \(profile.gradYear)")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .tracking(4)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent))
            }
        }
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: -10) {
            Text(profile.firstName.isEmpty ? "First" : profile.firstName)
                .font(.system(size: 96, weight: .light, design: .rounded))
                .foregroundStyle(.white.opacity(0.92))
            Text((profile.lastName.isEmpty ? "Last" : profile.lastName).uppercased())
                .font(.system(size: 150, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.5)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var positionLine: some View {
        let parts = [profile.position, profile.clubNumber.isEmpty ? "" : "#\(profile.clubNumber)"]
            .filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  ").uppercased())
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .tracking(3)
                .foregroundStyle(accent)
        }
    }

    /// A non-lazy grid: ImageRenderer can't draw lazy containers.
    private func detailGrid(columns: Int, maxItems: Int) -> some View {
        let items = Array(profile.details.prefix(maxItems))
        let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
        return Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 22) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, item in
                        detailTile(label: item.label, value: item.value)
                    }
                    if row.count < columns {
                        ForEach(0..<(columns - row.count), id: \.self) { _ in
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                        }
                    }
                }
            }
        }
    }

    private func detailTile(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .tracking(2)
                .foregroundStyle(accent.opacity(0.9))
            Text(value)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.07))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1.5))
        )
    }

    private var contactRow: some View {
        HStack(spacing: 44) {
            ForEach(Array(profile.contactLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 14) {
                    Image(systemName: line.icon)
                        .foregroundStyle(accent)
                    Text(line.text)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .font(.system(size: 34, weight: .medium, design: .rounded))
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.5)
    }

    // MARK: Layouts

    private var splitIntro: some View {
        HStack(alignment: .center, spacing: 90) {
            photo(width: 600, height: 760, circle: false)
            VStack(alignment: .leading, spacing: 26) {
                classChip
                nameBlock
                positionLine
                detailGrid(columns: 2, maxItems: 8)
                    .padding(.top, 10)
                if !profile.contactLines.isEmpty {
                    contactRow.padding(.top, 14)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 130)
        .padding(.vertical, 110)
    }

    private var centeredIntro: some View {
        VStack(spacing: 30) {
            photo(width: 360, height: 360, circle: true)
            classChip
            VStack(spacing: -6) {
                Text(profile.firstName.isEmpty ? "First" : profile.firstName)
                    .font(.system(size: 80, weight: .light, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                Text((profile.lastName.isEmpty ? "Last" : profile.lastName).uppercased())
                    .font(.system(size: 132, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            positionLine
            HStack(spacing: 22) {
                ForEach(Array(profile.details.prefix(5).enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        Text(item.label.uppercased())
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .tracking(2)
                            .foregroundStyle(accent)
                        Text(item.value)
                            .font(.system(size: 36, weight: .semibold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                    }
                    .padding(.horizontal, 28)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white.opacity(0.07)))
                }
            }
        }
        .padding(80)
    }

    private func sectionCard(_ title: String) -> some View {
        VStack(spacing: 34) {
            let byline = [profile.fullName, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)"]
                .filter { !$0.isEmpty }
            if !byline.isEmpty {
                Text(byline.joined(separator: "  ·  ").uppercased())
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .tracking(6)
                    .foregroundStyle(.white.opacity(0.6))
            }
            Text(title.uppercased())
                .font(.system(size: 210, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .shadow(color: accent.opacity(0.5), radius: 40)
            Capsule()
                .fill(accent)
                .frame(width: 260, height: 14)
        }
        .padding(.horizontal, 140)
    }

    private var endCard: some View {
        VStack(spacing: 36) {
            photo(width: 300, height: 300, circle: true)
            Text(profile.fullName.isEmpty ? "Thanks for watching" : profile.fullName)
                .font(.system(size: 110, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            let sub = [profile.position, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)",
                       profile.clubTeam].filter { !$0.isEmpty }
            if !sub.isEmpty {
                Text(sub.joined(separator: "  ·  "))
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .foregroundStyle(accent)
            }
            if !profile.contactLines.isEmpty {
                VStack(spacing: 18) {
                    ForEach(Array(profile.contactLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 16) {
                            Image(systemName: line.icon).foregroundStyle(accent)
                            Text(line.text).foregroundStyle(.white)
                        }
                        .font(.system(size: 44, weight: .medium, design: .rounded))
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 34)
                .background(RoundedRectangle(cornerRadius: 30, style: .continuous).fill(Color.white.opacity(0.07)))
            }
            Text("Thanks for watching")
                .font(.system(size: 30, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .opacity(profile.fullName.isEmpty ? 0 : 1)
        }
        .padding(100)
    }
}

extension PlayerCardView {
    /// Renders the card to a bitmap of the given pixel size (16:9).
    @MainActor
    static func render(profile: PlayerProfile, headshot: NSImage?, kind: CardKind, pixelSize: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: PlayerCardView(profile: profile, headshot: headshot, kind: kind))
        renderer.proposedSize = ProposedViewSize(canvas)
        renderer.scale = pixelSize.width / canvas.width
        renderer.isOpaque = true
        return renderer.cgImage
    }
}
