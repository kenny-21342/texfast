// Native drawing of TikZ/pgf pages (realtime-tex docs/DISPLAY_LIST.md, "Native drawing"): which
// pages can be drawn without the PDF, and where each drawing operation goes among the items.
// Pure module (no DOM), unit-tested with node:test.
import type { DisplayList, GfxColor, GfxOp, MaskCell, Matrix, NativePage, PatternCell } from '../src/protocol';

/** Flags native drawing resolves (rtex_dl::gfx::RESOLVED_FLAGS). */
const RESOLVED = new Set(['literal', 'shading']);

/** The page's native drawing, when rtex sent one and every flag of the page is one it resolves. */
export function nativeOf(page: { exact: boolean; dl: DisplayList; native?: NativePage }): NativePage | undefined {
  if (page.exact || !page.native) return undefined;
  const flags = page.dl.flags && typeof page.dl.flags === 'object' && !Array.isArray(page.dl.flags) ? Object.keys(page.dl.flags as object) : [];
  return flags.every((f) => RESOLVED.has(f) || f.endsWith('_detail')) ? page.native : undefined;
}

/** Operations and item transforms of one row (`null`: the page's `other` items), by item index. */
export interface RowNative {
  /** ops to run right after item k */
  after: Map<number, GfxOp[]>;
  transforms: Map<number, Matrix>;
  /** the page's tiling pattern cells, by name */
  patterns: Record<string, PatternCell>;
  /** the page's soft masks, by instance */
  masks: Record<string, MaskCell>;
}

export function indexNative(n: NativePage): Map<number | null, RowNative> {
  const rows = new Map<number | null, RowNative>();
  const row = (line: number | null) => {
    let r = rows.get(line);
    if (!r) rows.set(line, (r = { after: new Map(), transforms: new Map(), patterns: n.patterns ?? {}, masks: n.masks ?? {} }));
    return r;
  };
  for (const op of n.ops) {
    const r = row(op.at.line);
    const list = r.after.get(op.at.item);
    if (list) list.push(op);
    else r.after.set(op.at.item, [op]);
  }
  for (const [at, m] of n.transforms) row(at.line).transforms.set(at.item, m);
  return rows;
}

/** RGB (0..1) of a DeviceCMYK color as pdf.js shows it, so that pages drawn here match pages
 * drawn from the PDF. The polynomial is pdf.js's DeviceCmykCS (pdfjs-dist 4.10, src/core/colorspace.js,
 * Apache-2.0, Mozilla Foundation), a fit of a press profile: CMYK magenta is rgb(251,49,153)
 * there, not the #ff00ff of the plain 1 - c formula. */
export function cmykToRgb(c: number, m: number, y: number, k: number): [number, number, number] {
  const r =
    255 +
    c * (-4.387332384609988 * c + 54.48615194189176 * m + 18.82290502165302 * y + 212.25662451639585 * k + -285.2331026137004) +
    m * (1.7149763477362134 * m - 5.6096736904047315 * y + -17.873870861415444 * k - 5.497006427196366) +
    y * (-2.5217340131683033 * y - 21.248923337353073 * k + 17.5119270841813) +
    k * (-21.86122147463605 * k - 189.48180835922747);
  const g =
    255 +
    c * (8.841041422036149 * c + 60.118027045597366 * m + 6.871425592049007 * y + 31.159100130055922 * k + -79.2970844816548) +
    m * (-15.310361306967817 * m + 17.575251261109482 * y + 131.35250912493976 * k - 190.9453302588951) +
    y * (4.444339102852739 * y + 9.8632861493405 * k - 24.86741582555878) +
    k * (-20.737325471181034 * k - 187.80453709719578);
  const b =
    255 +
    c * (0.8842522430003296 * c + 8.078677503112928 * m + 30.89978309703729 * y - 0.23883238689178934 * k + -14.183576799673286) +
    m * (10.49593273432072 * m + 63.02378494754052 * y + 50.606957656360734 * k - 112.23884253719248) +
    y * (0.03296041114873217 * y + 115.60384449646641 * k + -193.58209356861505) +
    k * (-22.33816807309886 * k - 180.12613974708367);
  return [r / 255, g / 255, b / 255];
}

/** CSS rgba() of a PDF device color (CMYK as pdf.js converts it, see cmykToRgb). */
export function cssColor(c: GfxColor, alpha = c.alpha): string {
  const v = c.comps;
  let rgb: number[];
  if (v.length === 1) rgb = [v[0], v[0], v[0]];
  else if (v.length === 3) rgb = v;
  else if (v.length === 4) rgb = cmykToRgb(v[0], v[1], v[2], v[3]);
  else rgb = [0, 0, 0];
  const b = (x: number) => Math.round(Math.max(0, Math.min(1, x)) * 255);
  return `rgba(${b(rgb[0])},${b(rgb[1])},${b(rgb[2])},${Math.max(0, Math.min(1, alpha))})`;
}

/** The band of an axial shading without extension: the quadrilateral of `bbox` points whose
 * projection on the axis lies between its ends (user space), or undefined for a degenerate axis. */
export function axialBand(coords: number[], bbox: [number, number, number, number]): [number, number][] | undefined {
  const [x0, y0, x1, y1] = coords;
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len = Math.hypot(dx, dy);
  if (!len) return undefined;
  // the bbox's extent along the normal: enough to cover it
  const [bx0, by0, bx1, by1] = bbox;
  const far = Math.hypot(bx1 - bx0, by1 - by0) + Math.hypot(x0 - bx0, y0 - by0) + len;
  const nx = (-dy / len) * far;
  const ny = (dx / len) * far;
  return [
    [x0 + nx, y0 + ny],
    [x1 + nx, y1 + ny],
    [x1 - nx, y1 - ny],
    [x0 - nx, y0 - ny],
  ];
}

/** The inverse of an affine map, or undefined when it is singular. */
export function invert(m: Matrix): Matrix | undefined {
  const det = m[0] * m[3] - m[1] * m[2];
  if (!det || !Number.isFinite(det)) return undefined;
  const a = m[3] / det, b = -m[1] / det, c = -m[2] / det, d = m[0] / det;
  return [a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5])];
}

/** The cell offsets (multiples of xstep, ystep) whose bbox overlaps one period [0, xstep] x
 * [0, ystep]: drawing the cell at each of these, clipped to its bbox, gives one period of the
 * tiling (content past a step wraps). */
export function wrapOffsets(cell: Pick<PatternCell, 'bbox' | 'xstep' | 'ystep'>): [number, number][] {
  const [x0, y0, x1, y1] = cell.bbox;
  const range = (lo: number, hi: number, step: number) => {
    const s = Math.abs(step);
    const out: number[] = [];
    // k·s + [lo, hi] overlaps [0, s]
    for (let k = Math.floor(-hi / s); k <= Math.ceil((s - lo) / s); k++) {
      if (k * s + hi > 0 && k * s + lo < s) out.push(k * s);
    }
    return out;
  };
  const xs = range(x0, x1, cell.xstep), ys = range(y0, y1, cell.ystep);
  return xs.flatMap((x) => ys.map((y) => [x, y] as [number, number]));
}

/** Luminosity (PDF's gray conversion) of RGBA pixels as their alpha, in place: a soft mask. */
export function luminosityToAlpha(px: Uint8ClampedArray): void {
  for (let i = 0; i < px.length; i += 4) {
    const y = 0.3 * px[i] + 0.59 * px[i + 1] + 0.11 * px[i + 2];
    px[i] = px[i + 1] = px[i + 2] = 0;
    px[i + 3] = Math.round(y);
  }
}
