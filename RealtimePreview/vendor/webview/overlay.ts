// Place native ops and item transforms in the same frame as an overlay's rows.
import type { PageOverlay } from './model';
import { indexNative } from './native';
import { FontStore, ImageStore, Mat, Painter } from './render';

export function drawOverlay(ctx: CanvasRenderingContext2D, base: Mat, fonts: FontStore, images: ImageStore, { overlay, rows }: PageOverlay): void {
  if (!rows.length) return;
  const nativeRows = overlay.native ? indexNative(overlay.native) : undefined;
  const painter = new Painter(ctx, base, fonts, images);
  // Keep colour stack state across rows, translating the base matrix for each draw call.
  painter.draw(overlay.dl, overlay.dl.other ?? [], rows[0].dx, rows[0].dy, nativeRows?.get(null));
  for (const r of rows) painter.draw(overlay.dl, r.line.items, r.dx, r.dy, nativeRows?.get(r.index));
}
