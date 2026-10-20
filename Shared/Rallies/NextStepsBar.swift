import SwiftUI

/// A slim bar above the rallies after a match is analyzed: the one next thing worth doing, with
/// a button for it and a way to pass it over. It moves on by itself as steps get done, and can
/// be hidden for the match.
struct NextStepsBar: View {
    let finder: RallyFinder
    var onRoster: () -> Void
    var onIdentify: () -> Void

    var body: some View {
        if let step = finder.nextStep {
            // One line when there's room; the buttons below the text when there isn't (iPhone).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 12) {
                    label(step)
                    Spacer(minLength: 8)
                    actions(step)
                    trailing(step)
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        label(step)
                        Spacer(minLength: 4)
                        trailing(step)
                    }
                    HStack(spacing: 8) { actions(step) }
                        .padding(.leading, 38)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            .motion(.default, value: step)
        }
    }

    private func label(_ step: RallyFinder.GuideStep) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon(step))
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text("Next: \(title(step))")
                    .font(.callout.weight(.semibold))
                Text(detail(step))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 560, alignment: .leading)
        }
    }

    private func trailing(_ step: RallyFinder.GuideStep) -> some View {
        HStack(spacing: 10) {
            Text("\(step.rawValue + 1) of \(RallyFinder.GuideStep.allCases.count)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
            Button {
                finder.hideGuide()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help("Hide these tips for this match")
        }
    }

    private func icon(_ step: RallyFinder.GuideStep) -> String {
        switch step {
        case .roster: return "person.3"
        case .warmUp: return "figure.cooldown"
        case .identify: return "person.badge.plus"
        case .use: return "film.stack"
        }
    }

    private func title(_ step: RallyFinder.GuideStep) -> String {
        switch step {
        case .roster: return "Add your team roster"
        case .warmUp: return "Leave out the warm-up"
        case .identify: return "Identify players"
        case .use: return "Use the rallies"
        }
    }

    private func detail(_ step: RallyFinder.GuideStep) -> String {
        switch step {
        case .roster:
            return "Your team's numbers keep opponents and referees off the rallies, and let Cocut list at most six of your players per rally. Mark your libero too, so Cocut can find her by her jersey."
        case .warmUp:
            #if os(macOS)
            return "If the first rallies are the warm-up or lineup, right-click the first real rally › Leave Out Earlier Rallies."
            #else
            return "If the first rallies are the warm-up or lineup, swipe right on the first real rally › Leave Out Earlier."
            #endif
        case .identify:
            let n = finder.suggestedQuestions
            let questions = n > 0 ? "About \(n) answers" : "A few answers"
            return "\(questions) in Who's This? let Cocut list players on the rallies, so you can find every rally a player is in."
        case .use:
            return "Pick a player in the filter to keep just their rallies, then Add to Clips for a highlight reel, or Export Condensed Match."
        }
    }

    @ViewBuilder private func actions(_ step: RallyFinder.GuideStep) -> some View {
        switch step {
        case .roster:
            Button("Team Roster…", action: onRoster).buttonStyle(.borderedProminent)
            Button("Skip") { finder.pass(.roster) }
        case .warmUp:
            if let first = finder.rallies.min(by: { $0.start < $1.start }) {
                Button("Play First Rally") { finder.play(first) }
            }
            Button("Looks Fine") { finder.pass(.warmUp) }
        case .identify:
            Button("Identify Players…", action: onIdentify)
                .buttonStyle(.borderedProminent)
                .disabled(!finder.canTeach)
            Button("Later") { finder.pass(.identify) }
        case .use:
            Button("Got It") { finder.pass(.use) }
        }
    }
}
