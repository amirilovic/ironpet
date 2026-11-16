// Microsoft Teams, the desktop app. Ported from MaxMi's TeamsParser and the shared
// NativeConversationExtraction. Teams on the web is rules/teams.js, matched by host.
//
// The transcript is a list whose identifier, description or title names a message list or
// transcript. Without one this rule returns null: the sidebar and search hold other chats'
// names, so loose window text is never read as a conversation.
//
// Inside the transcript every row or list item (or any node whose metadata says "message" or
// "bubble") right of the sidebar is one bubble. Its texts in visual order are the body; the
// first text is the sender when it is short, on one line and followed by more text. A bubble
// with one text is never split on ": ". Teams marks nothing as the user's own, so is_me is
// always false outside the draft.
//
// The chat name is the best text near the top of the main pane (a heading, or a node whose
// metadata says conversation, chat, title or header), else the window title.
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.microsoft.teams2", "com.microsoft.teams"] },
};

const PARSER_ID = "teams-desktop/v1";
const APP_NAME = "Microsoft Teams";
const MESSAGE_ROLES = ["Row", "ListItem"];
const TEXT_ROLES = ["StaticText", "TextArea", "Heading"];
const LABEL_ROLES = ["Button", "Link"];
const CHROME = new Set([
  "chats", "calls", "updates", "communities", "settings", "search", "new chat", "more", "reply",
  "react", "forward", "edited", "activity", "chat", "teams", "calendar", "apps", "copilot",
]);
const SYSTEM_NOTICES = [
  "older messages", "syncing", "reconnecting", "pinned message", "tap to go to message",
  "voice call", "video call", "is speaking",
];

const isChrome = (v) => CHROME.has(v.trim().toLowerCase());

// The first non-blank of the given candidates. Live trees report a missing value as "".
function firstText(...candidates) {
  for (const raw of candidates) {
    if (typeof raw !== "string") continue;
    const t = raw.trim();
    if (t !== "") return t;
  }
  return undefined;
}

function readableText(n, ctx) {
  if (ctx.node.isSecure(n)) return undefined;
  if (LABEL_ROLES.includes(n.role)) return firstText(ctx.node.label(n), n.name, n.value);
  if (n.role === "Heading" || n.role === "StaticText") return firstText(n.value, n.name, ctx.node.label(n));
  return firstText(n.value, n.name);
}

// identifier, description and title, lowercased and joined.
function metadata(n, ctx, withTitle) {
  const parts = [ctx.node.identifier(n), ctx.node.label(n)];
  if (withTitle) parts.push(n.name);
  return parts.filter((p) => typeof p === "string").join(" ").toLowerCase();
}

function transcriptOf(root, ctx) {
  return ctx.node.allWhere(root, (n) => {
    if (n.role !== "List") return false;
    const meta = metadata(n, ctx, true);
    return meta.includes("message") && (meta.includes("list") || meta.includes("transcript"));
  })[0];
}

// Everything left of this x is the sidebar.
function mainPaneBoundary(root) {
  const f = root.frame;
  if (!f) return 240;
  return f.x + Math.min(360, Math.max(220, f.width * 0.28));
}

function conversationTitle(root, boundary, appName, ctx) {
  const top = root.frame ? root.frame.y : 0;
  const maxY = top + Math.min(180, (root.frame ? root.frame.height : 600) * 0.25);
  const candidates = [];
  ctx.node.walk(root, (n) => {
    if (!TEXT_ROLES.includes(n.role)) return;
    const value = readableText(n, ctx);
    if (value === undefined || [...value].length > 120) return;
    const x = n.frame ? n.frame.x : boundary;
    const y = n.frame ? n.frame.y : 0;
    if (x < boundary || y > maxY) return;
    let score = n.role === "Heading" ? 30 : 10;
    const meta = metadata(n, ctx, false);
    if (["conversation", "chat", "title", "header"].some((w) => meta.includes(w))) score += 20;
    candidates.push({ score, y, i: candidates.length, value });
  });
  const appNames = [appName.toLowerCase(), "microsoft teams", "teams"];
  const usable = candidates.filter((c) => {
    const lower = c.value.toLowerCase();
    return !appNames.includes(lower) && !isChrome(lower) && !SYSTEM_NOTICES.some((s) => lower.includes(s));
  });
  usable.sort((a, b) => b.score - a.score || a.y - b.y || a.i - b.i);
  return usable.length > 0 ? usable[0].value : undefined;
}

// Drops blanks and case-insensitive adjacent repeats.
function uniqueAdjacent(values) {
  const out = [];
  for (const v of values) {
    const clean = v.trim();
    if (clean === "") continue;
    if (out.length > 0 && out[out.length - 1].toLowerCase() === clean.toLowerCase()) continue;
    out.push(clean);
  }
  return out;
}

function containerTexts(node, ctx) {
  const found = [];
  ctx.node.walk(node, (n) => {
    if (!TEXT_ROLES.includes(n.role) && !LABEL_ROLES.includes(n.role)) return;
    const value = readableText(n, ctx);
    if (value !== undefined) {
      found.push({ y: n.frame ? n.frame.y : 0, x: n.frame ? n.frame.x : 0, i: found.length, value });
    }
  });
  found.sort((a, b) => a.y - b.y || a.x - b.x || a.i - b.i);
  return uniqueAdjacent(found.map((f) => f.value)).filter((v) => !isChrome(v));
}

function collectContainers(node, boundary, out, ctx) {
  if (ctx.node.isSecure(node)) return;
  const meta = metadata(node, ctx, true);
  const hint = meta.includes("message") || meta.includes("bubble");
  const x = node.frame ? node.frame.x : boundary;
  if (x >= boundary && (MESSAGE_ROLES.includes(node.role) || hint)) {
    const texts = containerTexts(node, ctx);
    if (texts.length > 0) {
      const sender = ctx.senderLabel(texts);
      out.push({
        y: node.frame ? node.frame.y : 0,
        i: out.length,
        sender,
        text: (sender === undefined ? texts : texts.slice(1)).join(" ").trim(),
      });
      return;
    }
  }
  for (const c of ctx.node.children(node)) collectContainers(c, boundary, out, ctx);
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const transcript = transcriptOf(root, ctx);
  if (!transcript) return null;

  const boundary = mainPaneBoundary(root);
  const containers = [];
  for (const c of ctx.node.children(transcript)) collectContainers(c, boundary, containers, ctx);
  containers.sort((a, b) => a.y - b.y || a.i - b.i);

  const bubbles = [];
  for (const b of containers) {
    if (b.text === "") continue;
    const last = bubbles[bubbles.length - 1];
    if (
      last !== undefined &&
      (last.sender ?? "").toLowerCase() === (b.sender ?? "").toLowerCase() &&
      last.text.toLowerCase() === b.text.toLowerCase()
    ) continue;
    if (b.sender === undefined && isChrome(b.text)) continue;
    bubbles.push(b);
  }
  if (bubbles.length === 0) return { refuse: "no-conversation-content" };

  const messages = bubbles.map((b) => {
    const m = { text: b.text, is_me: false, draft: false };
    if (b.sender !== undefined) m.author = b.sender;
    return m;
  });
  const draft = ctx.focusedComposerDraft(root);
  if (draft !== undefined) messages.push(draft);

  const windowTitle = firstText(snapshot.window_title, root.name);
  const conversation = conversationTitle(root, boundary, snapshot.app.name ?? APP_NAME, ctx);
  const meaningful =
    windowTitle !== undefined && !["microsoft teams", "teams", (snapshot.app.name ?? "").toLowerCase()].includes(windowTitle.toLowerCase())
      ? windowTitle
      : undefined;
  const identity = conversation ?? meaningful;
  // Messages with no chat to file them under: storing them would mix every such window into one
  // thread, so store nothing, as whatsapp.js does.
  if (identity === undefined || ctx.slug(identity) === "") return { refuse: "unconfirmed-chat" };
  // Teams' headers expose no group marker.
  const content = { kind: "conversation", title: identity, is_group: false, messages };
  return ctx.item(snapshot, PARSER_ID, `teams:${ctx.slug(identity)}`, conversation ?? windowTitle ?? identity, undefined, content);
}
