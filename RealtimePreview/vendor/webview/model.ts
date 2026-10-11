// Preview state: background pages plus fast-path overlays (realtime-tex docs/VERSIONING.md).
// Pure module (no DOM), unit-tested with node:test.
import type { DisplayList, Fragment, Item, Line, NativePage, PageUpdate, Placement } from '../src/protocol';

export interface Overlay {
  parId: number;
  dl: DisplayList;
  native?: NativePage;
  fragments: Fragment[];
  /** source_revision of the edit that produced it. */
  revision: number;
}

export interface OverlayRow {
  /** Zero-based line index in the overlay display list. */
  index: number;
  line: Line;
  dx: number;
  dy: number;
}

export interface PageOverlay {
  overlay: Overlay;
  rows: OverlayRow[];
}

export interface LayoutInput {
  pages: PageUpdate[];
  pagesTotal: number;
  placements: Placement[];
  /** Keep overlays with revision >= this (the layout is stale since it); null drops them all. */
  keepFromRevision: number | null;
}

const MATCH_TOLERANCE = 64; // sp

export class PreviewModel {
  readonly pages = new Map<number, PageUpdate>();
  pagesTotal = 0;
  /** Layout placements per unit. */
  readonly placements = new Map<number, Fragment[]>();
  readonly overlays = new Map<number, Overlay>();
  private hiddenCache = new Map<number, Set<number>>();

  get hasLayout(): boolean {
    return this.pagesTotal > 0;
  }

  /** Install a background layout. Returns the pages whose drawing changed. */
  applyLayout(input: LayoutInput): Set<number> {
    const dirty = new Set<number>();
    for (const ov of this.overlays.values()) for (const f of ov.fragments) dirty.add(f.page);
    for (const p of input.pages) {
      this.pages.set(p.page, p);
      dirty.add(p.page);
    }
    this.pagesTotal = input.pagesTotal;
    for (const n of [...this.pages.keys()]) if (n > input.pagesTotal) this.pages.delete(n);
    this.placements.clear();
    for (const pl of input.placements) this.placements.set(pl.par_id, pl.fragments);
    for (const [id, ov] of [...this.overlays]) {
      if (input.keepFromRevision === null || ov.revision < input.keepFromRevision) {
        this.overlays.delete(id);
        continue;
      }
      const placed = this.placements.get(id);
      if (placed) ov.fragments = reanchor(placed, ov.dl.lines);
      for (const f of ov.fragments) dirty.add(f.page);
    }
    this.hiddenCache.clear();
    for (const n of dirty) if (n > this.pagesTotal) dirty.delete(n);
    return dirty;
  }

  /** Install a fast-path result. Returns the pages to redraw. */
  applyParagraph(parId: number, dl: DisplayList, fragments: Fragment[], revision: number, native?: NativePage): Set<number> {
    if (needsNativeDrawing(dl, native)) return new Set();
    const dirty = new Set<number>();
    const old = this.overlays.get(parId);
    if (old) for (const f of old.fragments) dirty.add(f.page);
    this.overlays.set(parId, { parId, dl, native, fragments, revision });
    for (const f of fragments) dirty.add(f.page);
    for (const f of this.placements.get(parId) ?? []) {
      dirty.add(f.page);
      this.hiddenCache.delete(f.page);
    }
    return dirty;
  }

  /** Whether the preview shows something for unit `parId` (a live result, or layout rows). */
  shows(parId: number): boolean {
    return this.overlays.has(parId) || (this.placements.get(parId)?.length ?? 0) > 0;
  }

  /**
   * Boxes (sp, page coordinates: left, top, width, height) around what unit `parId` shows on
   * `page`: its live rows when it has a live result, else its rows in the layout. One box per
   * unit and page (the union), for the outline of a held unit.
   */
  unitBox(page: number, parId: number): { x: number; y: number; w: number; h: number } | undefined {
    const boxes: [number, number, number, number][] = [];
    const ov = this.overlays.get(parId);
    if (ov) {
      for (const po of this.overlaysOn(page)) {
        if (po.overlay.parId !== parId) continue;
        for (const r of po.rows) boxes.push([r.line.x + r.dx, r.line.y + r.dy - r.line.h, r.line.w, r.line.h + r.line.d]);
      }
    } else {
      const pu = this.pages.get(page);
      if (pu) for (const i of this.ownLines(page, parId)) {
        const l = pu.dl.lines[i];
        boxes.push([l.x, l.y - l.h, l.w, l.h + l.d]);
      }
    }
    if (!boxes.length) return undefined;
    const x0 = Math.min(...boxes.map((b) => b[0]));
    const y0 = Math.min(...boxes.map((b) => b[1]));
    const x1 = Math.max(...boxes.map((b) => b[0] + b[2]));
    const y1 = Math.max(...boxes.map((b) => b[1] + b[3]));
    return { x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
  }

  /** The pages unit `parId` shows on (live rows and layout rows). */
  unitPages(parId: number): Set<number> {
    const pages = new Set<number>();
    for (const f of this.overlays.get(parId)?.fragments ?? []) pages.add(f.page);
    for (const f of this.placements.get(parId) ?? []) pages.add(f.page);
    return pages;
  }

  /** Drop overlays (all when `ids` is undefined). Returns the pages to redraw. */
  dropOverlays(ids?: number[]): Set<number> {
    const dirty = new Set<number>();
    const victims = ids ?? [...this.overlays.keys()];
    for (const id of victims) {
      const ov = this.overlays.get(id);
      if (!ov) continue;
      this.overlays.delete(id);
      for (const f of ov.fragments) dirty.add(f.page);
      for (const f of this.placements.get(id) ?? []) {
        dirty.add(f.page);
        this.hiddenCache.delete(f.page);
      }
    }
    return dirty;
  }

  clear(): void {
    this.pages.clear();
    this.placements.clear();
    this.overlays.clear();
    this.hiddenCache.clear();
    this.pagesTotal = 0;
  }

  /** Indices of the page's lines replaced by overlays (rows of units that have one). */
  hiddenLines(page: number): Set<number> {
    let set = this.hiddenCache.get(page);
    if (set) return set;
    set = new Set<number>();
    for (const id of this.overlays.keys()) for (const i of this.ownLines(page, id)) set.add(i);
    this.hiddenCache.set(page, set);
    return set;
  }

  /**
   * Indices of the page's lines that belong to unit `parId` in the last layout: the lines at
   * the unit's placement rows (baseline and x), plus every other line the capture attributed
   * to the same capture unit (`line.unit`). The second part catches rows a placement does not
   * pin down exactly (a picture row, a display), so nothing of the unit stays behind at its old
   * place while the live result is drawn at the new one.
   */
  ownLines(page: number, parId: number): Set<number> {
    const set = new Set<number>();
    const pu = this.pages.get(page);
    if (!pu) return set;
    const units = new Set<number>();
    for (const f of this.placements.get(parId) ?? []) {
      if (f.page !== page) continue;
      for (let k = 0; k < f.baselines.length; k++) {
        pu.dl.lines.forEach((line, idx) => {
          if (Math.abs(line.y - f.baselines[k]) <= MATCH_TOLERANCE && Math.abs(line.x - (f.xs[k] ?? f.x)) <= MATCH_TOLERANCE) {
            set.add(idx);
            if (line.unit) units.add(line.unit);
          }
        });
      }
    }
    if (units.size) pu.dl.lines.forEach((line, idx) => line.unit && units.has(line.unit) && set.add(idx));
    return set;
  }

  /** Overlay rows to draw on `page`, with the translation of each row into page coordinates. */
  overlaysOn(page: number): PageOverlay[] {
    const out: PageOverlay[] = [];
    for (const ov of this.overlays.values()) {
      const rows: OverlayRow[] = [];
      for (const f of ov.fragments) {
        if (f.page !== page) continue;
        for (let k = 0; k < f.baselines.length; k++) {
          const line = ov.dl.lines[f.first_line - 1 + k];
          if (!line) continue;
          rows.push({ index: f.first_line - 1 + k, line, dx: (f.xs[k] ?? f.x) - line.x, dy: f.baselines[k] - line.y });
        }
      }
      if (rows.length) out.push({ overlay: ov, rows });
    }
    return out;
  }

  /** Where each unit currently is: overlay fragments win over layout placements. */
  currentPlacements(): Map<number, Fragment[]> {
    const out = new Map(this.placements);
    for (const ov of this.overlays.values()) out.set(ov.parId, ov.fragments);
    return out;
  }
}

/** Place a unit's rows at a layout's placement rows (the algorithm of rtex layout.rs
 * `fragments`): rows are positioned relative to the first placement row of each page; rows
 * beyond the placement continue on its last page. */
export function reanchor(placed: readonly Fragment[], rows: readonly Line[]): Fragment[] {
  const pl: { page: number; x: number; y: number }[] = [];
  for (const f of placed) for (let k = 0; k < f.baselines.length; k++) pl.push({ page: f.page, x: f.xs[k] ?? f.x, y: f.baselines[k] });
  const frags: Fragment[] = [];
  let i = 0;
  while (i < pl.length && i < rows.length) {
    const page = pl[i].page;
    const anchor = pl[i];
    const ax = rows[i].x;
    const ay = rows[i].y;
    const first = i;
    const xs: number[] = [];
    const baselines: number[] = [];
    while (i < pl.length && pl[i].page === page && i < rows.length) {
      xs.push(anchor.x + (rows[i].x - ax));
      baselines.push(anchor.y + (rows[i].y - ay));
      i++;
    }
    let approximate = false;
    if (i >= pl.length) {
      while (i < rows.length) {
        xs.push(anchor.x + (rows[i].x - ax));
        baselines.push(anchor.y + (rows[i].y - ay));
        i++;
        approximate = true;
      }
    }
    frags.push({ page, first_line: first + 1, last_line: i, x: xs[0], xs, baselines, approximate });
  }
  return frags;
}

/** A rectangle in sp. */
export interface Rect {
  x: number;
  y: number;
  w: number;
  h: number;
}

/** A picture rtex reused from its picture cache: `["u", "cached_picture", "<index> <x> <top> <width> <height>"]`
 * (rtex f345c45; sp, in the list's frame). Undefined for any other item. */
/** A cached picture item: "<index> <x> <top> <width> <height>[ <key>]" (newer rtex names the
 * picture's cache key, `file:line`, last). */
export function cachedPicture(it: Item): (Rect & { index: number; key?: string }) | undefined {
  if (it[0] !== 'u' || it[1] !== 'cached_picture') return undefined;
  const raw = it[2];
  const parts = Array.isArray(raw) ? raw.map(String) : String(raw ?? '').trim().split(/\s+/);
  const v = parts.slice(0, 5).map(Number);
  if (v.length < 5 || !v.every(Number.isFinite)) return undefined;
  const [index, x, y, w, h] = v;
  if (!(w > 0 && h > 0)) return undefined;
  return parts.length > 5 ? { index, x, y, w, h, key: parts.slice(5).join(' ') } : { index, x, y, w, h };
}

/**
 * Where the cached pictures of a live unit were on the page (`src`, from the page's display
 * list) and where they are now (`dst`, the unit's item moved by its row's translation). A
 * live compile carries a cached picture only as an item; its pixels come from the page as the
 * last layout drew it, so they are carried over to the new position. Only pictures on the
 * unit's own page lines (`own`, from PreviewModel.ownLines) are candidates: their items, and on a
 * natively drawn page the picture spots (`pictures`) inside those lines' boxes. They pair by
 * cache key (two keys that differ never pair), then picture index, then size: a picture of
 * another unit is never taken. A picture with no counterpart among them (e.g. it moved here
 * from another page) is skipped.
 */
export function cachedPictureMoves(page: DisplayList, rows: readonly OverlayRow[], own: ReadonlySet<number>): { src: Rect; dst: Rect }[] {
  const onPage: (Rect & { index: number; key?: string })[] = [];
  const spots = new Set(page.pictures ?? []);
  page.lines.forEach((line, idx) => {
    if (!own.has(idx)) return;
    for (const it of line.items) {
      const c = cachedPicture(it);
      if (c) onPage.push(c);
    }
    // pictures a natively drawn page draws from the cache's stored drawing (their items were
    // replaced): the ones inside this line's box
    for (const p of spots) {
      const inside =
        p.x >= line.x - MATCH_TOLERANCE &&
        p.x + p.width <= line.x + line.w + MATCH_TOLERANCE &&
        p.top >= line.y - line.h - MATCH_TOLERANCE &&
        p.top + p.height <= line.y + line.d + MATCH_TOLERANCE;
      if (!inside) continue;
      spots.delete(p);
      onPage.push({ index: -1, key: p.key, x: p.x, y: p.top, w: p.width, h: p.height });
    }
  });
  const used = new Set<number>();
  const out: { src: Rect; dst: Rect }[] = [];
  for (const { line, dx, dy } of rows) {
    for (const it of line.items) {
      const c = cachedPicture(it);
      if (!c) continue;
      const same = (k: number) =>
        !used.has(k) &&
        !(c.key && onPage[k].key && c.key !== onPage[k].key) &&
        Math.abs(onPage[k].w - c.w) <= MATCH_TOLERANCE &&
        Math.abs(onPage[k].h - c.h) <= MATCH_TOLERANCE;
      let k = c.key ? onPage.findIndex((p, i) => p.key === c.key && same(i)) : -1;
      if (k < 0) k = onPage.findIndex((p, i) => p.index === c.index && same(i));
      if (k < 0) k = onPage.findIndex((_, i) => same(i));
      if (k < 0) continue;
      used.add(k);
      const p = onPage[k];
      out.push({ src: { x: p.x, y: p.y, w: p.w, h: p.h }, dst: { x: c.x + dx, y: c.y + dy, w: c.w, h: c.h } });
    }
  }
  return out;
}

/** A literal without native ops must keep the previous picture until the next layout. */
export function needsNativeDrawing(dl: DisplayList, native?: NativePage): boolean {
  return !native && [...(dl.other ?? []), ...dl.lines.flatMap((line) => line.items)].some((it) => it[0] === 'l');
}
