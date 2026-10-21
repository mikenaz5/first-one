import PhotosUI
import SwiftUI

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case identity, specialties, about, location, portfolio

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .identity: "Set up your page"
        case .specialties: "What do you shoot?"
        case .about: "Tell clients about you"
        case .location: "Where do you work?"
        case .portfolio: "Show your best work"
        }
    }

    var subtitle: String {
        switch self {
        case .identity: "Add a photo and choose the link clients will use to book you."
        case .specialties: "Pick up to \(AppConfig.maxSpecialties). You can change these any time."
        case .about: "A few sentences about your style and how you work."
        case .location: "Clients see your city and how far you'll travel."
        case .portfolio: "Photos and reels. Three or more makes a strong first impression."
        }
    }

    /// Steps people can skip and finish later from their profile.
    var isOptional: Bool {
        switch self {
        case .identity, .specialties: false
        case .about, .location, .portfolio: true
        }
    }

    var isLast: Bool { self == OnboardingStep.allCases.last }
}

struct OnboardingFlow: View {
    @Environment(AppModel.self) private var model

    @State private var draft = ProfileDraft()
    @State private var pendingPortfolio: [NewPortfolioItem] = []
    @State private var position: OnboardingStep? = .identity
    @State private var isSaving = false
    @State private var finished = false

    private var step: OnboardingStep { position ?? .identity }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(OnboardingStep.allCases) { page in
                        OnboardingPage(step: page, draft: draft, pendingPortfolio: $pendingPortfolio)
                            .containerRelativeFrame(.horizontal)
                            .id(page)
                            .scrollTransition(axis: .horizontal) { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.25)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.96)
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $position)
            .scrollTargetBehavior(.paging)
            .scrollDisabled(true) // Moving between steps is explicit, via the buttons.
            .scrollIndicators(.hidden)
        }
        .slatePageBackground()
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .sensoryFeedback(.impact(weight: .light), trigger: step)
        .sensoryFeedback(.success, trigger: finished)
        .onAppear(perform: prefill)
    }

    // MARK: Header

    private var header: some View {
        VStack(spacing: Space.s) {
            HStack {
                Button {
                    go(to: previousStep)
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.semibold))
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Back")
                .opacity(step == .identity ? 0 : 1)
                .disabled(step == .identity || isSaving)

                Spacer()

                if step.isOptional && !step.isLast {
                    Button("Skip") { advance() }
                        .frame(minWidth: Metrics.minTapTarget, minHeight: Metrics.minTapTarget)
                }
            }

            ProgressSegments(current: step.rawValue, count: OnboardingStep.allCases.count)
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.xs)
    }

    // MARK: Action bar

    private var actionBar: some View {
        VStack(spacing: Space.s) {
            Button(action: primaryAction) {
                Group {
                    if isSaving {
                        ProgressView().tint(.white)
                    } else {
                        Text(step.isLast ? "Create my page" : "Continue")
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 28)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canContinue || isSaving)
            .accessibilityHint(canContinue ? "" : "Complete the required fields to continue")
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.m)
        .padding(.bottom, Space.s)
        .background(.bar)
    }

    private var canContinue: Bool {
        switch step {
        case .identity: draft.identityIsValid
        case .specialties: draft.specialtiesAreValid
        case .about, .location, .portfolio: true
        }
    }

    // MARK: Navigation

    private var previousStep: OnboardingStep {
        OnboardingStep(rawValue: step.rawValue - 1) ?? .identity
    }

    private func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        go(to: next)
    }

    private func go(to target: OnboardingStep) {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        withAnimation(.slateSmooth) { position = target }
    }

    private func primaryAction() {
        if step.isLast {
            Task { await finish() }
        } else {
            advance()
        }
    }

    private func finish() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.completeOnboarding(draft: draft, portfolio: pendingPortfolio)
            finished = true
        } catch SlateError.handleTaken {
            draft.handleStatus = .taken
            go(to: .identity)
            model.show(SlateError.handleTaken, title: "Choose another link name")
        } catch {
            model.show(error, title: "Couldn't create your page")
        }
    }

    private func prefill() {
        guard draft.displayName.isEmpty, let name = model.session?.fullName else { return }
        draft.displayName = name
        draft.updateSuggestedHandle()
    }
}

// MARK: - Progress

private struct ProgressSegments: View {
    let current: Int
    let count: Int

    var body: some View {
        HStack(spacing: Space.xs) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .fill(index <= current ? Color.accentColor : Color.slateFill)
                    .frame(height: 4)
            }
        }
        .motionSafe(.slateSmooth, value: current)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(current + 1) of \(count)")
    }
}

// MARK: - Page

private struct OnboardingPage: View {
    let step: OnboardingStep
    @Bindable var draft: ProfileDraft
    @Binding var pendingPortfolio: [NewPortfolioItem]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.xl) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Text(step.title)
                        .font(SlateFont.display)
                        .accessibilityAddTraits(.isHeader)
                    Text(step.subtitle)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                content
            }
            .padding(.horizontal, Space.page)
            .padding(.top, Space.l)
            .padding(.bottom, Space.xxl)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .identity:
            IdentityStep(draft: draft)
        case .specialties:
            VStack(alignment: .leading, spacing: Space.m) {
                SpecialtyPicker(draft: draft)
                Text("\(draft.specialties.count) of \(AppConfig.maxSpecialties) selected")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .about:
            BioField(draft: draft).card()
        case .location:
            LocationField(draft: draft).card()
        case .portfolio:
            PortfolioStep(items: $pendingPortfolio)
        }
    }
}

private struct IdentityStep: View {
    @Bindable var draft: ProfileDraft

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xl) {
            AvatarPicker(draft: draft)
                .frame(maxWidth: .infinity)

            VStack(alignment: .leading, spacing: Space.s) {
                Text("Your name or studio").eyebrow()
                TextField("Maya Chen Photography", text: $draft.displayName)
                    .textContentType(.name)
                    .submitLabel(.next)
                    .frame(minHeight: Metrics.minTapTarget)
                    .padding(.horizontal, Space.l)
                    .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                    .onChange(of: draft.displayName) { _, _ in draft.updateSuggestedHandle() }
            }

            VStack(alignment: .leading, spacing: Space.s) {
                Text("Your booking link").eyebrow()
                HandleField(draft: draft)
                    .padding(.horizontal, Space.l)
                    .background(Color.slateCard, in: RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
                HandleStatusText(draft: draft)
            }
        }
    }
}

// MARK: - Portfolio step

private struct PortfolioStep: View {
    @Binding var items: [NewPortfolioItem]

    @State private var picks: [PhotosPickerItem] = []
    @State private var importer = PortfolioImporter()

    private var remaining: Int { max(0, AppConfig.portfolioLimit - items.count) }
    private let columns = Array(repeating: GridItem(.flexible(), spacing: Metrics.gridSpacing), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            if !items.isEmpty {
                LazyVGrid(columns: columns, spacing: Metrics.gridSpacing) {
                    ForEach(items) { item in
                        PendingTile(item: item) {
                            withAnimation(.slateSnappy) { items.removeAll { $0.id == item.id } }
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.m, style: .continuous))
            }

            if remaining > 0 {
                PhotosPicker(
                    selection: $picks,
                    maxSelectionCount: remaining,
                    matching: .any(of: [.images, .videos])
                ) {
                    AddWorkTile(isEmpty: items.isEmpty)
                }
                .buttonStyle(PressableTileStyle())
                .disabled(importer.isImporting)
            }

            if importer.isImporting {
                HStack(spacing: Space.s) {
                    ProgressView()
                    Text("Adding \(min(importer.completed + 1, importer.total)) of \(importer.total)…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }

            ForEach(importer.skipped, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Color.slateWarning)
            }

            Text("\(items.count) of \(AppConfig.portfolioLimit) added. Reels can be up to \(AppConfig.maxVideoSeconds / 60) minutes.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .sensoryFeedback(trigger: items.count) { old, new in new > old ? .success : nil }
        .onChange(of: picks) { _, newPicks in
            guard !newPicks.isEmpty else { return }
            Task {
                let added = await importer.load(newPicks)
                picks = []
                withAnimation(.slateSpring) { items.append(contentsOf: added) }
            }
        }
    }
}

private struct AddWorkTile: View {
    let isEmpty: Bool

    var body: some View {
        VStack(spacing: Space.s) {
            Image(systemName: "photo.badge.plus")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(isEmpty ? "Add photos and reels" : "Add more")
                .font(.headline)
            if isEmpty {
                Text("Choose from your library")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: isEmpty ? 160 : Metrics.minTapTarget + Space.l)
        .background(
            RoundedRectangle(cornerRadius: Radius.l, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.5), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
        )
        .contentShape(RoundedRectangle(cornerRadius: Radius.l, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

private struct PendingTile: View {
    let item: NewPortfolioItem
    let onRemove: () -> Void

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = UIImage(data: item.thumbnailJPEG) {
                    Image(uiImage: image).resizable().scaledToFill()
                }
            }
            .overlay(alignment: .bottomLeading) {
                if item.kind == .video {
                    Image(systemName: "play.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(Space.xs)
                        .shadow(radius: 2)
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.55))
                        .font(.title3)
                        .frame(width: Metrics.minTapTarget, height: Metrics.minTapTarget)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Remove \(item.kind == .video ? "reel" : "photo")")
            }
            .clipped()
            .transition(.scale.combined(with: .opacity))
    }
}

#Preview("Onboarding") {
    OnboardingFlow()
        .environment(AppModel(backend: LocalBackend(root: FileManager.default.temporaryDirectory.appendingPathComponent("preview-onboarding"))))
}
