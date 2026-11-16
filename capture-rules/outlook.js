// Outlook on the web. A reading pane becomes a conversation, a message list becomes a page of
// table rows, and a compose window becomes the draft alone. Anchors are
// `outlook-message-card`, `outlook-message-header`, `outlook-message-body`,
// `outlook-compose-body`, `outlook-message-row` and `outlook-subject`.
export const meta = {
  api: 1,
  kind: "parser",
  match: { hosts: ["outlook.office.com", "outlook.live.com", "outlook.office365.com"] },
};

const PARSER_ID = "outlook-web/v1";
const CARD_CLASS = "outlook-message-card";
const HEADER_CLASS = "outlook-message-header";
const BODY_CLASS = "outlook-message-body";
const COMPOSER_ID = "outlook-compose-body";
const ROW_CLASS = "outlook-message-row";
const SUBJECT_CLASS = "outlook-subject";
const CARD_DESCRIPTION_PREFIX = "Message";
const COMPOSE_DESCRIPTION = "Message body";
const SENDER_PREFIX = "From: ";
const SENT_SEPARATOR = ", Sent: ";

// Reads "... From: <name>, Sent: <time>". Both halves are optional. A description without
// "From: " yields [undefined, undefined] and the caller falls back to the header's static texts.
function headerFields(description) {
  const nonEmpty = (s) => {
    const t = s.trim();
    return t !== "" ? t : undefined;
  };
  const at = description.indexOf(SENDER_PREFIX);
  if (at < 0) return [undefined, undefined];
  const tail = description.slice(at + SENDER_PREFIX.length);
  const sep = tail.indexOf(SENT_SEPARATOR);
  if (sep < 0) return [nonEmpty(tail), undefined];
  return [nonEmpty(tail.slice(0, sep)), nonEmpty(tail.slice(sep + SENT_SEPARATOR.length))];
}

function composerOf(root, ctx) {
  return ctx.findAll(`//*[domId="${COMPOSER_ID}"]`, root).find((n) => ctx.node.label(n) === COMPOSE_DESCRIPTION);
}

// Cards are DOM-class anchored and must carry Outlook's description shape or be a document
// node. A description alone never emits content.
function messageCards(root, ctx) {
  const cards = ctx.findAll(`//*[domClass="${CARD_CLASS}"]`, root).filter((n) => {
    const l = ctx.node.label(n);
    return (l !== undefined && l.startsWith(CARD_DESCRIPTION_PREFIX)) || n.role === "Document";
  });
  return ctx.sortedByVisualOrder(cards, root.frame);
}

function subjectOf(root, title, ctx) {
  const node = ctx.find(`//*[domClass="${SUBJECT_CLASS}"]`, root);
  const text = node ? ctx.textOf(node) : undefined;
  if (text !== undefined) return text;
  return title !== undefined ? title : "unknown";
}

function readingPaneMessages(root, ctx) {
  const out = [];
  for (const card of messageCards(root, ctx)) {
    const header = ctx.find(`//*[domClass="${HEADER_CLASS}"]`, card);
    if (!header) continue;
    const body = ctx.find(`//*[domClass="${BODY_CLASS}"]`, card);
    if (!body) continue;
    const desc = ctx.node.label(header) ?? ctx.node.label(card);
    const described = desc !== undefined ? headerFields(desc) : [undefined, undefined];
    const headerTexts = ctx.collectStaticTexts(header);
    const sender = described[0] ?? ctx.senderLabel(headerTexts);
    const time = described[1] ?? headerTexts[1];
    const [author, isUser] = ctx.resolveUser(sender);
    const m = ctx.message(author, time, ctx.collectStaticTexts(body), isUser);
    if (m !== undefined) out.push(m);
  }
  return out;
}

// One line per message-list row: the row's cells joined by spaces.
function listRows(root, ctx) {
  const rows = ctx.findAll(`//Row[domClass="${ROW_CLASS}"]`, root);
  return ctx
    .sortedByVisualOrder(rows, root.frame)
    .map((row) => ctx.rowCells(row).join(" "))
    .filter((text) => text !== "");
}

// The `itemid` query parameter of the redacted URL, which identifies the open message.
function itemId(rawUrl, ctx) {
  const redacted = ctx.url.redact(rawUrl);
  const m = /^[a-zA-Z][a-zA-Z0-9+.\-]*:(?:\/\/[^\/?#]*)?[^?#]*(?:\?([^#]*))?/.exec(redacted);
  if (!m || m[1] === undefined) return undefined;
  const decode = (s) => {
    const spaced = s.replace(/\+/g, " ");
    try {
      return decodeURIComponent(spaced);
    } catch (e) {
      return spaced;
    }
  };
  for (const pair of m[1].split("&")) {
    if (pair === "") continue;
    const eq = pair.indexOf("=");
    const key = decode(eq < 0 ? pair : pair.slice(0, eq));
    if (key.toLowerCase() === "itemid") {
      const value = decode(eq < 0 ? "" : pair.slice(eq + 1));
      return value !== "" ? value : undefined;
    }
  }
  return undefined;
}

function threadKey(snapshot, fallbackTitle, ctx) {
  const id = snapshot.url !== undefined && snapshot.url !== null ? itemId(snapshot.url, ctx) : undefined;
  return id !== undefined ? `outlook:${id}` : `outlook:${ctx.slug(fallbackTitle)}`;
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const title = ctx.windowTitle(snapshot);
  const composer = composerOf(root, ctx);
  const draft = ctx.draft(composer);
  const messages = readingPaneMessages(root, ctx);
  const account = title !== undefined ? ctx.emailInTitle(title) : undefined;

  if (messages.length > 0 || draft !== undefined) {
    if (draft !== undefined) messages.push(draft);
    const subject = subjectOf(root, title, ctx);
    const key = threadKey(snapshot, subject, ctx);
    const content = { kind: "conversation", title: subject, is_group: false, messages };
    return ctx.item(snapshot, PARSER_ID, key, subject, account, content);
  }
  const rows = listRows(root, ctx);
  if (rows.length === 0) {
    // The one refusal: a compose-only window whose draft is empty.
    return composer !== undefined ? { refuse: "empty-compose" } : null;
  }
  const listTitle = title !== undefined ? title : "outlook";
  const key = threadKey(snapshot, listTitle, ctx);
  return ctx.item(snapshot, PARSER_ID, key, listTitle, account, ctx.pageFromRows(rows));
}
