// Slack, native and web. Anchors are DOM classes the app exposes through the accessibility
// tree: `c-message_list`, `c-virtual_list__item`, `c-message_kit__background`,
// `c-message__sender`, `c-timestamp`, `ql-editor` and `p-view_header__channel_title`.
// There is no whole-tree or geometry fallback.
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.tinyspeck.slackmacgap"], hosts: ["app.slack.com", ".slack.com"] },
};

const PARSER_ID = "slack/v1";
const MESSAGE_LIST = "c-message_list";
const MESSAGE_PANE = "p-message_pane";
const MESSAGE_ITEM = "c-virtual_list__item";
const MESSAGE_BACKGROUND = "c-message_kit__background";
const SENDER = "c-message__sender";
const TIMESTAMP = "c-timestamp";
const COMPOSER = "ql-editor";
const REACTIONS = "c-message_kit__reaction_bar";
const HEADER_CHANNEL = "p-view_header__channel_title";

// Removes a leading unread counter such as "(3) " from a view name.
function stripLeadingCounter(view) {
  view = view.trim();
  if (view.startsWith("(")) {
    const rest = view.slice(1);
    const close = rest.indexOf(")");
    if (close >= 0) {
      const inside = rest.slice(0, close);
      const tail = rest.slice(close + 1);
      if (inside !== "" && /^[0-9+]+$/.test(inside)) return tail.trimStart();
    }
  }
  return view;
}

// Parses "<view> - <workspace> - Slack". Counter fragments ("3 new items", "(3)") are dropped
// before the workspace is picked, so the workspace is never a counter. Undefined when the title
// is not a Slack title with at least a view and a workspace.
function parseTitle(title, ctx) {
  let parts = title.split(" - ").map((p) => p.trim());
  if (parts.pop() !== "Slack") return undefined;
  parts = parts.filter((p) => !ctx.isCounterFragment(p));
  if (parts.length < 2) return undefined;
  const workspace = parts[parts.length - 1];
  const view = stripLeadingCounter(parts[0]);
  return view !== "" && workspace !== "" ? { view, workspace } : undefined;
}

function threadKey(title, ctx) {
  if (title === undefined) return "slack:unknown";
  const p = parseTitle(title, ctx);
  return p ? `slack:${ctx.slug(p.workspace)}/${ctx.slug(p.view)}` : `slack:${ctx.slug(title)}`;
}

function channelFromTitle(title, ctx) {
  if (title === undefined) return "unknown";
  const p = parseTitle(title, ctx);
  return p ? p.view.replace(/^[# ]+|[# ]+$/g, "") : title;
}

function isGroupFromTitle(title, ctx) {
  const p = title === undefined ? undefined : parseTitle(title, ctx);
  return p !== undefined && p.view.startsWith("#");
}

const classQuery = (cls) => `//*[domClass*="${cls}"]`;

function textOfFound(node, ctx) {
  return node ? ctx.textOf(node) : undefined;
}

function headerChannel(root, ctx) {
  return textOfFound(ctx.find(`//*[domClass="${HEADER_CHANNEL}"]`, root), ctx);
}

// Message items: the virtual-list rows when exposed, else the message_kit backgrounds. Never
// both, so one message is not counted twice.
function domItems(list, ctx) {
  let items = ctx.findAll(classQuery(MESSAGE_ITEM), list);
  if (items.length === 0) items = ctx.findAll(classQuery(MESSAGE_BACKGROUND), list);
  return ctx.sortedByVisualOrder(items, list.frame);
}

// The message list container. Matched by exact class, because a substring match also hits
// `c-message_list__day_divider…`. Slack desktop builds that expose no `c-message_list` node
// keep the rows directly under `p-message_pane`.
function messageList(root, ctx) {
  return ctx.find(`//*[domClass="${MESSAGE_LIST}"]`, root) ?? ctx.find(`//*[domClass="${MESSAGE_PANE}"]`, root);
}

function domMessages(root, ctx) {
  const list = messageList(root, ctx);
  if (!list) return [];
  const out = [];
  for (const item of domItems(list, ctx)) {
    // Day dividers and the DM foreword are list rows too; a message row has a sender or a time.
    if (!ctx.find(classQuery(TIMESTAMP), item) && !ctx.find(classQuery(SENDER), item)) continue;
    const sender = textOfFound(ctx.find(classQuery(SENDER), item), ctx);
    // Slack web puts the readable time in the timestamp's label, native in its value.
    const time = textOfFound(ctx.find(classQuery(TIMESTAMP), item), ctx);
    // Reaction counts are not message text.
    const texts = ctx.staticTextsExcluding(
      item,
      (n) => ctx.node.hasClassContaining(n, SENDER) || ctx.node.hasClass(n, TIMESTAMP) || ctx.node.hasClass(n, REACTIONS),
    );
    const [author, isUser] = ctx.resolveUser(sender);
    const m = ctx.message(author, time, texts, isUser);
    if (m !== undefined) out.push(m);
  }
  return out;
}

function draftMessage(root, ctx) {
  const composer = ctx.find(classQuery(COMPOSER), root);
  return composer ? ctx.draft(composer) : ctx.focusedComposerDraft(root);
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const title = ctx.windowTitle(snapshot);
  const messages = domMessages(root, ctx);
  const draft = draftMessage(root, ctx);
  if (draft !== undefined) messages.push(draft);
  if (messages.length === 0) {
    // The one refusal: a visible, empty composer on app.slack.com and nothing else.
    const onWeb = snapshot.url !== undefined && snapshot.url !== null && ctx.url.host(snapshot.url) === "app.slack.com";
    const composer = ctx.find(classQuery(COMPOSER), root);
    if (onWeb && composer && !composer.hidden) return { refuse: "empty-compose" };
    return null;
  }
  const header = headerChannel(root, ctx);
  let channel;
  let isGroup;
  if (header !== undefined) {
    channel = header.startsWith("#") ? header.slice(1) : header;
    isGroup = header.startsWith("#");
  } else {
    channel = channelFromTitle(title, ctx);
    // The web message_kit anchor defaults to "channel" when the header is absent.
    isGroup = ctx.find(classQuery(MESSAGE_BACKGROUND), root) !== undefined || isGroupFromTitle(title, ctx);
  }
  const parsed = title === undefined ? undefined : parseTitle(title, ctx);
  const account = parsed ? parsed.workspace : undefined;
  const content = { kind: "conversation", title: channel, is_group: isGroup, messages };
  return ctx.item(snapshot, PARSER_ID, threadKey(title, ctx), channel, account, content);
}
