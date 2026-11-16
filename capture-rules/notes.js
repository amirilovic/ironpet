// Apple Notes. The note body is one text area with a stable identifier, which keeps the note
// list and folder sidebar out of the document.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.Notes"] },
};

// Rendered characters kept per note. The oldest (top) lines go first.
const CONTENT_CAP = 32000;
const BODY_IDENTIFIER = "Note Body Text View";
// Notes appends this to the window title of a shared note.
const SHARED_TITLE_SUFFIX = " — Shared";
// A collaborator line on a shared note ends with this.
const SHARED_HEADER_SUFFIX = "— Shared";
const UNTITLED = "untitled";

const charCount = (s) => [...s].length;

const slug = (s) => s.split(/\s+/).filter(Boolean).join("-").toLowerCase();

const stripSharedSuffix = (title) =>
  (title.endsWith(SHARED_TITLE_SUFFIX) ? title.slice(0, title.length - SHARED_TITLE_SUFFIX.length) : title).trim();

// The first body line is the note title. A blank first line defers to the window title
// (without the shared suffix), then to "untitled".
const noteTitle = (firstLine, windowTitle) => {
  const first = firstLine.trim();
  if (first !== "") return first;
  const fallback = stripSharedSuffix((windowTitle ?? "").trim());
  return fallback === "" ? UNTITLED : fallback;
};

// Drops the oldest lines until the text fits, keeping at least one.
const bound = (lines, title, cap) => {
  const titleCost = charCount(title) + 4;
  const budget = Math.max(0, cap - titleCost);
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
  const body = ctx.find(`//*[identifier="${BODY_IDENTIFIER}"]`, snapshot.root);
  if (!body) return null;
  const raw = body.value;
  if (raw === undefined || raw === null || ctx.node.isSecure(body) || raw.trim() === "") return null;

  const lines = raw.split("\n");
  const first = lines.shift();
  const title = noteTitle(first, snapshot.window_title);
  const rest = lines;
  // A shared note has a "Name — Shared" collaborator line, which is not note text.
  const at = rest.findIndex((l) => l.trim().endsWith(SHARED_HEADER_SUFFIX));
  if (at >= 0) rest.splice(at, 1);
  const [blocks, truncated] = bound(
    rest.filter((l) => l.trim() !== ""),
    title,
    CONTENT_CAP,
  );

  // The window title names the note in the list, so it is the stable identity. The
  // shared suffix comes and goes when the note is shared, so it is not part of the key.
  const stripped = snapshot.window_title !== undefined && snapshot.window_title !== null
    ? stripSharedSuffix(snapshot.window_title)
    : "";
  const keySource = stripped !== "" ? stripped : title;
  const out = ctx.item(
    { ...snapshot, url: undefined },
    "notes/v1",
    `notes:${slug(keySource)}`,
    title,
    undefined,
    { kind: "document", title, text: blocks.join("\n") },
  );
  out.truncated = truncated;
  return out;
}
