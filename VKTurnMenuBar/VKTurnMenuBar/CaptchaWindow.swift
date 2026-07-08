import SwiftUI
import WebKit

// CaptchaWindow embeds a WKWebView that loads VK's captcha page and captures
// the `success_token` VK returns from captchaNotRobot.check. This is the same
// technique the full app uses — a controllable WebView with a document-start
// JS hook — because that token can't be captured from an ordinary browser.
// On capture it hands the token to the engine via the control API and closes.
struct CaptchaWindow: View {
    @ObservedObject var controller: AgentController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Solve VK Captcha").font(.headline)
                Spacer()
                Button("Refresh") {
                    controller.refreshCaptcha { url in
                        if let url = url { controller.captchaURL = url }
                    }
                }
                Button("Done") { dismiss() }
            }
            .padding(8)

            if let url = controller.captchaURL {
                CaptchaWebView(url: url) { token in
                    controller.submitCaptcha(token: token)
                    dismiss()
                }
            } else {
                Spacer()
                Text("No captcha pending.")
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .frame(minWidth: 460, minHeight: 640)
    }
}

struct CaptchaWebView: NSViewRepresentable {
    let url: URL
    let onToken: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onToken: onToken) }

    func makeNSView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()

        let ucc = WKUserContentController()
        ucc.add(context.coordinator, name: "captchaToken")

        // Hook fetch + XHR to grab success_token from captchaNotRobot.check.
        let js = """
        (function() {
          var h = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.captchaToken;
          if (!h) return;
          var of = window.fetch;
          window.fetch = function() {
            var u = arguments[0]; if (typeof u === 'object' && u.url) u = u.url;
            var p = of.apply(this, arguments);
            if (String(u).indexOf('captchaNotRobot.check') !== -1) {
              p.then(function(r){return r.clone().json();}).then(function(d){
                if (d && d.response && d.response.success_token) h.postMessage(d.response.success_token);
              }).catch(function(){});
            }
            return p;
          };
          var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
          XMLHttpRequest.prototype.open = function(m,u){ this._u = u; return oo.apply(this, arguments); };
          XMLHttpRequest.prototype.send = function(){
            var x = this;
            if (this._u && String(this._u).indexOf('captchaNotRobot.check') !== -1) {
              x.addEventListener('load', function(){
                try { var d = JSON.parse(x.responseText);
                  if (d && d.response && d.response.success_token) h.postMessage(d.response.success_token);
                } catch(e){}
              });
            }
            return os.apply(this, arguments);
          };
        })();
        """
        ucc.addUserScript(WKUserScript(source: js, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        cfg.userContentController = ucc

        let web = WKWebView(frame: .zero, configuration: cfg)
        web.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        context.coordinator.lastURL = url.absoluteString
        web.load(URLRequest(url: url))
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        // Reload if the URL changed (Refresh fetched a fresh captcha).
        if context.coordinator.lastURL != url.absoluteString {
            context.coordinator.lastURL = url.absoluteString
            web.load(URLRequest(url: url))
        }
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onToken: (String) -> Void
        var lastURL: String?
        private var fired = false
        init(onToken: @escaping (String) -> Void) { self.onToken = onToken }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard !fired, let token = message.body as? String, !token.isEmpty else { return }
            fired = true
            DispatchQueue.main.async { self.onToken(token) }
        }
    }
}
