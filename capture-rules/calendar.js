// Apple Calendar and Fantastical. Ported from MaxMi's CalendarParser and FantasticalParser,
// which share one extraction: only an event detail surface (the inspector popover, sheet or
// dialog) is captured, never the sidebar, toolbar or day grid. The event becomes a page with one
// field per line: title, date, all-day flag, location, calendar or organizer, then the
// remaining detail text. Each app keeps its own parser id and thread key prefix.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.iCal", "com.flexibits.fantastical2.mac"] },
};

// Parser id, thread key prefix and app name, by bundle id.
const APPS = {
  "com.apple.ical": { parser: "calendar/v1", prefix: "calendar", source: "Calendar" },
  "com.flexibits.fantastical2.mac": { parser: "fantastical/v1", prefix: "fantastical", source: "Fantastical" },
};
// Rendered characters kept per event.
const CONTENT_CAP = 32000;

// ---- shared with fantastical.js (a rule cannot import another rule) ----------------------

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
const FALSE_VALUES = new Set(["0", "false", "no", "unchecked"]);

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

// MaxMi matched hints as substrings, so "end" also matched every "calendar-name" field and
// took the calendar name as the date when the date field had no hint. "end" skips "calendar".
const hasHint = (metadata, hint) =>
  hint === "end" ? metadata.replace(/calendar/g, "").includes(hint) : metadata.includes(hint);

const firstValue = (fields, hints) => {
  const f = fields.find((field) => hints.some((h) => hasHint(field.metadata, h)));
  return f ? f.value : undefined;
};

const meaningfulWindowTitle = (title, excluding) => {
  const t = (title ?? "").trim();
  if (t === "") return undefined;
  return excluding.some((e) => e.toLowerCase() === t.toLowerCase()) ? undefined : t;
};

// A detail surface is a popover, sheet or dialog, or a node whose metadata names an event,
// detail or popover, that holds at least one event field or a heading that is not chrome.
const isDetailSurface = (n, ctx) => {
  const metadata = metadataOf(n, ctx);
  const surface = SURFACE_ROLES.has(n.role) || ["event", "detail", "popover"].some((h) => metadata.includes(h));
  if (!surface) return false;
  return orderedFields(n, ctx).some(
    (f) =>
      ["event", "title", "summary", "date", "time", "start", "end", "all-day"].some((h) => hasHint(f.metadata, h)) ||
      (f.role === "Heading" && !isChrome(f.value)),
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

// A window with nothing but a toolbar or the calendar sidebar has no event to capture.
const isKnownNonContentSurface = (root, ctx) => {
  const kids = ctx.node.children(root);
  return (
    kids.length === 0 ||
    kids.every((c) => c.role === "Toolbar" || (ctx.node.identifier(c) ?? "").includes("calendar-sidebar"))
  );
};

const isAllDay = (fields) =>
  fields.some((f) => {
    const flagged =
      f.metadata.includes("all-day") || f.metadata.includes("allday") || f.value.toLowerCase().includes("all day");
    return flagged && !FALSE_VALUES.has(f.value.trim().toLowerCase());
  });

// Everything the named fields did not claim, without chrome, checkboxes or repeats.
const remainingValues = (fields, claimed) => {
  const lowerClaimed = claimed.map((c) => c.toLowerCase());
  const seen = new Set();
  const out = [];
  for (const f of fields) {
    if (f.role === "CheckBox") continue;
    const lower = f.value.toLowerCase();
    if (lowerClaimed.includes(lower) || isChrome(f.value) || seen.has(lower)) continue;
    seen.add(lower);
    out.push(f.value);
  }
  return out;
};

const event = (root, windowTitle, appName, ctx) => {
  const fields = orderedFields(root, ctx);
  if (fields.length === 0) return undefined;
  const heading = fields.find((f) => f.role === "Heading" && !isChrome(f.value));
  const title =
    firstValue(fields, ["title", "summary", "event-name"]) ??
    (heading ? heading.value : undefined) ??
    meaningfulWindowTitle(windowTitle, [appName, "Calendar"]);
  if (title === undefined || title === "") return undefined;
  const dated = fields.find((f) => looksLikeDateOrTime(f.value));
  const when = firstValue(fields, ["date", "time", "start", "end"]) ?? (dated ? dated.value : undefined);
  const location = firstValue(fields, ["location", "place"]);
  // Detail views expose no organizer, so the calendar or account name stands in for it.
  const organizer = firstValue(fields, ["organizer", "invitee", "calendar-name", "account"]);
  const claimed = [title, when, location, organizer].filter((v) => v !== undefined);
  return { title, when, allDay: isAllDay(fields), location, organizer, details: remainingValues(fields, claimed) };
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
  const root = detailRoot(snapshot.root, ctx);
  if (!root) {
    return isKnownNonContentSurface(snapshot.root, ctx) ? { refuse: "unmatched-calendar-window" } : null;
  }
  const ev = event(root, snapshot.window_title, app.source, ctx);
  if (!ev) return null;

  const lines = [ev.title];
  if (ev.when !== undefined) lines.push(ev.when);
  if (ev.allDay && !(ev.when ?? "").toLowerCase().includes("all day")) lines.push("All day");
  if (ev.location !== undefined) lines.push(ev.location);
  if (ev.organizer !== undefined) lines.push(ev.organizer);
  lines.push(...ev.details);
  const [kept, truncated] = bound(lines, CONTENT_CAP);

  // MaxMi keyed on title, date and organizer. The date is left out because detail views
  // show it relative to today ("Tomorrow"), which would move the same event to a new thread.
  const parts = [ev.organizer, ev.title].filter((v) => v !== undefined).map((v) => ctx.slug(v));
  const key = parts.filter((p) => p !== "").join("/");
  const threadKey = `${app.prefix}:${key === "" ? "untitled" : key}`;
  const out = ctx.item(snapshot, app.parser, threadKey, ev.title, undefined, ctx.pageFromRows(kept));
  out.truncated = out.truncated || truncated;
  return out;
}
