// Turned pages: a page's /Rotate (pdflscape's landscape pages; DisplayList.rotate, degrees
// clockwise). Display lists keep the coordinates of the unrotated page; the preview turns the
// whole page as PDF viewers do. Pure helpers, shared by drawing, hit-testing and sizing.
import type { DisplayList } from '../src/protocol';

/** [a, b, c, d, e, f]: x' = a·x + c·y + e, y' = b·x + d·y + f (render.ts `Mat`; kept here so the
 * helpers stay free of the DOM). */
type Mat = [number, number, number, number, number, number];

/** The page's rotation, normalized to 0, 90, 180 or 270. */
export function rotationOf(dl: Pick<DisplayList, 'rotate'> | undefined): 0 | 90 | 180 | 270 {
  const r = ((((dl?.rotate ?? 0) % 360) + 360) % 360) as number;
  return r === 90 || r === 180 || r === 270 ? r : 0;
}

/** Width and height of the turned page, given the unrotated page's. */
export function displaySize(w: number, h: number, rot: number): [number, number] {
  return rot === 90 || rot === 270 ? [h, w] : [w, h];
}

/** The map from unrotated page coordinates (sp, y down) to the turned page's, for a page of
 * width `w` and height `h`. Clockwise: at 90° the top-left corner goes to the top right. */
export function turn(rot: number, w: number, h: number): Mat {
  switch (rot) {
    case 90:
      return [0, 1, -1, 0, h, 0];
    case 180:
      return [-1, 0, 0, -1, w, h];
    case 270:
      return [0, -1, 1, 0, 0, w];
    default:
      return [1, 0, 0, 1, 0, 0];
  }
}

/** A point of the turned page back in unrotated page coordinates. */
export function unturn(rot: number, w: number, h: number, x: number, y: number): [number, number] {
  switch (rot) {
    case 90:
      return [y, h - x];
    case 180:
      return [w - x, h - y];
    case 270:
      return [w - y, x];
    default:
      return [x, y];
  }
}
