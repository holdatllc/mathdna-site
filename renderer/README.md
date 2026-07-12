# MathDNA LaTeX Renderer — Handoff

How MathDNA renders "hard" problems (NuminaMath / competition / olympiad) whose text is
LaTeX-laced — prose with inline `$…$` and display `$$…$$` math (`\binom`, `\sum`, `\frac`,
matrices, `\begin{align}`, …). Plain `Text` shows raw backslashes; this renders real math.

## Approach (the important part — portable to any stack)

- **Renderer:** **MathJax 3 `tex-svg`** — a *single self-contained ~2.3 MB JS file* with
  **SVG output** and **fonts embedded** (no separate font files). This is what makes it
  trivially **offline** and easy to bundle vs. KaTeX (which needs ~60 font files).
- **Host:** a `WKWebView` (WebKit is on iOS *and* macOS). We give it an HTML page:
  the escaped problem text in a `<div>`, MathJax configured to auto-typeset `$…$`/`$$…$$`,
  transparent background, light text. MathJax typesets, we measure the content height and
  post it back so the SwiftUI view sizes itself.
- **Why a webview, not a native math lib (iosMath/SwiftMath):** those render *standalone
  formulas*, not *prose with inline math*. NuminaMath problems are sentences with math
  mixed in; MathJax/KaTeX are built for exactly that and handle every construct.

**Non-Apple stacks:** same idea — bundle `tex-svg-full.js`, drop the problem text (with
`$…$`) into an element, call `MathJax.typesetPromise([el])`. React Native → a WebView;
web → an iframe/div; Android → a `WebView`. The renderer is platform-agnostic; only the
host view changes.

## The MathJax asset

```
https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-svg-full.js   # ~2.3 MB, self-contained
```
Bundle it as an app resource (we ship it in `Sources/MathDNA/Resources/mathjax-tex-svg.js`).

## Three gotchas that will bite you

1. **Inline the JS — do NOT use `<script src=…>` with `loadHTMLString(baseURL:)`.**
   `WKWebView.loadHTMLString(_:baseURL:)` does **not** grant a bundled script file read
   access, so `src="mathjax…js"` silently fails. We read the JS once (cached `static let`)
   and inline it into the page. `loadHTMLString(html, baseURL: nil)`.
2. **HTML-escape the whole string (`& < >`), then it still typesets.** The browser decodes
   entities back to text *before* MathJax reads the DOM, so `$a &lt; b$` → text `$a < b$`
   → MathJax renders `a < b`. Escaping is safe **and** required (prose can contain `<`).
3. **Content height** comes back via a `WKScriptMessageHandler` after typesetting; drive a
   SwiftUI `@State` height with it. Set `allowsHitTesting(false)` so the webview doesn't
   eat taps meant for the surrounding card/row.

## Performance rule

A `WKWebView` is heavy — use the renderer **only where one problem is shown** (the solve
screen). For **list rows**, use a cheap plain-text preview (`String.deLatexed`, included
below) — a webview per row would jank/crash a long list.

## Integration (MathDNA)

```swift
// Full problem (solve screen):
MathText(text: problem.problemText)

// List row preview (no webview):
Text(problem.problemText.deLatexed).lineLimit(2)
```

## The code (`MathView.swift`)

```swift
import SwiftUI
import WebKit

struct MathText: View {
    let text: String
    var cssColor: String = "#E9F3EF"     // light text on dark cards
    var fontSize: CGFloat = 17
    @State private var height: CGFloat = 22

    var body: some View {
        MathWebView(text: text, cssColor: cssColor, fontSize: fontSize, height: $height)
            .frame(height: height)
            .allowsHitTesting(false)         // taps fall through to the card/row
    }

    /// MathJax bundle, read ONCE and inlined into each page (avoids WKWebView's
    /// local-file access restriction with loadHTMLString).
    static let mathjaxJS: String = {
        guard let url = Bundle.main.url(forResource: "mathjax-tex-svg", withExtension: "js"),
              let js = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return js
    }()

    static func html(_ text: String, cssColor: String, fontSize: CGFloat) -> String {
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
    /// Plain-text-ish preview of LaTeX-laced text for compact list rows (no renderer).
    var deLatexed: String {
        var s = self
        for token in ["$$", "$", "\\(", "\\)", "\\[", "\\]", "\\left", "\\right",
                      "\\displaystyle", "\\,", "\\!", "\\;", "\\ "] {
            s = s.replacingOccurrences(of: token, with: " ")
        }
        s = s.replacingOccurrences(of: "\\", with: "")
        return s.replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

Live file: `Sources/MathDNA/Views/MathView.swift`. Asset: `Sources/MathDNA/Resources/mathjax-tex-svg.js`.
