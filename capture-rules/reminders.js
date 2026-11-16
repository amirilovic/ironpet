// Apple Reminders. Ported from MaxMi's RemindersParser. A Reminders window is either a list
// of rows, each with its own completion checkbox, or one reminder's detail pane. Every row
// (or the detail) becomes lines of a page: title, due date, list, then the remaining text.
// A window with only the sidebar or toolbar is refused.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.reminders"] },
};

const PARSER = "reminders/v1";
const KEY_PREFIX = "reminders";
// Rendered characters kept per window.
const CONTENT_CAP = 32000;

const READABLE_ROLES = new Set(["StaticText", "TextArea", "TextField", "Heading", "Link", "CheckBox"]);
const SURFACE_ROLES = new Set(["Sheet", "Popover", "Dialog"]);
const CHROME = new Set([
  "calendar", "today", "day", "week", "month", "year", "inbox", "search",
  "reminders", "completed", "flagged", "all", "scheduled", "add list", "settings",
]);
const DATE_TOKENS = [
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  "january", "february", "march", "april", "may", "june", "july", "august",
  "september", "october", "november", "december", "am", "pm", "tomorrow", "today",
];
const TITLE_HINTS = ["title", "name", "task-title", "reminder-title"];
const DUE_HINTS = ["due", "date", "time"];
const LIST_HINTS = ["list", "project", "section"];

const isChrome = (value) => CHROME.has(value.trim().toLowerCase());
const looksLikeDateOrTime = (value) => {
  const lower = value.toLowerCase();
  return DATE_TOKENS.some((t) => lower.includes(t));
};

// Identifier, label and name, lowercased: the text the field hints are matched against.
const metadataOf = (n, ctx) =>
  [ctx.node.identifier(n), ctx.node.label(n), n.name]
    .filter((v) => typeof v === "string")
    .join(" ")
    .toLowerCase();

// The value, or the name when the value is missing or blank (live trees report "").
const readableText = (n) => {
  for (const raw of [n.value, n.name]) {
    if (typeof raw !== "string") continue;
    const t = raw.trim();
    if (t !== "") return t;
  }
  return undefined;
};

// Readable fields under `root` in (y, x) order.
const orderedFields = (root, ctx) => {
  const out = [];
  const visit = (n) => {
    if (n.hidden || ctx.node.isSecure(n)) return;
    if (READABLE_ROLES.has(n.role)) {
      const value = readableText(n);
      if (value !== undefined) {
        out.push({
          role: n.role,
          value,
          metadata: metadataOf(n, ctx),
          y: n.frame ? n.frame.y : 0,
          x: n.frame ? n.frame.x : 0,
          i: out.length,
        });
      }
    }
    for (const c of ctx.node.children(n)) visit(c);
  };
  visit(root);
  return out.sort((a, b) => (a.y !== b.y ? a.y - b.y : a.x !== b.x ? a.x - b.x : a.i - b.i));
};

const firstValue = (fields, hints) => {
  const f = fields.find((field) => hints.some((h) => field.metadata.includes(h)));
  return f ? f.value : undefined;
};

// Everything the named fields did not claim, as note lines. The checkbox is status, not text.
const notes = (fields, claimed) =>
  fields
    .filter((f) => f.role !== "CheckBox" && !claimed.includes(f.value) && !isChrome(f.value))
    .map((f) => f.value);

const hasCheckBox = (n, ctx) => ctx.find("//CheckBox", n) !== undefined;

const taskRows = (root, ctx) => ctx.findAll("//Row", root).filter((r) => hasCheckBox(r, ctx));

const itemFromRow = (row, ctx) => {
  const fields = orderedFields(row, ctx);
  const text = fields.find((f) => f.role === "StaticText");
  const title = firstValue(fields, TITLE_HINTS) ?? (text ? text.value : undefined);
  if (title === undefined || title === "") return undefined;
  const due = firstValue(fields, DUE_HINTS);
  const list = firstValue(fields, LIST_HINTS);
  return { title, due, list, notes: notes(fields, [title, due, list]) };
};

// A popover, sheet or dialog, or a node named like a task, reminder or detail, that holds a
// reminder field or a heading that is not chrome.
const isDetailSurface = (n, ctx) => {
  const metadata = metadataOf(n, ctx);
  const surface = SURFACE_ROLES.has(n.role) || ["task", "reminder", "detail"].some((h) => metadata.includes(h));
  if (!surface) return false;
  const hints = [...TITLE_HINTS, ...DUE_HINTS, ...LIST_HINTS, "completed"];
  return orderedFields(n, ctx).some(
    (f) => hints.some((h) => f.metadata.includes(h)) || (f.role === "Heading" && !isChrome(f.value)),
  );
};

const detailRoot = (n, ctx) => {
  if (isDetailSurface(n, ctx)) return n;
  for (const c of ctx.node.children(n)) {
    const found = detailRoot(c, ctx);
    if (found) return found;
  }
  return undefined;
};

const detailItem = (root, ctx) => {
  const fields = orderedFields(root, ctx);
  if (fields.length === 0) return undefined;
  const heading = fields.find((f) => f.role === "Heading" && !isChrome(f.value));
  const title = firstValue(fields, TITLE_HINTS) ?? (heading ? heading.value : undefined);
  if (title === undefined || title === "") return undefined;
  const dated = fields.find((f) => looksLikeDateOrTime(f.value));
  const due = firstValue(fields, DUE_HINTS) ?? (dated ? dated.value : undefined);
  const list = firstValue(fields, LIST_HINTS);
  return { title, due, list, notes: notes(fields, [title, due, list]) };
};

const isKnownNonContentSurface = (root, ctx) => {
  const kids = ctx.node.children(root);
  return (
    kids.length === 0 ||
    kids.every((c) => c.role === "Toolbar" || (ctx.node.identifier(c) ?? "").includes("reminders-sidebar"))
  );
};

const linesOf = (t) => {
  const lines = [t.title];
  if (t.due !== undefined) lines.push(t.due);
  if (t.list !== undefined) lines.push(t.list);
  lines.push(...t.notes);
  return lines;
};

// Drops the last lines until the text fits, keeping at least the first.
const bound = (lines, cap) => {
  const out = lines.slice();
  let total = out.reduce((sum, l) => sum + [...l].length + 1, 0) - 1;
  while (out.length > 1 && total > cap) total -= [...out.pop()].length + 1;
  return [out, out.length < lines.length];
};

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const rows = taskRows(root, ctx);
  const detailAt = detailRoot(root, ctx);
  if (rows.length === 0 && !detailAt) {
    return isKnownNonContentSurface(root, ctx) ? { refuse: "unmatched-reminders-window" } : null;
  }
  const detail = detailAt ? detailItem(detailAt, ctx) : undefined;

  let items;
  if (rows.length > 0) {
    items = ctx
      .sortedByVisualOrder(rows, root.frame)
      .map((r) => itemFromRow(r, ctx))
      .filter((t) => t !== undefined);
  } else {
    items = detail ? [detail] : [];
  }
  // The selected reminder's detail pane owns the thread. Without one, the first visible row does.
  const identity = detail ?? items[0];
  if (!identity) return null;

  const [kept, truncated] = bound(items.flatMap(linesOf), CONTENT_CAP);
  const parts = [identity.list, identity.title].filter((v) => v !== undefined).map((v) => ctx.slug(v));
  const key = parts.filter((p) => p !== "").join("/");
  const threadKey = `${KEY_PREFIX}:${key === "" ? "untitled" : key}`;
  const out = ctx.item(snapshot, PARSER, threadKey, identity.title, undefined, ctx.pageFromRows(kept));
  out.truncated = out.truncated || truncated;
  return out;
}
