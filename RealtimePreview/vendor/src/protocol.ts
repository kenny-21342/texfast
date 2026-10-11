// Types of the `rtex serve` JSON-lines protocol (realtime-tex crates/rtex-cli/src/serve.rs and
// crates/rtex-core/src/session.rs). Display lists use the JSON mirror of docs/DISPLAY_LIST.md.

export type Sp = number;

export interface Versions {
  source_revision: number;
  context_revision: number;
  engine_generation: number;
  layout_version: number;
}

export interface FontDesc {
  id: number;
  name?: string | null;
  fullname?: string | null;
  psname?: string | null;
  filename?: string | null;
  format?: string | null;
  type?: string | null;
  size?: number | null;
  designsize?: number | null;
  slant?: number | null;
  extend?: number | null;
  squeeze?: number | null;
  subfont?: number | null;
}

/** Items: ["g",font,char,index,x,y,w,ef] ["r",x,y_top,w,h] ["c",stack,cmd,data,after?] ["l",mode,data]
 * ["u",kind,detail] ["m","on"|"off",x] ["i",index,x,y_top,w,h] ["M","save"|"set"|"restore",x,y,data] */
export type Item = [string, ...unknown[]];

export interface Line {
  par?: number;
  i?: number;
  unit?: number;
  row?: number;
  x: Sp;
  y: Sp;
  w: Sp;
  h: Sp;
  d: Sp;
  items: Item[];
}

export interface ImageInfo {
  file: string;
  page?: number;
  pages?: number;
  /** A TikZ picture the background pass reused from an earlier pass's PDF (the page is
   * degraded and drawn from the PDF); `bbox` is its region there. */
  cached_picture?: boolean;
  bbox?: [number, number, number, number];
}

export interface DisplayList {
  kind: string;
  fonts: Record<string, FontDesc>;
  lines: Line[];
  other: Item[];
  flags: unknown;
  glyphs?: number;
  inserts?: number;
  images_info?: Record<string, ImageInfo>;
  width: Sp;
  height: Sp;
  depth: Sp;
  page?: number | null;
  page_width?: Sp;
  page_height?: Sp;
  /** The page's /Rotate, degrees clockwise (pdflscape's landscape pages). Coordinates are those
   * of the unrotated page; the preview turns the whole page as PDF viewers do. */
  rotate?: number;
  /** Pictures the page draws from the picture cache's stored drawing (native drawing): where
   * each is, by cache key (`file:line`). */
  pictures?: PictureSpot[];
}

export interface PictureSpot {
  key: string;
  x: Sp;
  top: Sp;
  width: Sp;
  height: Sp;
}

export interface Fragment {
  page: number;
  first_line: number;
  last_line: number;
  x: Sp;
  xs: Sp[];
  baselines: Sp[];
  approximate: boolean;
}

export interface Placement {
  par_id: number;
  fragments: Fragment[];
  lines: number;
  kind: string;
}

export interface PageUpdate {
  page: number;
  exact: boolean;
  hash: number;
  dl: DisplayList;
  /** A degraded page rtex can draw without its PDF (TikZ/pgf literals and shadings): the drawing
   * operations, interleaved with the list's items (realtime-tex docs/DISPLAY_LIST.md, "Native
   * drawing"). Absent when the page needs the PDF, or from an rtex without native drawing. */
  native?: NativePage;
}

/** Where an item sits: a row (`line`) or the page's `other` items (`line: null`). */
export interface ItemRef {
  line: number | null;
  item: number;
}

/** [a, b, c, d, e, f]: x' = a·x + c·y + e, y' = b·x + d·y + f. */
export type Matrix = [number, number, number, number, number, number];

/** Path segment in user space (PDF units, y up); the op's `ctm` maps it to sp, y down. */
export type Seg =
  | { s: 'M'; x: number; y: number }
  | { s: 'L'; x: number; y: number }
  | { s: 'C'; x1: number; y1: number; x2: number; y2: number; x: number; y: number }
  | { s: 'Z' };

/** 1 gray, 3 RGB or 4 CMYK components (0..1), as the PDF gives them. */
export interface GfxColor {
  comps: number[];
  alpha: number;
}

export interface GfxStroke {
  color: GfxColor;
  width: number;
  /** 0 butt, 1 round, 2 square */
  cap: number;
  /** 0 miter, 1 round, 2 bevel */
  join: number;
  miter_limit: number;
  dash: number[];
  dash_phase: number;
}

export type GfxOp =
  | { op: 'Save'; at: ItemRef }
  | { op: 'Restore'; at: ItemRef }
  | { op: 'Clip'; at: ItemRef; ctm: Matrix; path: Seg[]; even_odd: boolean }
  | {
      op: 'Paint';
      at: ItemRef;
      ctm: Matrix;
      path: Seg[];
      /** with `pattern`: the pattern's tint (uncoloured patterns) and opacity */
      fill: GfxColor | null;
      even_odd: boolean;
      stroke: GfxStroke | null;
      /** the fill is this tiling pattern (`NativePage.patterns`) */
      pattern?: string;
      /** painted under this soft mask (`NativePage.masks`) */
      mask?: string;
    }
  | {
      op: 'Shade';
      at: ItemRef;
      ctm: Matrix;
      /** [x0, y0, x1, y1] in form space */
      bbox: [number, number, number, number];
      radial: boolean;
      /** axial [x0 y0 x1 y1], radial [x0 y0 r0 x1 y1 r1] */
      coords: number[];
      extend: [boolean, boolean];
      /** [offset 0..1, color] */
      stops: [number, GfxColor][];
      alpha: number;
      /** painted under this soft mask (`NativePage.masks`) */
      mask?: string;
    };

export interface NativePage {
  ops: GfxOp[];
  /** Items a transformed pgf scope moves (rotated/scaled node text): draw with this map (sp to
   * sp) instead of their MATRIX records. */
  transforms: [ItemRef, Matrix][];
  /** Tiling patterns (pgf's patterns library) the Paint ops fill with, by name. */
  patterns?: Record<string, PatternCell>;
  /** Soft masks (pgf's fadings) ops are painted under, by instance. */
  masks?: Record<string, MaskCell>;
}

/** A soft mask: what its form draws (`ops`, page coordinates), and the form's box `bbox` (form
 * space) with `ctm` from form space to sp. Ops under it get, as opacity, the luminosity of this
 * drawing over black (black, so transparent, outside the box). */
export interface MaskCell {
  ops: GfxOp[];
  bbox: [number, number, number, number];
  ctm: Matrix;
}

/** A tiling pattern's cell: `ops` (their ctm maps to pattern space) drawn clipped to `bbox` at
 * every (i·xstep, j·ystep), `matrix` mapping pattern space to sp, y down. An uncoloured cell is
 * painted in the tint of the fill that uses it. */
export interface PatternCell {
  colored: boolean;
  bbox: [number, number, number, number];
  xstep: number;
  ystep: number;
  matrix: Matrix;
  ops: GfxOp[];
}

export type Convergence =
  | { state: 'Converged' }
  | { state: 'Converging'; pass: number; reasons: string[] }
  | { state: 'PassLimitReached'; passes: number; reasons: string[] }
  | { state: 'Stale'; pending_since: number };

export type CompileStatus = { state: 'Ok' } | { state: 'CompiledWithErrors'; count: number } | { state: 'Failed' };

export interface Diagnostic {
  severity: string;
  file?: string | null;
  line?: number | null;
  message: string;
  context?: string | null;
}

export interface Timing {
  total_us: number;
  tex_us: number;
  traverse_us: number;
  pack_us: number;
}

export interface ParagraphUpdateEvent {
  event: 'ParagraphUpdate';
  par_id: number;
  edit_id: number;
  versions: Versions;
  status: string;
  reasons: string[];
  fragments: Fragment[];
  pagination_stale: boolean;
  context_stale: boolean;
  dl: DisplayList;
  /** Native drawing in the unit display list frame; place with the row translation. */
  native?: NativePage;
  diagnostics: Diagnostic[];
  timing: Timing;
}

export interface LayoutUpdateEvent {
  event: 'LayoutUpdate';
  versions: Versions;
  compile: CompileStatus;
  convergence: Convergence;
  passes: number;
  pages_changed: PageUpdate[];
  pages_total: number;
  placements: Placement[];
  eligible_paragraphs: number[];
  pdf_fallback: string | null;
  wall_ms: number;
  /** Pictures shown in their last good version while their source has errors (rtex ≥ 0.0.6). */
  held?: HeldPicture[];
}

/** A picture rtex shows in its last good version (realtime-tex docs/how-it-works.md, "Held pictures"). */
export interface HeldPicture {
  /** The unit (span) that shows it; the placements give its place. */
  par_id: number;
  file: string;
  /** 1-based `\begin` and `\end` lines. */
  line: number;
  end_line: number;
  since_revision: number;
}

export interface DiagnosticsEvent {
  event: 'Diagnostics';
  source: string;
  items: Diagnostic[];
}

export interface EngineStateEvent {
  event: 'EngineState';
  engine_generation: number;
  state: string;
  reason: string | null;
}

export interface BackgroundScheduledEvent {
  event: 'BackgroundScheduled';
  par_id: number | null;
  reasons: string[];
  edit_id: number;
}

export interface PdfExportedEvent {
  event: 'PdfExported';
  job_id: number;
  path: string | null;
  status: CompileStatus;
  converged: boolean;
  passes: number;
}

export type RtexEvent =
  | ParagraphUpdateEvent
  | LayoutUpdateEvent
  | DiagnosticsEvent
  | EngineStateEvent
  | BackgroundScheduledEvent
  | PdfExportedEvent;

export interface EditOutcome {
  touched: number[];
  added: number[];
  removed: number[];
}

export interface EditResult {
  edit_id: number;
  source_revision: number;
  outcome: EditOutcome;
  routed: 'fast' | 'background' | 'preamble' | string;
  reasons: string[];
}

export interface Span {
  id: number;
  range: { start: number; end: number };
  kind: 'Preamble' | 'Body' | 'Env' | 'Heading' | 'Trailer';
  hash: number;
  last_revision: number;
}

export type Reply =
  | { reply: 'edit'; result: EditResult }
  | { reply: 'set_document'; result: EditResult }
  | { reply: 'spans'; spans: Span[] }
  | { reply: 'status'; versions: Versions; convergence: Convergence | null }
  | { reply: 'request_layout' }
  | { reply: 'export_pdf'; job_id: number }
  | { reply: 'error'; message: string };

export type Command =
  | { cmd: 'edit'; path: string; start: number; end: number; text: string }
  | { cmd: 'set_document'; path: string; text: string }
  | { cmd: 'spans'; path: string }
  | { cmd: 'status' }
  | { cmd: 'request_layout' }
  | { cmd: 'export_pdf'; out: string }
  | { cmd: 'quit' };

/** 1 pt = 65536 sp; 1 bp = 65781.76 sp. */
export const SP_PER_PT = 65536;
export const SP_PER_BP = 65781.76;
