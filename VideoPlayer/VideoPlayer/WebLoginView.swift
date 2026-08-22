import SwiftUI
import WebKit

struct WebLoginView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL
    let onLoginDetected: (() -> Void)?

    var body: some View {
        NavigationStack {
            WebLoginContainer(url: url, onLoginDetected: onLoginDetected)
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(url.host ?? "\u{62A}\u{633}\u{62C}\u{64A}\u{644} \u{627}\u{644}\u{62F}\u{62E}\u{648}\u{644}")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        AppAnimatedBackButton(size: 36, accessibilityLabel: "\u{625}\u{63A}\u{644}\u{627}\u{642}") {
                            dismiss()
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("\u{62A}\u{645} \u{62A}\u{633}\u{62C}\u{64A}\u{644} \u{627}\u{644}\u{62F}\u{62E}\u{648}\u{644}") {
                            onLoginDetected?()
                            dismiss()
                        }
                    }
                }
        }
    }
}

struct WebLoginContainer: UIViewRepresentable {
    let url: URL
    let onLoginDetected: (() -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(onLoginDetected: onLoginDetected) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let onLoginDetected: (() -> Void)?
        init(onLoginDetected: (() -> Void)?) { self.onLoginDetected = onLoginDetected }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
                cookies.forEach { HTTPCookieStorage.shared.setCookie($0) }
                DispatchQueue.main.async { self?.onLoginDetected?() }
            }
        }
    }
}
