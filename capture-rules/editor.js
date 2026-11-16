// Cursor and VS Code. The visible buffer is a text area below an editor group (an identifier
// containing "editor", such as `workbench.editor.main`). The integrated terminal is a sibling
// panel, so anchoring on the editor group keeps it out. Ported from MaxMi's EditorParser.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode"] },
};

const PARSER_ID = "editor/v1";
// Rendered characters kept per buffer. The oldest (top) lines go first.
const CONTENT_CAP = 32000;
const UNTITLED = "untitled";
// Characters trimmed from each title part: the unsaved-file dot, spaces and tabs.
const TITLE_TRIM = /^[●• \t]+|[●• \t]+$/g;

const charCount = (s) => [...s].length;

// The window title, or the root window's name when the snapshot carries none.
const windowTitleOf = (snapshot) => {
  for (const raw of [snapshot.window_title, snapshot.root.role === "Window" ? snapshot.root.name : undefined]) {
    if (typeof raw === "string" && raw.trim() !== "") return raw;
  }
  return undefined;
};

// VS Code titles are "<file> — <workspace>", Cursor titles "<workspace> — <file>".
const titleParts = (title) => {
  if (title === undefined || title === "") return [];
  return title
    .split(" — ")
    .flatMap((p) => p.split(" - "))
    .map((p) => p.replace(TITLE_TRIM, ""))
    .filter((p) => p !== "");
};

// A name with an extension of at most five letters or digits: "app.swift", not ".env" or "v1.".
const looksLikeFilename = (value) => {
  const dot = value.lastIndexOf(".");
  if (dot <= 0 || dot === value.length - 1) return false;
  const ext = [...value.slice(dot + 1)];
  return ext.length <= 5 && ext.every((c) => /[\p{L}\p{N}]/u.test(c));
};

const activeTab = (parts) => (parts.length === 0 ? UNTITLED : parts.find(looksLikeFilename) ?? parts[0]);

const workspace = (parts) => {
  if (parts.length < 2) return undefined;
  const file = parts.find(looksLikeFilename);
  if (file === undefined) return undefined;
  return parts.find((p) => p !== file);
};

const threadKey = (parts, ctx) => {
  if (parts.length === 0) return "editor:unknown";
  const file = ctx.slug(activeTab(parts));
  const ws = workspace(parts);
  return ws === undefined ? `editor:${file}` : `editor:${ctx.slug(ws)}/${file}`;
};

// The longest non-blank text area under an editor group. The first of equal length wins.
const editorTextArea = (root, ctx) => {
  let best;
  for (const area of ctx.findAll(`//Group[identifier*="editor"]//TextArea`, root)) {
    if (ctx.node.isSecure(area) || typeof area.value !== "string" || area.value.trim() === "") continue;
    if (best === undefined || charCount(area.value) > charCount(best.value)) best = area;
  }
  return best;
};

// Drops the oldest lines until the text fits, keeping at least one.
const bound = (lines, title, cap) => {
  const budget = Math.max(0, cap - (charCount(title) + 4));
  const cost = (l) => charCount(l) + 1;
  let total = Math.max(0, lines.reduce((sum, l) => sum + cost(l), 0) - 1);
  let start = 0;
  while (lines.length - start > 1 && total > budget) {
    total = Math.max(0, total - cost(lines[start]));
    start += 1;
  }
  return [lines.slice(start), start > 0];
};

export function parse(snapshot, ctx) {
  const area = editorTextArea(snapshot.root, ctx);
  if (!area) return null;
  const parts = titleParts(windowTitleOf(snapshot));
  const title = activeTab(parts);
  // Lines keep their indentation and blank lines stay, so the buffer reads as written.
  const [lines, truncated] = bound(area.value.split("\n"), title, CONTENT_CAP);
  const out = ctx.item(
    { ...snapshot, url: undefined },
    PARSER_ID,
    threadKey(parts, ctx),
    title,
    undefined,
    { kind: "document", title, text: lines.join("\n") },
  );
  out.truncated = out.truncated || truncated;
  return out;
}
