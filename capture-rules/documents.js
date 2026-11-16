// Microsoft Word and Apple Pages. Ported from MaxMi's WordParser and PagesParser: the readable
// text of the whole window becomes a document, titled and keyed by the window title without the
// app's suffix. Each app keeps its own parser id and thread key prefix.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.microsoft.Word", "com.apple.iWork.Pages"] },
};

// Parser id, thread key prefix and window title suffixes, by bundle id.
const APPS = {
  "com.microsoft.word": { parser: "word/v1", prefix: "word", suffixes: [" - Microsoft Word", " — Microsoft Word"] },
  "com.apple.iwork.pages": { parser: "pages/v1", prefix: "pages", suffixes: [" - Pages", " — Pages"] },
};

// Rendered characters kept per capture, MaxMi's page budget. Lines past it are dropped.
const CONTENT_CAP = 32000;
const UNTITLED = "untitled";

const documentTitle = (raw, suffixes) => {
  let title = (raw ?? "").trim();
  for (const suffix of suffixes) {
    if (title.endsWith(suffix)) title = title.slice(0, title.length - suffix.length).trim();
  }
  return title === "" ? UNTITLED : title;
};

export function parse(snapshot, ctx) {
  const app = APPS[snapshot.app.bundle_id.toLowerCase()];
  if (app === undefined) return null;
  const [lines, truncated] = bound(pageLines(snapshot.root, ctx), CONTENT_CAP);
  // An empty window is not this rule's to refuse. The generic rule decides.
  if (lines.length === 0) return null;
  const title = documentTitle(titleOf(snapshot, ctx), app.suffixes);
  const slug = ctx.slug(title);
  const key = `${app.prefix}:${slug !== "" ? slug : UNTITLED}`;
  const content = { kind: "document", title, text: lines.join("\n") };
  const out = ctx.item({ ...snapshot, url: undefined }, app.parser, key, title, undefined, content);
  out.truncated = out.truncated || truncated;
  return out;
}

// ---- page text -------------------------------------------------------------------------------
// A small copy of the generic walk. MaxMi read these windows with its generic page extractor,
// and rules cannot import each other, so this file carries its own.

// Skipped with their subtree. A column republishes the cells its rows already emitted.
const SKIP_ROLES = ["ScrollBar", "Splitter", "GrowArea", "Column", "Toolbar"];
const TEXT_ROLES = ["Heading", "StaticText", "Paragraph", "Link"];
const INPUT_ROLES = ["TextArea", "TextField"];
const ROW_ROLES = ["ListItem", "TreeItem", "Row", "TableRow"];
// Subtrees that are not the main content. Their text goes after the main text.
const ASIDE_SUBROLES = ["LandmarkNavigation", "LandmarkComplementary", "LandmarkBanner", "LandmarkContentInfo"];
const ASIDE_HINTS = ["sidebar", "source list"];

const charCount = (s) => [...s].length;

const intersects = (a, b) =>
  a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height;

const isAside = (n, ctx) => {
  const raw = ctx.node.subrole(n);
  const sub = raw !== undefined && raw.startsWith("AX") ? raw.slice(2) : raw;
  if (sub !== undefined && ASIDE_SUBROLES.includes(sub)) return true;
  return [ctx.node.identifier(n), ctx.node.label(n)].some(
    (v) => v !== undefined && ASIDE_HINTS.some((h) => v.toLowerCase().includes(h)),
  );
};

// The text a node contributes, or undefined to descend into it. A text entry field contributes
// only its value: its name is a label, and live trees report a missing value as "".
const blockText = (n, ctx) => {
  if (ROW_ROLES.includes(n.role)) {
    const cells = ctx.rowCells(n);
    return cells.length > 0 ? cells.join(" ") : undefined;
  }
  if (INPUT_ROLES.includes(n.role)) {
    const v = (n.value ?? "").trim();
    return v !== "" ? v : undefined;
  }
  if (TEXT_ROLES.includes(n.role)) return ctx.textOf(n);
  return undefined;
};

// Readable lines of the window: main content in visual order, then sidebars. Menus, toolbars,
// hidden and secure subtrees, zero-size and offscreen nodes are skipped, and a repeated line
// is kept once. Iterative, because QuickJS has a small native stack.
const pageLines = (root, ctx) => {
  const win = root.frame;
  const found = [];
  const stack = [[root, false]];
  while (stack.length > 0) {
    const [n, aside] = stack.pop();
    if (ctx.node.isSecure(n) || ctx.node.isMenuRole(n.role) || n.hidden || SKIP_ROLES.includes(n.role)) continue;
    const f = n.frame;
    if (f && (f.width === 0 || f.height === 0)) continue;
    if (n !== root && f && win && win.width > 0 && win.height > 0 && !intersects(win, f)) continue;
    const inAside = aside || isAside(n, ctx);
    const text = blockText(n, ctx);
    if (text !== undefined) {
      found.push({ aside: inAside, y: f ? f.y : 0, x: f ? f.x : 0, order: found.length, text });
      continue;
    }
    const kids = ctx.node.children(n);
    for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], inAside]);
  }
  found.sort((a, b) => a.aside - b.aside || a.y - b.y || a.x - b.x || a.order - b.order);
  const seen = new Set();
  const out = [];
  for (const f of found) {
    if (seen.has(f.text)) continue;
    seen.add(f.text);
    out.push(f.text);
  }
  return out;
};

// Keeps whole lines from the top until `cap` characters are used. A first line longer than
// the cap is cut to it.
const bound = (lines, cap) => {
  const kept = [];
  let used = 0;
  for (const line of lines) {
    const cost = charCount(line) + (kept.length > 0 ? 1 : 0);
    if (used + cost > cap) {
      if (kept.length === 0) kept.push([...line].slice(0, cap).join(""));
      return [kept, true];
    }
    kept.push(line);
    used += cost;
  }
  return [kept, false];
};

// The window title, or the root window's name when the snapshot carries none.
const titleOf = (snapshot, ctx) => {
  const t = ctx.windowTitle(snapshot);
  if (t !== undefined) return t;
  const name = (snapshot.root.name ?? "").trim();
  return name !== "" ? name : undefined;
};
