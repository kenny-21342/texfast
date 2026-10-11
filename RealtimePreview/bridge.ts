// Adapt the plugin's renderer to WKWebView; no VS Code runtime is required.
import { parseMapFile, parseEncFile, type1Outlines } from './vendor/src/type1';
const host = (window as any).webkit.messageHandlers.texfast;
let saved: any;
window.addEventListener('error', event => { event.stopImmediatePropagation(); host.postMessage({ type: 'log', message: event.error?.stack || `${event.message} ${event.filename}:${event.lineno}:${event.colno}` }); }, true);
window.addEventListener('unhandledrejection', event => host.postMessage({ type: 'renderFailure', message: event.reason?.stack || String(event.reason) }));
(window as any).acquireVsCodeApi = () => ({
  postMessage: (message: any) => host.postMessage(message),
  getState: () => saved,
  setState: (state: any) => { saved = state; },
});
const bytes = (base64: string) => Uint8Array.from(atob(base64), c => c.charCodeAt(0));
(window as any).texfastReceive = (message: any) => {
  if (message.type === 'resources') {
    message.fonts = message.fonts.map(([key, raw]: [string, any]) => {
      if (!raw.data) return [key, raw];
      if (raw.kind === 'sfnt') return [key, { kind: 'sfnt', data: bytes(raw.data) }];
      try {
        const entry = raw.mapLine ? [...parseMapFile(raw.mapLine).values()][0] : undefined;
        const outlines = type1Outlines(bytes(raw.data), raw.encoding ? parseEncFile(raw.encoding) : undefined);
        return [key, { kind: 'type1', ...outlines, slant: entry?.slant, extend: entry?.extend }];
      } catch (error) { return [key, { kind: 'missing', reason: String(error) }]; }
    });
    message.images = message.images.map(([key, raw]: [string, any]) => [key, raw.data ? { ...raw, data: bytes(raw.data) } : raw]);
  }
  if (message.type === 'layout' && message.pdf) message.pdf = bytes(message.pdf);
  window.dispatchEvent(new MessageEvent('message', { data: message }));
};
require('./vendor/webview/main');
