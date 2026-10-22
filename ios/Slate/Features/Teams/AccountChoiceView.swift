import SwiftUI

/// The first thing a new person sees after Sign in with Apple: are they one person, or a company?
/// Choosing "Just me" goes on to the usual profile setup; "My company" goes on to starting a company.
struct AccountChoiceFlow: View {
    private enum Step { case choose, individual, company }

    @State private var step = Step.choose

    var body: some View {
        ZStack {
            switch step {
            case .choose:
                AccountChoiceView(
                    onIndividual: { step = .individual },
                    onCompany: { step = .company }
                )
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            case .individual:
                OnboardingFlow(onBack: { step = .choose })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .company:
                CompanySetupView(mode: .new, onBack: { step = .choose })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .motionSafe(.slateSmooth, value: step)
    }
}

struct AccountChoiceView: View {
    @Environment(AppModel.self) private var model

    let onIndividual: () -> Void
    let onCompany: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("How will you use Slate?")
                        .font(SlateFont.display)
                        .accessibilityAddTraits(.isHeader)
                    Text("You can start on your own and move to a company account later. Your profile, services, bookings and contracts come with you.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: Space.m) {
                    ChoiceCard(
                        symbol: "person.crop.circle",
                        title: "Just me",
                        subtitle: "Individual freelancer",
                        points: [
                            "One profile, one calendar",
                            "Your own services, contracts and payouts",
                            "Free to start",
                        ],
                        action: onIndividual
                    )
                    ChoiceCard(
                        symbol: "building.2",
                        title: "My company",
                        subtitle: "A team of \(model.teamConfig.seatMinimum) or more",
                        points: [
                            "A company page, with a profile for each person",
                            "Roles, shared services and one team calendar",
                            "Contracts and payments in the company's name",
                        ],
                        action: onCompany
                    )
                }

                Text("Not sure? Choose Just me. You can upgrade from your profile whenever your team grows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .slatePageBackground()
    }
}

/// One of the two big cards. A whole card is the button, and reads as one thing to VoiceOver.
private struct ChoiceCard: View {
    let symbol: String
    let title: String
    let subtitle: String
    let points: [String]
    let action: () -> Void

    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(spacing: Space.m) {
                    Image(systemName: symbol)
                        .font(.title)
                        .foregroundStyle(Color.accentColor)
                        .frame(minWidth: Metrics.iconColumn)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: Space.xxs) {
                        Text(title).font(.title3.weight(.semibold))
                        Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: Space.s)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: Space.s) {
                    ForEach(points, id: \.self) { point in
                        Label {
                            Text(point).font(.subheadline)
                        } icon: {
                            Image(systemName: "checkmark")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
            .card(padding: Space.xl)
            .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
        .sensoryFeedback(.selection, trigger: taps)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Continues setting up this kind of account")
    }
}

#Preview("Account type") {
    AccountChoiceView(onIndividual: {}, onCompany: {})
        .environment(AppModel(backend: LocalBackend(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-choice"))))
}
