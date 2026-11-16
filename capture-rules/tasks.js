// Microsoft To Do, Todoist, OmniFocus and Toggl. Ported from MaxMi's shared task extraction
// (MicrosoftToDoParser, TodoistParser, OmniFocusParser, TogglParser): the task detail pane, or
// the whole window when there is none, becomes one task. The task is a page with one field per
// line: title, due date, project, then the remaining detail text. Each app keeps its own parser
// id and thread key prefix. Apple Reminders has its own rule, reminders.js.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.microsoft.to-do-mac", "com.todoist.mac.Todoist", "com.omnigroup.OmniFocus3", "com.omnigroup.OmniFocus4", "com.toggl.toggldesktop"] },
};

// Parser id, thread key prefix and app name, by bundle id.
const APPS = {
  "com.microsoft.to-do-mac": { parser: "microsoft-todo/v1", prefix: "microsoft-todo", source: "Microsoft To Do" },
  "com.todoist.mac.todoist": { parser: "todoist/v1", prefix: "todoist", source: "Todoist" },
  "com.omnigroup.omnifocus3": { parser: "omnifocus/v1", prefix: "omnifocus", source: "OmniFocus" },
  "com.omnigroup.omnifocus4": { parser: "omnifocus/v1", prefix: "omnifocus", source: "OmniFocus" },
  "com.toggl.toggldesktop": { parser: "toggl/v1", prefix: "toggl", source: "Toggl" },
};
// Rendered characters kept per task.
const CONTENT_CAP = 32000;

// ---- extraction 
const READABLE_ROLES = new Set(["StaticText", "TextArea", "TextField", "Heading", "Link", "CheckBox"]);
const SURFACE_ROLES = new Set(["Sheet", "Popover", "Dialog"]);
const DETAIL_HINTS = ["task", "reminder", "detail"];
const CHROME = new Set([
  "calendar", "today", "day", "week", "month", "year", "inbox", "search",
  "reminders", "completed", "flagged", "all", "scheduled", "add list", "settings",
]);
const DATE_TOKENS = [
  "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
  "january", "february", "march", "april", "may", "june", "july", "august",
  "september", "october", "november", "december", "am", "pm", "tomorrow", "today",
];

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

const meaningfulWindowTitle = (title, excluding) => {
  const t = (title ?? "").trim();
  if (t === "") return undefined;
  return excluding.some((e) => e.toLowerCase() === t.toLowerCase()) ? undefined : t;
};

const isPreferred = (n, ctx) => {
  if (SURFACE_ROLES.has(n.role)) return true;
  const metadata = metadataOf(n, ctx);
  return DETAIL_HINTS.some((h) => metadata.includes(h));
};

// The first popover, sheet, dialog or node named like a task detail, depth first; the root
// when there is none.
const preferredDetailRoot = (n, ctx) => {
  if (isPreferred(n, ctx)) return n;
  for (const c of ctx.node.children(n)) {
    const found = preferredDetailRoot(c, ctx);
    if (found !== c || isPreferred(c, ctx)) return found;
  }
  return n;
};

// Everything the named fields did not claim, without chrome or repeats.
const remainingValues = (fields, claimed) => {
  const lowerClaimed = claimed.map((c) => c.toLowerCase());
  const seen = new Set();
  const out = [];
  for (const f of fields) {
    const lower = f.value.toLowerCase();
    if (lowerClaimed.includes(lower) || isChrome(f.value) || seen.has(lower)) continue;
    seen.add(lower);
    out.push(f.value);
  }
  return out;
};

const task = (root, windowTitle, appName, ctx) => {
  const fields = orderedFields(root, ctx);
  if (fields.length === 0) return undefined;
  const heading = fields.find((f) => f.role === "Heading" && !isChrome(f.value));
  const title =
    firstValue(fields, ["title", "name", "task-title", "reminder-title"]) ??
    (heading ? heading.value : undefined) ??
    meaningfulWindowTitle(windowTitle, [appName, "Reminders"]);
  if (title === undefined || title === "") return undefined;
  const dated = fields.find((f) => looksLikeDateOrTime(f.value));
  const due = firstValue(fields, ["due", "date", "time"]) ?? (dated ? dated.value : undefined);
  const project = firstValue(fields, ["list", "project", "section"]);
  // The completion checkbox is status, not text. lookback pages carry no status line.
  const status = fields.find((f) => f.role === "CheckBox" || f.metadata.includes("completed"));
  const claimed = [title, due, project, status ? status.value : undefined].filter((v) => v !== undefined);
  return { title, due, project, details: remainingValues(fields, claimed) };
};

// Drops the last lines until the text fits, keeping at least the title.
const bound = (lines, cap) => {
  const out = lines.slice();
  let total = out.reduce((sum, l) => sum + [...l].length + 1, 0) - 1;
  while (out.length > 1 && total > cap) total -= [...out.pop()].length + 1;
  return [out, out.length < lines.length];
};

export function parse(snapshot, ctx) {
  const app = APPS[snapshot.app.bundle_id.toLowerCase()];
  if (app === undefined) return null;
  const root = preferredDetailRoot(snapshot.root, ctx);
  const t = task(root, snapshot.window_title, app.source, ctx);
  if (!t) return null;

  const lines = [t.title];
  if (t.due !== undefined) lines.push(t.due);
  if (t.project !== undefined) lines.push(t.project);
  lines.push(...t.details);
  const [kept, truncated] = bound(lines, CONTENT_CAP);

  // MaxMi keyed a task on its title and project.
  const parts = [t.project, t.title].filter((v) => v !== undefined).map((v) => ctx.slug(v));
  const key = parts.filter((p) => p !== "").join("/");
  const threadKey = `${app.prefix}:${key === "" ? "untitled" : key}`;
  const out = ctx.item(snapshot, app.parser, threadKey, t.title, undefined, ctx.pageFromRows(kept));
  out.truncated = out.truncated || truncated;
  return out;
}
