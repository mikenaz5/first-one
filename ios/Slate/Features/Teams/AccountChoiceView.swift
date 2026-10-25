import SwiftUI

/// The first thing a new person sees after signing in: are they one person, a company, or here to book?
/// "Just me" goes on to the usual profile setup, "My company" to starting a company, and "I'm booking a creator" straight
/// into the app as a client (asking for a name first if there isn't one).
struct AccountChoiceFlow: View {
    private enum Step { case choose, individual, company, client }

    @Environment(AppModel.self) private var model

    @State private var step = Step.choose
    @State private var isStartingClient = false

    var body: some View {
        ZStack {
            switch step {
            case .choose:
                AccountChoiceView(
                    onIndividual: { step = .individual },
                    onCompany: { step = .company },
                    onClient: { startClient() }
                )
                .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)).combined(with: .opacity))
            case .individual:
                OnboardingFlow(onBack: { step = .choose })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .company:
                CompanySetupView(mode: .new, onBack: { step = .choose })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            case .client:
                ClientNameStep(onBack: { step = .choose })
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .motionSafe(.slateSmooth, value: step)
        .onAppear {
            // Someone who arrived from a booking link is here to book: no type to choose.
            if model.pendingBookingHandle != nil { startClient() }
        }
    }

    /// Straight in if we already know the name; otherwise ask for it once.
    private func startClient() {
        guard !isStartingClient else { return }
        if (model.session?.fullName ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            step = .client
            return
        }
        isStartingClient = true
        Task {
            do {
                try await model.becomeClient(name: nil)
            } catch {
                model.show(error, title: "Couldn't continue")
            }
            isStartingClient = false
        }
    }
}

/// Asks a new client for the name that goes on their contracts, then opens the app.
private struct ClientNameStep: View {
    @Environment(AppModel.self) private var model
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Label("Back", systemImage: "chevron.left")
                        .frame(minHeight: Metrics.minTapTarget)
                }
                Spacer()
            }
            .padding(.horizontal, Space.page)

            ClientNameForm(
                heading: "What should we call you?",
                detail: "This is the name on the contracts you sign when you book. You can change it later in Profile.",
                buttonTitle: "Continue"
            ) { name in
                try await model.becomeClient(name: name)
            }
        }
        .slateGlowBackground()
    }
}

struct AccountChoiceView: View {
    @Environment(AppModel.self) private var model

    let onIndividual: () -> Void
    let onCompany: () -> Void
    let onClient: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text("How will you use Slate Pro?")
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
                    ChoiceCard(
                        symbol: "calendar.badge.checkmark",
                        title: "I'm booking a creator",
                        subtitle: "Client · always free",
                        points: [
                            "Find a creator, book, sign and pay in a few taps",
                            "Your contracts, payments, messages and files in one place",
                            "Every contract in your name, nothing to set up",
                        ],
                        action: onClient
                    )
                }

                Text("Not sure? Choose Just me if you sell your work, or I'm booking a creator if you hire people. A company is for teams that sell together.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.xxl)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: Metrics.readableWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .slateGlowBackground()
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
                        .foregroundStyle(Color.slateAccentText)
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
    AccountChoiceView(onIndividual: {}, onCompany: {}, onClient: {})
        .environment(AppModel(backend: LocalBackend(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-choice"))))
}
