import SwiftUI

/// The licenses of the open-source code Slate Pro is built with. Those licenses ask for their text to travel with the app, so
/// the app carries it (`Slate/Resources/ThirdPartyNotices.txt`, written by `scripts/update_notices.py`) and shows it here.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    private let text: String

    init(bundle: Bundle = .main) {
        if let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
           let contents = try? String(contentsOf: url, encoding: .utf8) {
            text = contents
        } else {
            text = "The license notices couldn't be read."
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.page)
            }
            .slatePageBackground()
            .navigationTitle("Open-source licenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
