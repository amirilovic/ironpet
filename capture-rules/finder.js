// Finder. A Finder window is the page shape the generic extractor handles: a source list that
// becomes the sidebar region, a file table whose rows join into one line each, and a toolbar
// whose copy-progress text stays out of the listing. This rule adds the identity (the folder
// path) and keeps the toolbar region, which the generic rule drops for native windows. Ported
// from MaxMi's FinderParser.
//
// Rules cannot import each other, so the region walk below is a trimmed copy of the one in
// generic.js: no web area, no focus anchor and no per-region shares, since Finder has none of
// those concerns.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.finder"] },
};

const PARSER_ID = "finder/v1";
// Rendered characters kept per window. Chrome regions shed blocks before the listing does.
const CONTENT_CAP = 32000;
const MAX_NODES = 50000;
const MAX_DEPTH = 256;

const AX_PREFIX = "AX";
const REGION_ORDER = ["main", "dialog", "sidebar", "navigation", "toolbar", "banner", "footer"];
const SKIP_ROLES = ["ScrollBar", "Splitter", "GrowArea", "Column"];
// The window's traffic-light buttons. The zoom button's label is a VoiceOver hint, not content.
const WINDOW_BUTTON_SUBROLES = ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"];
const INPUT_ROLES = ["TextField", "TextArea", "SearchField", "ComboBox"];
const LABEL_ROLES = ["Button", "Link", "MenuItem", "CheckBox", "RadioButton", "Image"];
const SIDEBAR_NAME_HINTS = ["sidebar", "source list"];
const SIDEBAR_LIST_ROLES = ["Outline", "List", "Table"];
const SIDEBAR_MAX_WIDTH_SHARE = 0.35;
const SIDEBAR_LEFT_EDGE_SHARE = 0.05;

const charCount = (s) => [...s].length;
const children = (n) => n.children || [];
const attr = (n, key) => (n.attrs && n.attrs[key] !== undefined ? n.attrs[key] : undefined);
const nonBlank = (v) => typeof v === "string" && v.trim() !== "";

// ---- identity -------------------------------------------------------------------------------

// The window title, or the root window's name when the snapshot carries none.
const windowTitleOf = (snapshot) => {
  for (const raw of [snapshot.window_title, snapshot.root.role === "Window" ? snapshot.root.name : undefined]) {
    if (nonBlank(raw)) return raw.trim();
  }
  return undefined;
};

// The path of a file URL ("file:///Users/ada/x/" gives "/Users/ada/x"). Any other string is
// returned as it is.
const fileUrlPath = (raw) => {
  const m = /^file:\/\/[^/]*(\/.*)?$/i.exec(raw);
  if (!m) return raw;
  let path = m[1] ?? "/";
  try {
    path = decodeURIComponent(path);
  } catch (e) {
    // A malformed escape keeps the encoded form.
  }
  return path.length > 1 ? path.replace(/\/+$/, "") || "/" : path;
};

// A file reference URL ("file:///.file/id=6571367.3012") names one file by inode, not a path.
const isFileReference = (url) => /^file:\/\/[^/]*\/\.file\/id=/i.test(url);

// The folder's path from the window's document URL, which Finder puts on the window in list
// view and on the browser below it in column view. Rows are skipped: in a live list view every
// row's name field carries the file reference URL of that file, not of the folder.
const folderPath = (snapshot) => {
  let raw = nonBlank(snapshot.url) ? snapshot.url : undefined;
  if (raw === undefined) {
    const stack = [snapshot.root];
    while (stack.length > 0 && raw === undefined) {
      const n = stack.pop();
      if (n.role === "Row" || n.role === "TableRow") continue;
      const url = attr(n, "url");
      if (nonBlank(url) && !isFileReference(url.trim())) raw = url;
      const kids = children(n);
      for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
    }
  }
  return raw === undefined ? undefined : fileUrlPath(raw.trim());
};

// The lowercased path, then the window title (only a folder name) as the last resort.
const threadKey = (path, windowTitle, ctx) => {
  if (path !== undefined && path !== "") return `finder:${path.toLowerCase()}`;
  return windowTitle === undefined ? "finder:unknown" : `finder:${ctx.slug(windowTitle)}`;
};

// A source list is an outline and a file listing is a table (or an outline in list view). A
// toolbar alone is common to unrelated utility windows.
const hasExpectedShape = (root, ctx) =>
  ctx.find("//Outline", root) !== undefined || ctx.find("//Table", root) !== undefined;

// Empty and toolbar-only windows carry no page content.
const isNonContentSurface = (root) => children(root).every((c) => c.role === "Toolbar");

// ---- blocks ---------------------------------------------------------------------------------

const minX = (r) => r.x;
const minY = (r) => r.y;
const maxX = (r) => r.x + r.width;
const maxY = (r) => r.y + r.height;
const byPosition = (a, b) => (a.y < b.y ? -1 : a.y > b.y ? 1 : a.x < b.x ? -1 : a.x > b.x ? 1 : a.order - b.order);
const intersects = (a, b) => minX(a) < maxX(b) && minX(b) < maxX(a) && minY(a) < maxY(b) && minY(b) < maxY(a);

const firstNonEmpty = (values) => {
  for (const v of values) if (nonBlank(v)) return v.trim();
  return "";
};
// A control's name, then its description, then its value.
const readableLabel = (n) => firstNonEmpty([n.name, attr(n, "label"), n.value]);

const blockFor = (node, listDepth, ctx) => {
  const role = node.role;
  if (role === "Heading") {
    const text = ctx.textOf(node);
    if (text === undefined) return null;
    const level = Math.min(Math.max(ctx.node.headingLevel(node) ?? 2, 1), 6);
    return { kind: "heading", level, text };
  }
  if (role === "StaticText" || role === "Paragraph") {
    const text = ctx.textOf(node);
    return text === undefined ? null : { kind: "paragraph", text };
  }
  if (INPUT_ROLES.includes(role)) {
    const text = (node.value ?? "").trim();
    const placeholder = attr(node, "placeholder");
    if (text === "" && placeholder === undefined) return null;
    return { kind: "input", placeholder, text };
  }
  if (role === "ListItem" || role === "TreeItem") {
    const text = ctx.orderedDescendantText(node, ["StaticText", "Heading"]).join(" ");
    return text === "" ? null : { kind: "list_item", depth: Math.max(listDepth - 1, 0), text };
  }
  if (role === "Row" || role === "TableRow") {
    // The name cell of a row being renamed is an editable field, so text entry roles count.
    const cells = ctx.rowCells(node);
    if (cells.length === 0) return null;
    return { kind: "table_row", cells, selected: !!node.selected, text: cells.join(" ") };
  }
  if (LABEL_ROLES.includes(role)) {
    const text = readableLabel(node);
    return text === "" ? null : { kind: "label", text };
  }
  return null;
};

// The markdown-like form used for sizing, so a block never costs less than it prints.
const rendered = (b) => {
  switch (b.kind) {
    case "heading":
      return `${"#".repeat(b.level)} ${b.text}`;
    case "list_item":
      return `${"  ".repeat(b.depth)}- ${b.text}`;
    case "table_row":
      return `${b.selected ? "* " : ""}${b.cells.join(" | ")}`;
    case "input":
      return b.text === "" ? `«${b.placeholder ?? "empty field"}»` : b.text;
    default:
      return b.text;
  }
};

// ---- regions --------------------------------------------------------------------------------

const containsListLike = (node) => {
  const stack = [node];
  while (stack.length > 0) {
    const n = stack.pop();
    if (SIDEBAR_LIST_ROLES.includes(n.role)) return true;
    for (const c of children(n)) stack.push(c);
  }
  return false;
};

const isSplitGroupSidebar = (node, window) => {
  const f = node.frame;
  if (!window || !f) return false;
  if (window.width <= 0 || f.width >= SIDEBAR_MAX_WIDTH_SHARE * window.width) return false;
  // Window-relative, because frames are global screen coordinates.
  if (minX(f) - minX(window) > SIDEBAR_LEFT_EDGE_SHARE * window.width) return false;
  return containsListLike(node);
};

const classifyRegion = (node, window, parentIsSplitGroup) => {
  if (node.role === "Sheet" || node.role === "Dialog" || node.role === "Popover") return "dialog";
  const raw = attr(node, "subrole");
  const subrole = raw !== undefined && raw.startsWith(AX_PREFIX) ? raw.slice(AX_PREFIX.length) : raw;
  if (subrole === "Dialog" || subrole === "SystemDialog") return "dialog";
  if (node.role === "Toolbar") return "toolbar";
  if (subrole === "LandmarkMain") return "main";
  if (subrole === "LandmarkNavigation") return "navigation";
  if (subrole === "LandmarkComplementary") return "sidebar";
  if (subrole === "LandmarkBanner") return "banner";
  if (subrole === "LandmarkContentInfo") return "footer";
  for (const key of ["identifier", "label"]) {
    const v = attr(node, key);
    if (v === undefined) continue;
    const lower = v.toLowerCase();
    if (SIDEBAR_NAME_HINTS.some((hint) => lower.includes(hint))) return "sidebar";
  }
  if (parentIsSplitGroup && isSplitGroupSidebar(node, window)) return "sidebar";
  return null;
};

// Walks the window into region claims. Each claim holds its blocks with their positions.
const walk = (root, ctx) => {
  const window = root.frame;
  const claims = [{ kind: "main", y: window ? minY(window) : 0, x: window ? minX(window) : 0, order: 0, entries: [] }];
  let visited = 0;
  let order = 0;
  let truncated = false;
  // Five slots per entry: node, claim, parent is a split group, list depth, depth. An explicit
  // stack, because QuickJS has a small native stack.
  const stack = [root, 0, false, 0, 0];
  while (stack.length > 0) {
    const depth = stack.pop();
    const listDepth = stack.pop();
    const parentIsSplitGroup = stack.pop();
    const claim = stack.pop();
    const node = stack.pop();
    if (visited >= MAX_NODES || depth > MAX_DEPTH) {
      truncated = true;
      continue;
    }
    visited += 1;
    if (ctx.node.isSecure(node) || ctx.node.isMenuRole(node.role) || node.hidden) continue;
    if (SKIP_ROLES.includes(node.role) || WINDOW_BUTTON_SUBROLES.includes(attr(node, "subrole"))) continue;
    const f = node.frame;
    if (f && (f.width === 0 || f.height === 0)) continue;
    if (window && f && window.width > 0 && window.height > 0 && !intersects(window, f)) continue;

    let current = claim;
    const kind = classifyRegion(node, window, parentIsSplitGroup);
    if (kind !== null) {
      current = claims.length;
      claims.push({ kind, y: f ? minY(f) : 0, x: f ? minX(f) : 0, order: current, entries: [] });
    }
    const block = blockFor(node, listDepth, ctx);
    if (block !== null) {
      claims[current].entries.push({ y: f ? minY(f) : 0, x: f ? minX(f) : 0, order, block });
      order += 1;
      // A node that emits text ends the descent.
      continue;
    }
    const childDepth = node.role === "List" || node.role === "Outline" ? listDepth + 1 : listDepth;
    const childInSplit = node.role === "SplitGroup";
    const kids = children(node);
    for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i], current, childInSplit, childDepth, depth + 1);
  }
  return { claims, truncated };
};

// Regions in REGION_ORDER. Same-kind claims concatenate in (y, x) order, blocks are ordered
// visually within a claim, and a repeat of the same shape and text is dropped.
const assemble = (claims) => {
  const regions = [];
  for (const kind of REGION_ORDER) {
    const matching = claims.filter((c) => c.kind === kind && c.entries.length > 0).sort(byPosition);
    const seen = new Set();
    const blocks = [];
    for (const claim of matching) {
      for (const entry of claim.entries.slice().sort(byPosition)) {
        const key = `${entry.block.kind}|${entry.block.text}`;
        if (seen.has(key)) continue;
        seen.add(key);
        blocks.push(entry.block);
      }
    }
    if (blocks.length > 0) regions.push({ kind, blocks });
  }
  return regions;
};

// Drops blocks from the end of the chrome regions (last region first), then from the end of
// main, until the rendered page fits. One block always stays.
const bound = (regions, cap) => {
  const size = () => {
    const all = regions.flatMap((r) => r.blocks);
    return all.reduce((sum, b) => sum + charCount(rendered(b)), 0) + Math.max(all.length - 1, 0);
  };
  const count = () => regions.reduce((sum, r) => sum + r.blocks.length, 0);
  let truncated = false;
  const order = REGION_ORDER.filter((k) => k !== "main").reverse().concat(["main"]);
  for (const kind of order) {
    const region = regions.find((r) => r.kind === kind);
    if (!region) continue;
    while (size() > cap && region.blocks.length > 0 && count() > 1) {
      region.blocks.pop();
      truncated = true;
    }
  }
  return [regions.filter((r) => r.blocks.length > 0), truncated];
};

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  if (!hasExpectedShape(root, ctx)) {
    if (isNonContentSurface(root)) return { refuse: "unmatched-finder-window" };
    // Get Info, Go to Folder and other panels fall through to the generic rule.
    return null;
  }
  const walked = walk(root, ctx);
  const [regions, cut] = bound(assemble(walked.claims), CONTENT_CAP);
  const text = regions
    .flatMap((r) => r.blocks)
    .map((b) => b.text)
    .filter((t) => t !== "")
    .join("\n");
  if (text.trim() === "") return null;

  const windowTitle = windowTitleOf(snapshot);
  const path = folderPath(snapshot);
  const out = ctx.item(snapshot, PARSER_ID, threadKey(path, windowTitle, ctx), windowTitle ?? path ?? "Finder", undefined, {
    kind: "page",
    title: "",
    text,
  });
  out.truncated = out.truncated || walked.truncated || cut;
  return out;
}
