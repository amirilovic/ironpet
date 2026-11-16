// The fallback parser for any window, and the page extractor behind it.
//
// The extractor walks a tree and emits typed blocks. Landmark roles and other cues sort them
// into regions (main, dialog, sidebar and so on), and a character budget trims whole blocks.
// The parser flattens the regions into one text with one block per line.
//
// Secure fields are never read, menu and hidden subtrees are skipped, and a node budget
// bounds the walk of a very large tree.
export const meta = { api: 1, kind: "parser", match: { fallback: true } };

const PARSER_ID = "generic/v1";

// Landmark and dialog subroles carry the platform prefix (`AXLandmarkMain`).
const AX_PREFIX = "AX";

// The kinds of region, in the order their text is emitted.
const REGION_ORDER = ["main", "dialog", "sidebar", "navigation", "toolbar", "banner", "footer"];

const DEFAULT_OPTIONS = {
  // Rendered characters across all regions.
  total_budget: 8000,
  main_share: 0.7,
  dialog_share: 0.15,
  rest_share: 0.15,
  // Nodes visited before the walk stops and the page is marked truncated.
  max_nodes: 50000,
  // Tree depth before the walk stops. Guards the stack against a pathological tree.
  max_depth: 256,
  // Skip nodes whose frame lies outside the window frame. A web area is never filtered,
  // because the page is longer than the window.
  visible_only: true,
};

// Skipped with their subtree. A column republishes the cells its rows already emitted.
const SKIP_ROLES = ["ScrollBar", "Splitter", "GrowArea", "Column"];
const INPUT_ROLES = ["TextField", "TextArea", "SearchField", "ComboBox"];
const LABEL_ROLES = ["Button", "Link", "MenuItem", "CheckBox", "RadioButton", "Image"];
const SIDEBAR_NAME_HINTS = ["sidebar", "source list"];
const SIDEBAR_LIST_ROLES = ["Outline", "List", "Table"];
const SIDEBAR_MAX_WIDTH_SHARE = 0.35;
const SIDEBAR_LEFT_EDGE_SHARE = 0.05;

// ---- small helpers ---------------------------------------------------------------------------

// Rust's str::trim: Unicode White_Space (includes U+0085, excludes U+FEFF, unlike JS trim).
const WS = "\\t\\n\\v\\f\\r \\u0085\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000";
const TRIM_RE = new RegExp(`^[${WS}]+|[${WS}]+$`, "gu");
const WS_SPLIT_RE = new RegExp(`[${WS}]+`, "u");
const trim = (s) => s.replace(TRIM_RE, "");
const charCount = (s) => [...s].length;

const children = (n) => n.children || [];
const attr = (n, key) => (n.attrs && n.attrs[key] !== undefined ? n.attrs[key] : undefined);
const hasText = (v) => v !== undefined && v !== null;

const isMenuRole = (role) =>
  role === "Menu" || role === "MenuBar" || role === "MenuBarItem" || role === "MenuItem" || role === "MenuButton";

const isSecure = (n) => {
  if (n.role === "SecureTextField") return true;
  const s = attr(n, "subrole");
  return s !== undefined && s.toLowerCase().includes("secure");
};

// Rust's `str::parse::<u8>`: optional "+", digits, at most 255.
const headingLevel = (n) => {
  const v = attr(n, "heading_level");
  if (v === undefined || !/^\+?[0-9]+$/.test(v)) return undefined;
  const num = Number(v);
  return num <= 255 ? num : undefined;
};

const minX = (r) => r.x;
const minY = (r) => r.y;
const maxX = (r) => r.x + r.width;
const maxY = (r) => r.y + r.height;

// f64::total_cmp for finite values: -0 sorts before +0.
const cmpF64 = (a, b) => {
  if (a < b) return -1;
  if (a > b) return 1;
  if (a === 0 && b === 0) return (Object.is(a, -0) ? 0 : 1) - (Object.is(b, -0) ? 0 : 1);
  return 0;
};
const byPosition = (a, b) => cmpF64(a.y, b.y) || cmpF64(a.x, b.x) || a.order - b.order;

const intersects = (a, b) =>
  minX(a) < maxX(b) && minX(b) < maxX(a) && minY(a) < maxY(b) && minY(b) < maxY(a);

// Pre-order visit without recursion, so a pathological tree cannot overflow the stack.
const preorder = (root, fn) => {
  const stack = [root];
  while (stack.length > 0) {
    const n = stack.pop();
    fn(n);
    const kids = children(n);
    for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
  }
};

// The first non-empty of the given values, trimmed.
const firstNonEmpty = (values) => {
  for (const v of values) {
    if (!hasText(v)) continue;
    const t = trim(v);
    if (t !== "") return t;
  }
  return "";
};

// The first non-empty of value, name and label, trimmed.
const readableText = (n) => firstNonEmpty([n.value, n.name, attr(n, "label")]);

// A control's name, then its description, then its value.
const readableLabel = (n) => firstNonEmpty([n.name, attr(n, "label"), n.value]);

// Descendant text in visual order with adjacent duplicates dropped. A matching node with
// text is not descended into, and secure, hidden and menu subtrees are never read.
const orderedDescendantText = (node, roles) => {
  const found = [];
  const stack = [];
  const kids = children(node);
  for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i]);
  while (stack.length > 0) {
    const n = stack.pop();
    if (isMenuRole(n.role) || n.hidden || isSecure(n)) continue;
    if (roles.includes(n.role)) {
      const text = readableText(n);
      if (text !== "") {
        found.push({
          y: n.frame ? minY(n.frame) : 0,
          x: n.frame ? minX(n.frame) : 0,
          order: found.length,
          text,
        });
        continue;
      }
    }
    const sub = children(n);
    for (let i = sub.length - 1; i >= 0; i--) stack.push(sub[i]);
  }
  found.sort(byPosition);
  const out = [];
  for (const f of found) if (out.length === 0 || out[out.length - 1] !== f.text) out.push(f.text);
  return out;
};

// ---- blocks ----------------------------------------------------------------------------------

// A block is { kind, text, ... }: kind is one of heading (level), paragraph, list_item
// (depth), label, table_row (cells, selected) and input (placeholder, undefined when absent).
const blockFor = (node, listDepth) => {
  const role = node.role;
  if (role === "Heading") {
    const text = readableText(node);
    if (text === "") return null;
    const level = Math.min(Math.max(headingLevel(node) ?? 2, 1), 6);
    return { kind: "heading", level, text };
  }
  if (role === "StaticText" || role === "Paragraph") {
    const text = readableText(node);
    if (text === "") return null;
    return { kind: "paragraph", text };
  }
  if (INPUT_ROLES.includes(role)) {
    const text = trim(node.value ?? "");
    const placeholder = attr(node, "placeholder");
    if (text === "" && placeholder === undefined) return null;
    return { kind: "input", placeholder, text };
  }
  if (role === "ListItem" || role === "TreeItem") {
    const text = orderedDescendantText(node, ["StaticText", "Heading"]).join(" ");
    if (text === "") return null;
    return { kind: "list_item", depth: Math.max(listDepth - 1, 0), text };
  }
  if (role === "Row" || role === "TableRow") {
    // Finder's name column is an editable field, so text entry roles count as cells.
    const cells = orderedDescendantText(node, ["Cell", "StaticText", "TextField", "TextArea"]);
    if (cells.length === 0) return null;
    return { kind: "table_row", cells, selected: !!node.selected, text: cells.join(" ") };
  }
  if (LABEL_ROLES.includes(role)) {
    const text = readableLabel(node);
    if (text === "") return null;
    return { kind: "label", text };
  }
  return null;
};

// The markdown-like form used for sizing. Budgets are measured on it so a block never costs
// less than it prints.
const rendered = (b) => {
  switch (b.kind) {
    case "heading":
      return `${"#".repeat(Math.min(Math.max(b.level, 1), 6))} ${b.text}`;
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

// Dedup key per region. Text alone would collide across shapes (a paragraph and a table row
// with the same joined text), so the shape tag is part of it.
const dedupKey = (b) => `${b.kind}|${b.text}`;

// ---- regions ---------------------------------------------------------------------------------

const containsListLike = (node) => {
  let found = false;
  const stack = [node];
  while (stack.length > 0 && !found) {
    const n = stack.pop();
    if (SIDEBAR_LIST_ROLES.includes(n.role)) found = true;
    else for (const c of children(n)) stack.push(c);
  }
  return found;
};

const isSplitGroupSidebar = (node, window) => {
  const f = node.frame;
  if (!window || !f) return false;
  if (window.width <= 0 || f.width >= SIDEBAR_MAX_WIDTH_SHARE * window.width) return false;
  // Window-relative, because frames are global screen coordinates.
  if (minX(f) - minX(window) > SIDEBAR_LEFT_EDGE_SHARE * window.width) return false;
  return containsListLike(node);
};

// Which region a node claims for its whole subtree, if any. null inherits the enclosing
// region, which defaults to main.
const classifyRegion = (node, window, parentIsSplitGroup) => {
  if (node.role === "Sheet" || node.role === "Dialog" || node.role === "Popover") return "dialog";
  const raw = attr(node, "subrole");
  const subrole = raw !== undefined && raw.startsWith(AX_PREFIX) ? raw.slice(AX_PREFIX.length) : raw;
  if (subrole === "Dialog" || subrole === "SystemDialog") return "dialog";
  if (node.role === "Toolbar") return "toolbar";
  switch (subrole) {
    case "LandmarkMain":
      return "main";
    case "LandmarkNavigation":
      return "navigation";
    case "LandmarkComplementary":
      return "sidebar";
    case "LandmarkBanner":
      return "banner";
    case "LandmarkContentInfo":
      return "footer";
    default:
  }
  // Each name is tested alone: joining them could invent a hint neither carries.
  const names = node.attrs;
  if (names !== undefined) {
    for (const key of ["identifier", "label"]) {
      const v = names[key];
      if (v === undefined) continue;
      const lower = v.toLowerCase();
      for (const hint of SIDEBAR_NAME_HINTS) if (lower.includes(hint)) return "sidebar";
    }
  }
  if (parentIsSplitGroup && isSplitGroupSidebar(node, window)) return "sidebar";
  return null;
};

// The deepest focused node under `roots`, ignoring menus. The first of equal depth wins.
const deepestFocused = (roots) => {
  let best = null;
  for (const root of roots) {
    const stack = [[root, 0]];
    while (stack.length > 0) {
      const [n, depth] = stack.pop();
      if (isMenuRole(n.role)) continue;
      if (n.focused && (best === null || depth > best[0])) best = [depth, n];
      const kids = children(n);
      for (let i = kids.length - 1; i >= 0; i--) stack.push([kids[i], depth + 1]);
    }
  }
  return best === null ? null : best[1];
};

class Walker {
  constructor(window, options, skipToolbars, focus) {
    this.window = window;
    this.options = options;
    this.skipToolbars = skipToolbars;
    this.focus = focus;
    this.claims = [
      {
        kind: "main",
        y: window ? minY(window) : 0,
        x: window ? minX(window) : 0,
        order: 0,
        entries: [],
      },
    ];
    this.order = 0;
    // [claim order, entry order] of the block the focused node emitted into a main region.
    this.anchor = null;
    this.visited = 0;
    this.truncated = false;
  }

  isOffscreen(node) {
    if (!this.options.visible_only) return false;
    const w = this.window;
    const f = node.frame;
    if (w && f && w.width > 0 && w.height > 0) return !intersects(w, f);
    return false;
  }

  // Pre-order walk with an explicit stack: QuickJS has a small native stack, so recursing
  // once per tree level would overflow on trees the depth budget still allows.
  walk(root) {
    // Five slots per entry: node, claim, parent is a split group, list depth, depth.
    const stack = [root, 0, false, 0, 0];
    while (stack.length > 0) {
      const depth = stack.pop();
      const listDepth = stack.pop();
      const parentIsSplitGroup = stack.pop();
      const claim = stack.pop();
      const node = stack.pop();
      if (this.visited >= this.options.max_nodes || depth > this.options.max_depth) {
        this.truncated = true;
        continue;
      }
      this.visited += 1;
      // Secure first and at any role: its value and its subtree are never read.
      if (isSecure(node) || isMenuRole(node.role) || node.hidden) continue;
      if (SKIP_ROLES.includes(node.role) || (this.skipToolbars && node.role === "Toolbar")) continue;
      // A zero-size frame means nothing under here is on screen. No frame means unknown.
      if (node.frame && (node.frame.width === 0 || node.frame.height === 0)) continue;
      if (this.isOffscreen(node)) continue;

      let current = claim;
      const kind = classifyRegion(node, this.window, parentIsSplitGroup);
      if (kind !== null) {
        const order = this.claims.length;
        this.claims.push({
          kind,
          y: node.frame ? minY(node.frame) : 0,
          x: node.frame ? minX(node.frame) : 0,
          order,
          entries: [],
        });
        current = order;
      }

      const block = blockFor(node, listDepth);
      if (block !== null) {
        const entryOrder = this.order;
        const target = this.claims[current];
        target.entries.push({
          y: node.frame ? minY(node.frame) : 0,
          x: node.frame ? minX(node.frame) : 0,
          order: entryOrder,
          block,
        });
        if (this.focus === node && target.kind === "main") this.anchor = [target.order, entryOrder];
        this.order += 1;
        // A node that emits text ends the descent, so a paragraph and its text runs do not
        // both appear.
        continue;
      }
      const childDepth = node.role === "List" || node.role === "Outline" ? listDepth + 1 : listDepth;
      const childInSplit = node.role === "SplitGroup";
      const kids = children(node);
      for (let i = kids.length - 1; i >= 0; i--) stack.push(kids[i], current, childInSplit, childDepth, depth + 1);
    }
  }
}

// Groups claims by kind in emission order, concatenates same-kind claims in (y, x) order,
// orders blocks visually within a claim and drops repeats of the same shape and text.
const assemble = (claims, anchor) => {
  const regions = [];
  let mainAnchorIndex = null;
  for (const kind of REGION_ORDER) {
    const matching = claims.filter((c) => c.kind === kind && c.entries.length > 0);
    matching.sort(byPosition);
    const seen = new Set();
    const blocks = [];
    for (const claim of matching) {
      const ordered = claim.entries.slice().sort(byPosition);
      for (const entry of ordered) {
        const key = dedupKey(entry.block);
        if (seen.has(key)) continue;
        seen.add(key);
        if (kind === "main" && anchor !== null && anchor[0] === claim.order && anchor[1] === entry.order) {
          mainAnchorIndex = blocks.length;
        }
        blocks.push(entry.block);
      }
    }
    if (blocks.length > 0) regions.push({ kind, blocks });
  }
  return { regions, mainAnchorIndex };
};

// ---- budgets ---------------------------------------------------------------------------------

const renderedSize = (blocks) =>
  blocks.reduce((sum, b) => sum + charCount(rendered(b)), 0) + Math.max(blocks.length - 1, 0);

const budgetShare = (total, fraction) => {
  if (!Number.isFinite(fraction) || fraction <= 0) return 0;
  return Math.trunc(total * Math.min(fraction, 1));
};

// Keeps whole blocks from the top until the allowance is spent. A block is never split, and
// the first block is kept even when it alone exceeds the allowance.
const trimBlocks = (blocks, allowance) => {
  const kept = [];
  let used = 0;
  for (const block of blocks) {
    const cost = charCount(rendered(block)) + (kept.length > 0 ? 1 : 0);
    if (kept.length > 0 && used + cost > allowance) break;
    kept.push(block);
    used += cost;
  }
  return [kept, kept.length !== blocks.length];
};

// Like trimBlocks, but keeps the contiguous window of blocks around the anchor (what the user
// is looking at) instead of the top. The anchor is always kept. Expansion alternates, forward
// first, and stops at the first neighbour that does not fit.
const trimAnchored = (blocks, allowance, anchor) => {
  if (anchor === null || anchor >= blocks.length) return trimBlocks(blocks, allowance);
  let low = anchor;
  let high = anchor;
  let used = charCount(rendered(blocks[anchor]));
  let forward = true;
  while (low > 0 || high < blocks.length - 1) {
    const canGoForward = high < blocks.length - 1;
    const index = (forward && canGoForward) || low === 0 ? high + 1 : low - 1;
    const cost = charCount(rendered(blocks[index])) + 1;
    if (used + cost > allowance) break;
    used += cost;
    if (index > high) high = index;
    else low = index;
    forward = !forward;
  }
  const kept = blocks.slice(low, high + 1);
  return [kept, kept.length !== blocks.length];
};

// Shares the character budget between regions. Main gets `main_share`, a dialog gets
// `dialog_share` and may borrow from main, and all other regions split `rest_share` in
// proportion to their size. Unused shares roll into main.
const applyBudgets = (regions, anchor, options) => {
  const total = Math.max(options.total_budget, 1);
  const mainShare = budgetShare(total, options.main_share);
  const dialogShare = budgetShare(total, options.dialog_share);
  const restShare = budgetShare(total, options.rest_share);
  let truncated = false;

  const findRegion = (kind) => regions.find((r) => r.kind === kind);
  const rest = regions.filter((r) => r.kind !== "main" && r.kind !== "dialog");

  const dialogAllowance = dialogShare + mainShare + (rest.length === 0 ? restShare : 0);
  const dialogRegion = findRegion("dialog");
  const [dialogBlocks, dialogCut] = trimBlocks(dialogRegion ? dialogRegion.blocks : [], dialogAllowance);
  truncated = truncated || dialogCut;
  let mainAllowance = mainShare + dialogShare - renderedSize(dialogBlocks);

  const restSizes = rest.map((r) => renderedSize(r.blocks));
  const restTotal = restSizes.reduce((a, b) => a + b, 0);
  let trimmedRest = [];
  let restUsed = 0;
  if (restTotal <= restShare) {
    trimmedRest = rest.slice();
    restUsed = restTotal;
  } else {
    rest.forEach((region, i) => {
      const share = restTotal > 0 ? Math.trunc((restShare * restSizes[i]) / restTotal) : 0;
      const [blocks, cut] = trimBlocks(region.blocks, share);
      truncated = truncated || cut;
      restUsed += renderedSize(blocks);
      if (blocks.length > 0) trimmedRest.push({ kind: region.kind, blocks });
    });
  }
  mainAllowance = Math.max(mainAllowance + restShare - restUsed, 0);

  // Only main is viewport-anchored. Chrome regions keep their top.
  const mainRegion = findRegion("main");
  const [mainBlocks, mainCut] = trimAnchored(mainRegion ? mainRegion.blocks : [], mainAllowance, anchor);
  truncated = truncated || mainCut;

  const out = [];
  for (const kind of REGION_ORDER) {
    if (kind === "main") {
      if (mainBlocks.length > 0) out.push({ kind, blocks: mainBlocks });
    } else if (kind === "dialog") {
      if (dialogBlocks.length > 0) out.push({ kind, blocks: dialogBlocks });
    } else {
      const r = trimmedRest.find((x) => x.kind === kind);
      if (r) out.push(r);
    }
  }
  return [out, truncated];
};

// ---- extraction ------------------------------------------------------------------------------

// Extracts a page from `roots`, measuring region geometry against `windowFrame`.
// `skipToolbars` drops toolbar subtrees, for walks that start at the whole window.
const extractRoots = (roots, windowFrame, skipToolbars, options) => {
  const focus = deepestFocused(roots);
  const walker = new Walker(windowFrame, options, skipToolbars, focus);
  for (const root of roots) walker.walk(root);
  const assembly = assemble(walker.claims, walker.anchor);
  const [regions, budgetCut] = applyBudgets(assembly.regions, assembly.mainAnchorIndex, options);
  return { regions, truncated: walker.truncated || budgetCut };
};

// The block texts of all regions in region order, one per line. Empty texts are skipped.
const pageText = (page) =>
  page.regions
    .flatMap((r) => r.blocks)
    .map((b) => b.text)
    .filter((t) => t !== "")
    .join("\n");

const containsReadableText = (node) => {
  let found = false;
  const stack = [node];
  while (stack.length > 0 && !found) {
    const n = stack.pop();
    if ((n.role === "StaticText" || n.role === "Heading") && hasText(n.value) && n.value !== "") found = true;
    else for (const c of children(n)) stack.push(c);
  }
  return found;
};

const titleResembles = (a, b) => {
  if (!hasText(a) || !hasText(b) || a === "" || b === "") return false;
  const la = a.toLowerCase();
  const lb = b.toLowerCase();
  return la.includes(lb) || lb.includes(la);
};

const webAreaScore = (node, windowTitle) => {
  let score = 0;
  if (node.focused) score += 20;
  if (node.frame && node.frame.width > 1 && node.frame.height > 1) score += 10;
  if (containsReadableText(node)) score += 10;
  if (attr(node, "url") !== undefined) score += 20;
  if (titleResembles(node.name, windowTitle)) score += 5;
  return score;
};

// The browser's active web area: the highest scoring `WebArea` in the tree (focused, framed,
// readable, carrying a URL, titled like the window). The first of equal scores wins.
const primaryWebArea = (root, windowTitle) => {
  let best = null;
  preorder(root, (n) => {
    if (n.role === "WebArea") {
      const score = webAreaScore(n, windowTitle);
      if (best === null || score > best[0]) best = [score, n];
    }
  });
  return best === null ? null : best[1];
};

const extractSnapshot = (snapshot, options) => {
  const window = snapshot.root;
  const area = primaryWebArea(window, snapshot.window_title);
  if (area !== null) {
    // Re-rooted on the web area, so browser chrome is out of reach. The window frame is kept
    // because region geometry is window-relative.
    const opts = { ...options, visible_only: false };
    return { page: extractRoots([area], window.frame, false, opts), areaUrl: attr(area, "url") };
  }
  // No web area (a native window, a blank tab). The whole window minus toolbars is better
  // than nothing, and the address bar must not become content.
  return { page: extractRoots([window], window.frame, true, options), areaUrl: undefined };
};

// Splits on Unicode whitespace, joins with "-" and lowercases.
const slug = (input) => input.split(WS_SPLIT_RE).filter((p) => p !== "").join("-").toLowerCase();

export function parse(snapshot, ctx) {
  const { page, areaUrl } = extractSnapshot(snapshot, DEFAULT_OPTIONS);
  const text = pageText(page);
  if (trim(text) === "") return { refuse: "empty-page" };
  // Redact before anything is derived from the URL: the key and the stored URL must never
  // carry a code or state parameter.
  const rawUrl = snapshot.url ?? areaUrl;
  const url = hasText(rawUrl) && trim(rawUrl) !== "" ? ctx.url.redact(rawUrl) : undefined;
  const windowTitle =
    hasText(snapshot.window_title) && trim(snapshot.window_title) !== "" ? snapshot.window_title : undefined;
  let threadKey;
  if (url !== undefined) threadKey = `web:${ctx.url.normalize(url)}`;
  else if (windowTitle !== undefined) threadKey = `app:${snapshot.app.bundle_id}/${slug(windowTitle)}`;
  else threadKey = `app:${snapshot.app.bundle_id}`;
  const threadTitle = windowTitle ?? url ?? snapshot.app.name;
  const out = { app: snapshot.app };
  if (url !== undefined) out.url = url;
  if (windowTitle !== undefined) out.window_title = windowTitle;
  out.thread_key = threadKey;
  out.thread_title = threadTitle;
  // The generic golden carries no page title, so the title stays empty. The window title is in
  // `thread_title` and `window_title`.
  out.content = { kind: "page", title: "", text };
  out.parser = PARSER_ID;
  out.truncated = page.truncated;
  return out;
}
