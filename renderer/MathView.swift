// MathText — renders a problem's text WITH LaTeX math (inline $…$ and display $$…$$),
// so competition/olympiad problems (NuminaMath) display as real typeset math instead of
// raw backslashes. Backed by a bundled, OFFLINE MathJax (SVG output) inlined into a
// WKWebView. Works on iOS and macOS. Content-sized, transparent background.

import SwiftUI
import WebKit

struct MathText: View {
    let text: String
    var cssColor: String = "#E9F3EF"     // light text on the dark cards
    var fontSize: CGFloat = 17
    @State private var height: CGFloat = 22

    var body: some View {
        MathWebView(text: text, cssColor: cssColor, fontSize: fontSize, height: $height)
            .frame(height: height)
            .allowsHitTesting(false)         // taps fall through to the card/row
    }

    /// The MathJax bundle, read from the app resources ONCE and inlined into each page
    /// (avoids WKWebView's local-file access restrictions with loadHTMLString).
    static let mathjaxJS: String = {
        guard let url = Bundle.main.url(forResource: "mathjax-tex-svg", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    static func html(_ text: String, cssColor: String, fontSize: CGFloat) -> String {
        // Escape HTML in the source; the browser decodes entities back to text before
        // MathJax reads them, so `$a < b$` still typesets correctly.
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
          html,body{margin:0;padding:0;background:transparent;}
          #c{color:\(cssColor);font:\(Int(fontSize))px/1.5 -apple-system,system-ui,sans-serif;
             word-wrap:break-word;overflow-wrap:break-word;}
          mjx-container{color:\(cssColor) !important;}
          mjx-container[display="true"]{margin:.4em 0;}
        </style>
        <script>
          window.MathJax={tex:{inlineMath:[['$','$'],['\\\\(','\\\\)']],
                               displayMath:[['$$','$$'],['\\\\[','\\\\]']]},
            svg:{fontCache:'none'},options:{enableMenu:false},startup:{typeset:false}};
        </script>
        <script>\(mathjaxJS)</script>
        </head><body><div id="c">\(escaped)</div>
        <script>
          function report(){
            if(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers.h){
              window.webkit.messageHandlers.h.postMessage(
                Math.ceil(document.getElementById('c').getBoundingClientRect().height)+2);
            }
          }
          (MathJax.startup.promise||Promise.resolve())
            .then(function(){return MathJax.typesetPromise([document.getElementById('c')]);})
            .then(report).catch(report);
          window.addEventListener('resize', report);
        </script>
        </body></html>
        """
    }
}

#if os(iOS)
private typealias MathRepresentable = UIViewRepresentable
#else
private typealias MathRepresentable = NSViewRepresentable
#endif

struct MathWebView: MathRepresentable {
    let text: String
    let cssColor: String
    let fontSize: CGFloat
    @Binding var height: CGFloat

    func makeCoordinator() -> Coordinator { Coordinator($height) }

    private func build(_ context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "h")
        let web = WKWebView(frame: .zero, configuration: cfg)
        #if os(iOS)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.isScrollEnabled = false
        web.scrollView.backgroundColor = .clear
        #else
        web.setValue(false, forKey: "drawsBackground")
        #endif
        web.loadHTMLString(MathText.html(text, cssColor: cssColor, fontSize: fontSize), baseURL: nil)
        return web
    }

    #if os(iOS)
    func makeUIView(context: Context) -> WKWebView { build(context) }
    func updateUIView(_ v: WKWebView, context: Context) {}
    #else
    func makeNSView(context: Context) -> WKWebView { build(context) }
    func updateNSView(_ v: WKWebView, context: Context) {}
    #endif

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let height: Binding<CGFloat>
        init(_ height: Binding<CGFloat>) { self.height = height }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            let h = (m.body as? NSNumber)?.doubleValue ?? 0
            guard h > 0 else { return }
            DispatchQueue.main.async { self.height.wrappedValue = CGFloat(h) }
        }
    }
}

extension String {
    /// A plain-text-ish preview of LaTeX-laced text for compact list rows (no renderer):
    /// drops math delimiters and the most common commands so it reads cleanly.
    var deLatexed: String {
        var s = self
        for token in ["$$", "$", "\\(", "\\)", "\\[", "\\]", "\\left", "\\right",
                      "\\displaystyle", "\\,", "\\!", "\\;", "\\ "] {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.replacingOccurrences(of: "\\", with: "")   // strip remaining command backslashes
        return s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
