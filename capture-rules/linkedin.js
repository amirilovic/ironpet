// LinkedIn messaging (linkedin.com/messaging). Ported from MaxMi's LinkedInMessagingParser.
// Every other LinkedIn page returns null and stays with the generic rule, even when it shows
// message classes (the feed's messaging rail does).
//
// Each `msg-s-message-list__event` is one list item. The sender name and time sit on the first
// item of a group, so an item without them continues the group before it. A message is the
// user's only when its sender equals the signed-in name from the nav photo ("Photo of <name>")
// or is the `[user]` marker; alignment is never used.
export const meta = {
  api: 1,
  kind: "parser",
  match: { hosts: ["www.linkedin.com", "linkedin.com"] },
};

const PARSER_ID = "linkedin/v1";
const MESSAGING_PREFIX = "/messaging";
const EVENT = "msg-s-message-list__event";
const GROUP_NAME = "msg-s-message-group__name";
const GROUP_TIME = "msg-s-message-group__timestamp";
const BODY = "msg-s-event-listitem__body";
const TITLE = "msg-entity-lockup__entity-title";
const COMPOSER = "msg-form__contenteditable";
const NAV_ME_PHOTO = "global-nav__me-photo";
const NAV_ME = "global-nav__me";
const PHOTO_PREFIX = "Photo of ";

const byClass = (cls) => `//*[domClass="${cls}"]`;

// The path of an absolute URL, or "" when it has none.
function urlPath(raw) {
  const m = /^[a-zA-Z][a-zA-Z0-9+.\-]*:(?:\/\/[^\/?#]*)?([^?#]*)/.exec(raw ?? "");
  return m ? m[1] : "";
}

function textAt(cls, root, ctx) {
  const n = ctx.find(byClass(cls), root);
  return n ? ctx.textOf(n) : undefined;
}

function signedInName(root, ctx) {
  const node = ctx.find(byClass(NAV_ME_PHOTO), root) ?? ctx.find(byClass(NAV_ME), root);
  let name = node ? ctx.textOf(node) : undefined;
  if (name === undefined) return undefined;
  if (name.startsWith(PHOTO_PREFIX)) name = name.slice(PHOTO_PREFIX.length).trim();
  return name !== "" ? name : undefined;
}

const sameName = (a, b) => a !== undefined && b !== undefined && a.toLowerCase() === b.toLowerCase();

function messagesOf(root, selfName, ctx) {
  const events = ctx.sortedByVisualOrder(ctx.findAll(byClass(EVENT), root), root.frame);
  let sender;
  let time;
  const out = [];
  for (const event of events) {
    const name = textAt(GROUP_NAME, event, ctx);
    if (name !== undefined) {
      sender = name;
      time = textAt(GROUP_TIME, event, ctx);
    }
    const marker = sameName(sender, "[user]");
    const isMe = marker || sameName(sender, selfName);
    const bodies = ctx.sortedByVisualOrder(ctx.findAll(byClass(BODY), event), event.frame);
    for (const body of bodies) {
      const m = ctx.message(marker ? "You" : sender, time, ctx.collectStaticTexts(body), isMe);
      if (m !== undefined) out.push(m);
    }
  }
  return out;
}

// The conversation id from /messaging/thread/<id>, if the URL has one.
function threadId(path) {
  const m = /^\/messaging\/thread\/([^\/]+)/.exec(path);
  return m ? m[1] : undefined;
}

export function parse(snapshot, ctx) {
  if (snapshot.url === undefined || snapshot.url === null) return null;
  const path = urlPath(ctx.url.redact(snapshot.url));
  if (!path.startsWith(MESSAGING_PREFIX)) return null;

  const root = snapshot.root;
  const composer = ctx.find(byClass(COMPOSER), root);
  const messages = messagesOf(root, signedInName(root, ctx), ctx);
  const hadMessages = messages.length > 0;
  const draft = ctx.draft(composer);
  if (draft !== undefined) messages.push(draft);
  if (messages.length === 0) {
    // The one refusal: a compose-only thread with an empty draft. An empty messaging shell
    // without a composer is still a page for the generic rule.
    return composer !== undefined && !hadMessages ? { refuse: "empty-compose" } : null;
  }

  const title = textAt(TITLE, root, ctx) ?? ctx.windowTitle(snapshot) ?? "unknown";
  const id = threadId(path);
  const key = id !== undefined ? `linkedin:${id}` : `linkedin:${ctx.slug(title)}`;
  // LinkedIn's anchors expose no participant count, so a thread stays flat.
  const content = { kind: "conversation", title, is_group: false, messages };
  return ctx.item(snapshot, PARSER_ID, key, title, undefined, content);
}
