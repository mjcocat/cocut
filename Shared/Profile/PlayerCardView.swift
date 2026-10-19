import SwiftUI

/// The intro and end cards, designed on a 1920×1080 canvas. The editor shows them scaled down;
/// the exporter renders them with ImageRenderer at the reel's resolution.
enum CardKind: Hashable {
    case intro, end
    /// A divider before a section of the reel, e.g. "Kills".
    case section(String)
}

/// Colors and type for a card theme, worked out from the team color so text stays readable
/// (a gold or silver team color on a light card gets a darker shade for text).
struct CardPalette {
    var text: Color
    var secondary: Color
    /// Labels, position line, small accents.
    var highlight: Color
    var tile: Color
    var tileStroke: Color
    var chipFill: Color
    var chipText: Color
    var photoStroke: Color
    var glow: Color
    var design: Font.Design
    var width: Font.Width

    init(theme: CardTheme, accent: Color) {
        let lum = Self.luminance(accent)
        let dark = Color(red: 0.07, green: 0.08, blue: 0.11)
        switch theme {
        case .night:
            text = .white
            secondary = .white.opacity(0.9)
            highlight = lum < 0.18 ? Self.mix(accent, .white, 0.4) : accent
            tile = .white.opacity(0.07)
            tileStroke = .white.opacity(0.1)
            chipFill = highlight
            chipText = lum > 0.5 ? .black : .white
            photoStroke = highlight
            glow = accent.opacity(0.55)
            design = .rounded
            width = .standard
        case .light:
            text = dark
            secondary = Color(white: 0.28)
            highlight = lum > 0.5 ? Self.mix(accent, .black, 0.45) : accent
            tile = .black.opacity(0.045)
            tileStroke = .black.opacity(0.08)
            chipFill = highlight
            chipText = .white
            photoStroke = highlight
            glow = .black.opacity(0.18)
            design = .rounded
            width = .standard
        case .team:
            let on: Color = lum > 0.6 ? dark : .white
            text = on
            secondary = on.opacity(0.88)
            highlight = on.opacity(0.72)
            tile = on.opacity(0.12)
            tileStroke = on.opacity(0.18)
            chipFill = on
            chipText = lum > 0.6 ? .white : Self.mix(accent, .black, 0.25)
            photoStroke = on
            glow = .black.opacity(0.3)
            design = .rounded
            width = .standard
        case .varsity:
            text = Color(red: 0.10, green: 0.10, blue: 0.14)
            secondary = Color(red: 0.22, green: 0.21, blue: 0.24)
            highlight = lum > 0.5 ? Self.mix(accent, .black, 0.45) : accent
            tile = .clear
            tileStroke = Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.35)
            chipFill = highlight
            chipText = Color(red: 0.96, green: 0.93, blue: 0.86)
            photoStroke = highlight
            glow = .black.opacity(0.12)
            design = .serif
            width = .condensed
        }
    }

    static func luminance(_ color: Color) -> Double {
        guard let c = Platform.sRGB(color) else { return 0.5 }
        return 0.2126 * c.red + 0.7152 * c.green + 0.0722 * c.blue
    }

    static func mix(_ a: Color, _ b: Color, _ t: Double) -> Color {
        guard let x = Platform.sRGB(a), let y = Platform.sRGB(b) else { return a }
        let f = min(1, max(0, t))
        func lerp(_ p: Double, _ q: Double) -> Double { p + (q - p) * f }
        return Color(.sRGB, red: lerp(x.red, y.red), green: lerp(x.green, y.green), blue: lerp(x.blue, y.blue),
                     opacity: lerp(x.alpha, y.alpha))
    }
}

struct PlayerCardView: View {
    let profile: PlayerProfile
    let headshot: PlatformImage?
    let kind: CardKind

    static let canvas = CGSize(width: 1920, height: 1080)

    private var accent: Color { profile.accentColor }
    private var palette: CardPalette { CardPalette(theme: profile.theme, accent: accent) }

    private func font(_ size: CGFloat, _ weight: Font.Weight) -> Font {
        .system(size: size, weight: weight, design: palette.design).width(palette.width)
    }

    var body: some View {
        ZStack {
            background
            switch kind {
            case .intro:
                switch profile.style {
                case .split: splitIntro
                case .centered: centeredIntro
                case .poster: posterIntro
                case .jersey: jerseyIntro
                case .minimal: minimalIntro
                }
            case .end:
                endCard
            case .section(let title):
                sectionCard(title)
            }
        }
        .frame(width: Self.canvas.width, height: Self.canvas.height)
        .clipped()
        .environment(\.colorScheme, profile.theme == .night || profile.theme == .team ? .dark : .light)
    }

    // MARK: Backgrounds

    @ViewBuilder
    private var background: some View {
        switch profile.theme {
        case .night:
            ZStack {
                LinearGradient(colors: [Color(red: 0.05, green: 0.09, blue: 0.16), Color(red: 0.01, green: 0.02, blue: 0.05)],
                               startPoint: .top, endPoint: .bottom)
                RadialGradient(colors: [accent.opacity(0.45), .clear], center: .init(x: 0.18, y: 0.1),
                               startRadius: 0, endRadius: 1100)
                RadialGradient(colors: [accent.opacity(0.18), .clear], center: .init(x: 0.95, y: 1.0),
                               startRadius: 0, endRadius: 900)
                diagonalLines(.white.opacity(0.025))
            }
        case .light:
            ZStack {
                Color(white: 0.965)
                diagonalLines(.black.opacity(0.03))
                // Drawn in a Canvas so the decoration never changes the card's layout: a soft glow
                // of team color in the top-right corner, a rail down the left edge, a band along the bottom.
                let highlight = palette.highlight
                Canvas { context, size in
                    context.fill(Path(ellipseIn: CGRect(x: size.width - 760, y: -560, width: 1200, height: 1200)),
                                 with: .color(highlight.opacity(0.09)))
                    context.fill(Path(CGRect(x: 0, y: 0, width: 24, height: size.height)), with: .color(highlight))
                    context.fill(Path(CGRect(x: 0, y: size.height - 16, width: size.width, height: 16)),
                                 with: .color(highlight.opacity(0.85)))
                }
            }
        case .team:
            ZStack {
                LinearGradient(colors: [accent, CardPalette.mix(accent, .black, 0.5)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [.white.opacity(0.18), .clear], center: .init(x: 0.15, y: 0.05),
                               startRadius: 0, endRadius: 1000)
                diagonalLines(.white.opacity(0.05))
            }
        case .varsity:
            ZStack {
                Color(red: 0.95, green: 0.92, blue: 0.85)
                VStack(spacing: 0) {
                    stripes
                    Spacer()
                    stripes.rotationEffect(.degrees(180))
                }
            }
        }
    }

    /// Varsity bands: a thick stripe and a thin one.
    private var stripes: some View {
        VStack(spacing: 10) {
            Rectangle().fill(palette.highlight).frame(height: 34)
            Rectangle().fill(palette.highlight).frame(height: 10)
        }
    }

    private func diagonalLines(_ color: Color) -> some View {
        Canvas { context, size in
            var path = Path()
            stride(from: -size.height, to: size.width, by: 120).forEach { x in
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
            }
            context.stroke(path, with: .color(color), lineWidth: 2)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private func photoContent(fontSize: CGFloat) -> some View {
        if let headshot {
            Image(platformImage: headshot)
                .resizable()
                .interpolation(.high)
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(colors: [accent.opacity(0.6), accent.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                Text(initials)
                    .font(.system(size: fontSize, weight: .heavy, design: palette.design))
                    .foregroundStyle(.white.opacity(0.9))
            }
        }
    }

    private func photo(width: CGFloat, height: CGFloat, circle: Bool) -> some View {
        let shape = circle
            ? AnyShape(Circle())
            : AnyShape(RoundedRectangle(cornerRadius: profile.theme == .varsity ? 12 : 44, style: .continuous))
        return photoContent(fontSize: min(width, height) * 0.36)
            .frame(width: width, height: height)
            .clipShape(shape)
            .overlay(shape.stroke(palette.photoStroke, lineWidth: 8))
            .shadow(color: palette.glow, radius: 40)
    }

    private var initials: String {
        let letters = [profile.firstName.first, profile.lastName.first].compactMap { $0 }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }

    private var classChip: some View {
        Group {
            if !profile.gradYear.isEmpty {
                Text("CLASS OF \(profile.gradYear)")
                    .font(font(34, .heavy))
                    .tracking(4)
                    .foregroundStyle(palette.chipText)
                    .padding(.horizontal, 26)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(palette.chipFill))
            }
        }
    }

    private var firstName: String { profile.firstName.isEmpty ? "First" : profile.firstName }
    private var lastName: String { (profile.lastName.isEmpty ? "Last" : profile.lastName).uppercased() }

    private func nameBlock(first: CGFloat = 96, last: CGFloat = 150, alignment: HorizontalAlignment = .leading) -> some View {
        VStack(alignment: alignment, spacing: -10) {
            Text(firstName)
                .font(font(first, profile.theme == .varsity ? .semibold : .light))
                .foregroundStyle(palette.secondary)
            Text(lastName)
                .font(font(last, .black))
                .foregroundStyle(palette.text)
                .minimumScaleFactor(0.5)
        }
        .lineLimit(1)
    }

    @ViewBuilder
    private var positionLine: some View {
        let parts = [profile.position, profile.featuredNumber.isEmpty ? "" : "#\(profile.featuredNumber)"]
            .filter { !$0.isEmpty }
        if !parts.isEmpty {
            Text(parts.joined(separator: "  ·  ").uppercased())
                .font(font(44, .bold))
                .tracking(3)
                .foregroundStyle(palette.highlight)
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
                .font(font(22, .bold))
                .tracking(2)
                .foregroundStyle(palette.highlight)
            Text(value)
                .font(font(40, .semibold))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: profile.theme == .varsity ? 6 : 22, style: .continuous)
                .fill(palette.tile)
                .overlay(RoundedRectangle(cornerRadius: profile.theme == .varsity ? 6 : 22, style: .continuous)
                    .strokeBorder(palette.tileStroke, lineWidth: profile.theme == .varsity ? 3 : 1.5))
        )
    }

    private var contactRow: some View {
        HStack(spacing: 44) {
            ForEach(Array(profile.contactLines.enumerated()), id: \.offset) { _, line in
                HStack(spacing: 14) {
                    Image(systemName: line.icon)
                        .foregroundStyle(palette.highlight)
                    Text(line.text)
                        .foregroundStyle(palette.secondary)
                }
                .font(font(34, .medium))
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
                nameBlock()
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
            nameBlock(first: 80, last: 132, alignment: .center)
            positionLine
            statRow(max: 5)
        }
        .padding(80)
    }

    /// One row of compact stats.
    private func statRow(max: Int) -> some View {
        HStack(spacing: 22) {
            ForEach(Array(profile.details.prefix(max).enumerated()), id: \.offset) { _, item in
                VStack(spacing: 6) {
                    Text(item.label.uppercased())
                        .font(font(20, .bold))
                        .tracking(2)
                        .foregroundStyle(palette.highlight)
                    Text(item.value)
                        .font(font(36, .semibold))
                        .foregroundStyle(palette.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: profile.theme == .varsity ? 6 : 20, style: .continuous)
                        .fill(palette.tile)
                        .overlay(RoundedRectangle(cornerRadius: profile.theme == .varsity ? 6 : 20, style: .continuous)
                            .strokeBorder(palette.tileStroke, lineWidth: profile.theme == .varsity ? 3 : 1)))
            }
        }
    }

    /// Full-height photo on the right with a slanted edge; jersey number huge behind the name.
    private var posterIntro: some View {
        ZStack(alignment: .leading) {
            if !profile.featuredNumber.isEmpty {
                Text(profile.featuredNumber)
                    .font(font(760, .black))
                    .foregroundStyle(palette.highlight.opacity(profile.theme == .team ? 0.18 : 0.13))
                    .lineLimit(1)
                    .offset(x: 70, y: 30)
            }
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                photoContent(fontSize: 300)
                    .frame(width: 880, height: 1080)
                    .clipShape(SlantedEdge(slant: 220))
                    .overlay(SlantedEdgeLine(slant: 220).stroke(palette.photoStroke, lineWidth: 14))
            }
            VStack(alignment: .leading, spacing: 26) {
                classChip
                nameBlock(first: 96, last: 160)
                positionLine
                detailGrid(columns: 2, maxItems: 6)
                    .padding(.top, 14)
                if !profile.contactLines.isEmpty {
                    contactRow.padding(.top, 10)
                }
            }
            .frame(width: 920, alignment: .leading)
            .padding(.leading, 120)
        }
    }

    /// The jersey number as a giant backdrop; name and a stat strip in front.
    private var jerseyIntro: some View {
        ZStack {
            Text(profile.featuredNumber.isEmpty ? initials : profile.featuredNumber)
                .font(font(980, .black))
                .foregroundStyle(palette.highlight.opacity(profile.theme == .team ? 0.2 : 0.16))
                .lineLimit(1)
                .minimumScaleFactor(0.3)
                .offset(y: -40)
            VStack(spacing: 26) {
                photo(width: 250, height: 250, circle: true)
                classChip
                nameBlock(first: 84, last: 170, alignment: .center)
                positionLine
                statRow(max: 6)
                    .padding(.top, 12)
            }
            .padding(70)
        }
    }

    /// A clean stat sheet: photo left, ruled list of details right.
    private var minimalIntro: some View {
        HStack(alignment: .top, spacing: 100) {
            VStack(alignment: .leading, spacing: 30) {
                photo(width: 520, height: 640, circle: false)
                classChip
            }
            VStack(alignment: .leading, spacing: 0) {
                nameBlock(first: 76, last: 128)
                positionLine
                    .padding(.top, 8)
                Rectangle()
                    .fill(palette.highlight)
                    .frame(width: 140, height: 8)
                    .padding(.vertical, 34)
                VStack(spacing: 0) {
                    ForEach(Array(profile.details.prefix(7).enumerated()), id: \.offset) { _, item in
                        HStack {
                            Text(item.label.uppercased())
                                .font(font(26, .bold))
                                .tracking(3)
                                .foregroundStyle(palette.highlight)
                            Spacer(minLength: 30)
                            Text(item.value)
                                .font(font(38, .semibold))
                                .foregroundStyle(palette.text)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                        }
                        .padding(.vertical, 16)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(palette.tileStroke).frame(height: 2)
                        }
                    }
                }
                if !profile.contactLines.isEmpty {
                    contactRow.padding(.top, 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 130)
        .padding(.vertical, 120)
    }

    private func sectionCard(_ title: String) -> some View {
        VStack(spacing: 34) {
            let byline = [profile.fullName, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)"]
                .filter { !$0.isEmpty }
            if !byline.isEmpty {
                Text(byline.joined(separator: "  ·  ").uppercased())
                    .font(font(34, .bold))
                    .tracking(6)
                    .foregroundStyle(palette.secondary.opacity(0.7))
            }
            Text(title.uppercased())
                .font(font(210, .black))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.35)
                .shadow(color: palette.glow, radius: 40)
            Capsule()
                .fill(palette.highlight)
                .frame(width: 260, height: 14)
        }
        .padding(.horizontal, 140)
    }

    private var endCard: some View {
        VStack(spacing: 36) {
            photo(width: 300, height: 300, circle: true)
            Text(profile.fullName.isEmpty ? "Thanks for watching" : profile.fullName)
                .font(font(110, .black))
                .foregroundStyle(palette.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            let sub = [profile.position, profile.gradYear.isEmpty ? "" : "Class of \(profile.gradYear)",
                       profile.clubTeam].filter { !$0.isEmpty }
            if !sub.isEmpty {
                Text(sub.joined(separator: "  ·  "))
                    .font(font(44, .semibold))
                    .foregroundStyle(palette.highlight)
            }
            if !profile.contactLines.isEmpty {
                VStack(spacing: 18) {
                    ForEach(Array(profile.contactLines.enumerated()), id: \.offset) { _, line in
                        HStack(spacing: 16) {
                            Image(systemName: line.icon).foregroundStyle(palette.highlight)
                            Text(line.text).foregroundStyle(palette.text)
                        }
                        .font(font(44, .medium))
                    }
                }
                .padding(.horizontal, 60)
                .padding(.vertical, 34)
                .background(
                    RoundedRectangle(cornerRadius: profile.theme == .varsity ? 8 : 30, style: .continuous)
                        .fill(palette.tile)
                        .overlay(RoundedRectangle(cornerRadius: profile.theme == .varsity ? 8 : 30, style: .continuous)
                            .strokeBorder(palette.tileStroke, lineWidth: profile.theme == .varsity ? 3 : 1)))
            }
            Text("Thanks for watching")
                .font(font(30, .medium))
                .foregroundStyle(palette.secondary.opacity(0.6))
                .opacity(profile.fullName.isEmpty ? 0 : 1)
        }
        .padding(100)
    }
}

/// A rectangle whose left edge leans in at the top (for the Poster layout's photo).
private struct SlantedEdge: Shape {
    let slant: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// Just the slanted edge, drawn as an accent line.
private struct SlantedEdgeLine: Shape {
    let slant: CGFloat
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX + slant, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        return p
    }
}

extension PlayerCardView {
    /// Renders the card to a bitmap of the given pixel size (16:9).
    @MainActor
    static func render(profile: PlayerProfile, headshot: PlatformImage?, kind: CardKind, pixelSize: CGSize) -> CGImage? {
        let renderer = ImageRenderer(content: PlayerCardView(profile: profile, headshot: headshot, kind: kind))
        renderer.proposedSize = ProposedViewSize(canvas)
        renderer.scale = pixelSize.width / canvas.width
        renderer.isOpaque = true
        return renderer.cgImage
    }
}
