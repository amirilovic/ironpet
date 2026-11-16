// Obsidian. The note is CodeMirror's editor root (`cm-editor`) in edit mode, or the rendered
// pane (`markdown-preview-view`) in reading mode, which keeps the file tree out. The window
// title "<note> - <vault> - Obsidian <version>" names the note. Ported from MaxMi's
// ObsidianParser.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["md.obsidian"] },
};

const PARSER_ID = "obsidian/v1";
// Rendered characters kept per note. The oldest (top) blocks go first.
const CONTENT_CAP = 32000;
const EDITOR_CLASS = "cm-editor";
const PREVIEW_CLASS = "markdown-preview-view";
const UNTITLED = "untitled";

const charCount = (s) => [...s].length;

// The window title, or the root window's name when the snapshot carries none.
const windowTitleOf = (snapshot) => {
  for (const raw of [snapshot.window_title, snapshot.root.role === "Window" ? snapshot.root.name : undefined]) {
    if (typeof raw === "string" && raw.trim() !== "") return raw.trim();
  }
  return undefined;
};

// "<note> - <vault> - Obsidian <version>" as [note, vault], parsed from the end because a
// note name may itself contain " - ". Any other title is the note with no vault.
const splitTitle = (title) => {
  const parts = title.split(" - ");
  if (parts.length >= 3 && parts[parts.length - 1].startsWith("Obsidian")) {
    return [parts.slice(0, parts.length - 2).join(" - "), parts[parts.length - 2]];
  }
  return [title, undefined];
};

const threadKey = (title, ctx) => {
  if (title === undefined) return "obsidian:unknown";
  const [note, vault] = splitTitle(title);
  return vault === undefined ? `obsidian:${ctx.slug(note)}` : `obsidian:${ctx.slug(vault)}/${ctx.slug(note)}`;
};

// Edit mode wins over reading mode: in split view the editor is what the user is changing.
const paneRoot = (root, ctx) =>
  ctx.find(`//*[domClass*="${EDITOR_CLASS}"]`, root) ?? ctx.find(`//*[domClass*="${PREVIEW_CLASS}"]`, root);

// Every heading and static text in the pane (the pane itself included) in visual order, each
// text once. Hidden, secure and menu subtrees are skipped.
const blockTexts = (pane, ctx) => {
  const found = [];
  const visit = (n) => {
    if (n.hidden || ctx.node.isSecure(n) || ctx.node.isMenuRole(n.role)) return;
    if (n.role === "Heading" || n.role === "StaticText") {
      const text = ctx.textOf(n);
      if (text !== undefined) found.push({ n, text });
    }
    for (const c of ctx.node.children(n)) visit(c);
  };
  visit(pane);
  const byNode = new Map(found.map((f) => [f.n, f.text]));
  const seen = new Set();
  const out = [];
  for (const n of ctx.sortedByVisualOrder(found.map((f) => f.n), pane.frame)) {
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
  const pane = paneRoot(snapshot.root, ctx);
  if (!pane) return null;
  const blocks = blockTexts(pane, ctx);
  if (blocks.length === 0) return null;
  const windowTitle = windowTitleOf(snapshot);
  const title = windowTitle === undefined ? UNTITLED : splitTitle(windowTitle)[0];
  const [kept, truncated] = bound(blocks, title, CONTENT_CAP);
  const out = ctx.item(
    { ...snapshot, url: undefined },
    PARSER_ID,
    threadKey(windowTitle, ctx),
    title,
    undefined,
    { kind: "document", title, text: kept.join("\n") },
  );
  out.truncated = out.truncated || truncated;
  return out;
}
