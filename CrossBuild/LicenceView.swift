import SwiftUI

/// The third-party notices, straight from the file bundled with the app.
///
/// Several of the components this app links and redistributes require their
/// notices to travel with the binary: the Linux engine is GPLv3, CPython is PSF,
/// the guest userland is a mix of GPL/LGPL/MIT. A file in the repository is not a
/// file in the app.
struct LicenceView: View {
    private var text: String {
        guard let url = Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return "The notices file is missing from this build. It is kept at THIRD-PARTY-NOTICES.md in the repository."
        }
        return contents
    }

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }
}
