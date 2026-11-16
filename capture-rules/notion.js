// Notion, desktop and web. The page body is the DOM element with the `notion-frame` class (or
// `notion-peek-renderer` for a page opened in the side peek). The comment rail and the property
// table live inside that frame and are skipped. Ported from MaxMi's NotionParser.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["notion.id"], hosts: ["www.notion.so", "notion.so", ".notion.site"] },
};

const PARSER_ID = "notion/v1";
// Rendered characters kept per page. The oldest (top) blocks go first.
const CONTENT_CAP = 32000;
// The page body in the main view, then in a peek view.
const FRAME_CLASSES = ["notion-frame", "notion-peek-renderer"];
// Chrome inside the frame: the comment and backlink rail, and the property table.
const SKIPPED_CLASSES = ["layout-margin-right", "notion-page-properties"];
const TOPBAR_CLASS = "notion-topbar";
const TITLE_SUFFIXES = [" — Notion", " - Notion"];
const UNTITLED = "untitled";

const charCount = (s) => [...s].length;

// The window title, or the root window's name when the snapshot carries none.
const windowTitleOf = (snapshot) => {
  for (const raw of [snapshot.window_title, snapshot.root.role === "Window" ? snapshot.root.name : undefined]) {
    if (typeof raw === "string" && raw.trim() !== "") return raw.trim();
  }
  return undefined;
};

const stripSuffix = (title) => {
  let out = title;
  for (const suffix of TITLE_SUFFIXES) out = out.split(suffix).join("");
  return out.trim();
};

const pageRoot = (root, ctx) => {
  for (const cls of FRAME_CLASSES) {
    const found = ctx.find(`//*[domClass*="${cls}"]`, root);
    if (found) return found;
  }
  return undefined;
};

// The first text of the top bar (the breadcrumb ends in the page name), then the window title
// without the " - Notion" suffix.
const pageTitle = (root, windowTitle, ctx) => {
  const topbar = ctx.find(`//*[domClass*="${TOPBAR_CLASS}"]`, root);
  if (topbar) {
    const texts = ctx.collectStaticTexts(topbar);
    if (texts.length > 0) return texts[0];
  }
  const fallback = stripSuffix(windowTitle ?? "");
  return fallback === "" ? UNTITLED : fallback;
};

// Heading and static-text values under the page root in visual order, chrome skipped, each
// text once. A node with text ends the descent, so a paragraph and its runs do not both appear.
// A heading without text of its own is descended into.
const blockTexts = (root, ctx) => {
  const found = [];
  const visit = (n) => {
    if (n.hidden || ctx.node.isSecure(n) || ctx.node.isMenuRole(n.role)) return;
    if (SKIPPED_CLASSES.some((cls) => ctx.node.hasClassContaining(n, cls))) return;
    if (n.role === "Heading" || n.role === "StaticText") {
      const text = ctx.textOf(n);
      if (text !== undefined) {
        found.push({ n, text });
        return;
      }
    }
    for (const c of ctx.node.children(n)) visit(c);
  };
  for (const c of ctx.node.children(root)) visit(c);
  const byNode = new Map(found.map((f) => [f.n, f.text]));
  const seen = new Set();
  const out = [];
  for (const n of ctx.sortedByVisualOrder(found.map((f) => f.n), root.frame)) {
    const text = byNode.get(n);
    if (seen.has(text)) continue;
    seen.add(text);
    out.push(text);
  }
  return out;
};

// Drops the oldest blocks until the text fits, keeping at least one.
const bound = (blocks, title, cap) => {
  const budget = Math.max(0, cap - (charCount(title) + 4));
  const cost = (b) => charCount(b) + 1;
  let total = Math.max(0, blocks.reduce((sum, b) => sum + cost(b), 0) - 1);
  let start = 0;
  while (blocks.length - start > 1 && total > budget) {
    total = Math.max(0, total - cost(blocks[start]));
    start += 1;
  }
  return [blocks.slice(start), start > 0];
};

export function parse(snapshot, ctx) {
  const root = pageRoot(snapshot.root, ctx);
  if (!root) return null;
  const windowTitle = windowTitleOf(snapshot);
  const title = pageTitle(snapshot.root, windowTitle, ctx);
  const blocks = blockTexts(root, ctx).filter((t) => t !== title);
  if (blocks.length === 0) return null;
  const [kept, truncated] = bound(blocks, title, CONTENT_CAP);

  // The window title names the page in both the app and the browser tab; the suffix differs
  // between them, so it is not part of the key.
  const keySource = windowTitle !== undefined && stripSuffix(windowTitle) !== "" ? stripSuffix(windowTitle) : title;
  const out = ctx.item(snapshot, PARSER_ID, `notion:${ctx.slug(keySource)}`, title, undefined, {
    kind: "document",
    title,
    text: kept.join("\n"),
  });
  out.truncated = out.truncated || truncated;
  return out;
}
