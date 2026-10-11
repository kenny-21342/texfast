Renderer sources and preview.css copied from:
https://github.com/kenny-21342/realtime-tex-vsc-plugin
Commit: 85a1ed8b5b62488961152cde6abeea1c1b9d4bde
MIT license: LICENSE (included in the app).

The WKWebView adapter lives in ../bridge.ts. Vendor adaptations:
- pdf.ts preloads pdf.js's WorkerMessageHandler and uses its inline parser to
  avoid file-origin module-worker restrictions in WKWebView.
- main.ts reports renderPage promise failures with their stack traces so the
  native host can fall back on a genuine rendering failure. Other webview error
  notifications are logged, as in the original plugin host.
Engine: https://github.com/kenny-21342/realtime-tex/releases/tag/v0.0.7
Commit: 94bc97bf153ae37645f2f118b24cb076a9e05186
