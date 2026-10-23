import SwiftUI

struct EditProfileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var draft: ProfileDraft
    @State private var isSaving = false
    @State private var saved = false

    private let original: CreatorProfile

    init(profile: CreatorProfile) {
        original = profile
        _draft = State(initialValue: ProfileDraft(profile: profile))
    }

    private var hasChanges: Bool {
        draft.avatarJPEG != nil
            || draft.trimmedName != original.displayName
            || draft.handle != original.handle
            || draft.bio.trimmingCharacters(in: .whitespacesAndNewlines) != original.bio
            || draft.specialties != original.specialties
            || draft.location != original.location
    }

    private var canSave: Bool {
        draft.canPublish && hasChanges && !isSaving
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AvatarPicker(draft: draft, size: Metrics.avatarL)
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                }
                    .listRowBackground(Color.slateCard)

                Section(original.kind == .company ? "Company name" : "Name") {
                    TextField(original.kind == .company ? "Company name" : "Your name or studio", text: $draft.displayName)
                        .textContentType(original.kind == .company ? .organizationName : .name)
                        .frame(minHeight: Metrics.minTapTarget)
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    HandleField(draft: draft)
                } header: {
                    Text("Booking link")
                } footer: {
                    HandleStatusText(draft: draft)
                }
                    .listRowBackground(Color.slateCard)

                Section {
                    SpecialtyPicker(draft: draft)
                        .padding(.vertical, Space.xs)
                } header: {
                    Text("Specialties")
                } footer: {
                    Text("\(draft.specialties.count) of \(AppConfig.maxSpecialties) selected")
                }
                    .listRowBackground(Color.slateCard)

                Section("About") {
                    BioField(draft: draft)
                }
                    .listRowBackground(Color.slateCard)

                Section("Location") {
                    LocationField(draft: draft)
                }
                    .listRowBackground(Color.slateCard)
            }
            .scrollContentBackground(.hidden)
            .slatePageBackground()
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!canSave)
                    }
                }
            }
            .interactiveDismissDisabled(hasChanges || isSaving)
            .sensoryFeedback(.success, trigger: saved)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await model.updateProfile(from: draft)
            saved = true
            dismiss()
        } catch SlateError.handleTaken {
            draft.handleStatus = .taken
            model.show(SlateError.handleTaken, title: "Choose another link name")
        } catch {
            model.show(error, title: "Couldn't save your profile")
        }
    }
}
