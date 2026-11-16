// Gmail on the web. An open thread becomes a conversation, a list view becomes a page of table
// rows, and a compose window becomes the draft alone. Anchors: `adn` (message), `gD` (sender
// name), `go` (sender address), `g3` (time), `a3s` (body), `zA` (list row) and the
// description "Message Body" on the compose editor.
export const meta = {
  api: 1,
  kind: "parser",
  match: { hosts: ["mail.google.com"] },
};

const PARSER_ID = "gmail/v1";
const MESSAGE_CLASS = "adn";
const SENDER_NAME_CLASS = "gD";
const SENDER_ADDRESS_CLASS = "go";
const TIME_CLASS = "g3";
const BODY_CLASS = "a3s";
const LIST_ROW_CLASS = "zA";
const COMPOSE_DESCRIPTION = "Message Body";
// Headings Gmail renders around the mail. None of them is a subject.
const CHROME_HEADINGS = ["gmail", "main menu", "search mail", "chat", "meet", "spaces", "conversations"];

function composerOf(root, ctx) {
  return ctx.find(`//*[description="${COMPOSE_DESCRIPTION}"]`, root);
}

// The first heading that is not Gmail chrome, else the window title.
function subjectOf(root, title, ctx) {
  for (const h of ctx.findAll("//Heading", root)) {
    const t = ctx.textOf(h);
    if (t !== undefined && !CHROME_HEADINGS.includes(t.toLowerCase())) return t;
  }
  return title !== undefined ? title : "unknown";
}

// One message per expanded container. A collapsed row has no body, and a message with a real
// sender and no body is worse than no message.
function threadMessages(root, ctx) {
  const containers = ctx.findAll(`//*[domClass="${MESSAGE_CLASS}"]`, root);
  const out = [];
  for (const container of ctx.sortedByVisualOrder(containers, root.frame)) {
    const body = ctx.find(`//*[domClass="${BODY_CLASS}"]`, container);
    if (!body) continue;
    const textOfClass = (cls) => {
      const n = ctx.find(`//*[domClass="${cls}"]`, container);
      return n ? ctx.textOf(n) : undefined;
    };
    const sender = textOfClass(SENDER_NAME_CLASS) ?? textOfClass(SENDER_ADDRESS_CLASS);
    const time = textOfClass(TIME_CLASS);
    const [author, isUser] = ctx.resolveUser(sender);
    // Only the body subtree's texts, so the sender line cannot leak into the text.
    const m = ctx.message(author, time, ctx.collectStaticTexts(body), isUser);
    if (m !== undefined) out.push(m);
  }
  return out;
}

// `[sender, subject and snippet, time]` per list row, joined by spaces. The middle cell is
// joined rather than split, and a row with only two texts has no time.
function listRows(root, ctx) {
  const rows = ctx.findAll(`//*[domClass="${LIST_ROW_CLASS}"]`, root);
  const out = [];
  for (const row of ctx.sortedByVisualOrder(rows, root.frame)) {
    const texts = ctx.collectStaticTexts(row);
    if (texts.length < 2) continue;
    const hasTime = texts.length >= 3;
    const middleEnd = texts.length - (hasTime ? 1 : 0);
    const cells = [texts[0], texts.slice(1, middleEnd).join(" ")];
    if (hasTime) cells.push(texts[texts.length - 1]);
    const line = cells.filter((c) => c !== "").join(" ");
    if (line !== "") out.push(line);
  }
  return out;
}

// The thread id from a `#inbox/<id>`, `#label/x/<id>` or `#search/q/<id>` fragment.
function threadId(rawUrl, ctx) {
  const redacted = ctx.url.redact(rawUrl);
  const m = /^[a-zA-Z][a-zA-Z0-9+.\-]*:(?:\/\/[^\/?#]*)?[^?#]*(?:\?[^#]*)?#([\s\S]*)$/.exec(redacted);
  if (!m) return undefined;
  const route = m[1].split("?")[0];
  const segments = route.split("/").filter((s) => s !== "");
  if (segments.length < 2) return undefined;
  const last = segments[segments.length - 1];
  return last.length >= 8 && /^[A-Za-z0-9]+$/.test(last) ? last : undefined;
}

// A conversation keys on the thread id, else the subject slug. A list view keys on the
// normalized (secret-free) URL, else the title slug.
function threadKey(snapshot, title, isThread, ctx) {
  const url = snapshot.url !== undefined && snapshot.url !== null ? snapshot.url : undefined;
  if (url !== undefined && isThread) {
    const id = threadId(url, ctx);
    return id !== undefined ? `gmail:${id}` : `gmail:${ctx.slug(title)}`;
  }
  if (url !== undefined) return `gmail:${ctx.url.normalize(url)}`;
  return `gmail:${ctx.slug(title)}`;
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const title = ctx.windowTitle(snapshot);
  const composer = composerOf(root, ctx);
  const draft = ctx.draft(composer);
  const messages = threadMessages(root, ctx);
  const account = title !== undefined ? ctx.emailInTitle(title) : undefined;

  if (messages.length > 0 || draft !== undefined) {
    if (draft !== undefined) messages.push(draft);
    const subject = subjectOf(root, title, ctx);
    const key = threadKey(snapshot, subject, true, ctx);
    // Gmail's anchors expose no recipient list, so the thread stays flat.
    const content = { kind: "conversation", title: subject, is_group: false, messages };
    return ctx.item(snapshot, PARSER_ID, key, subject, account, content);
  }
  const rows = listRows(root, ctx);
  if (rows.length === 0) return composer !== undefined ? { refuse: "empty-compose" } : null;
  const listTitle = title !== undefined ? title : "Gmail";
  const key = threadKey(snapshot, listTitle, false, ctx);
  return ctx.item(snapshot, PARSER_ID, key, listTitle, account, ctx.pageFromRows(rows));
}
