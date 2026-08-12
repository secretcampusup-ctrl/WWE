import SwiftUI

/// Shows the diagnostic log written by `DiagnosticLogger`, with buttons to
/// copy it or open the system share sheet (send to Notes, Messages, etc.).
struct DiagnosticLogView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = DiagnosticLogger.readAll()
    @State private var showShareSheet = false
    @State private var showCopiedConfirmation = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Diagnostics Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button {
                            text = DiagnosticLogger.readAll()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        Button {
                            UIPasteboard.general.string = text
                            showCopiedConfirmation = true
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                        Button(role: .destructive) {
                            DiagnosticLogger.clear()
                            text = DiagnosticLogger.readAll()
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [text])
        }
        .alert("Copied", isPresented: $showCopiedConfirmation) {
            Button("OK", role: .cancel) {}
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
