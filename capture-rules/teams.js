// Teams on the web. Containers resolve in tiers: the `fui-ChatMessage` DOM class, then a
// `chat-pane-message` DOM id prefix, then an identifier prefix. A container with no static
// texts falls back to its description as the whole message, unattributed. The description is
// never split into sender and time, because guessing a format would misattribute text.
export const meta = {
  api: 1,
  kind: "parser",
  match: { hosts: ["teams.microsoft.com", "teams.live.com", "teams.cloud.microsoft"] },
};

const PARSER_ID = "teams-web/v1";
const MESSAGE_CLASS = "fui-ChatMessage";
const AUTHOR_CLASS = "message-author-name";
const TIMESTAMP_CLASS = "message-timestamp";
const BODY_CLASS = "fui-ChatMessage__body";
const MESSAGE_ID_PREFIX = "chat-pane-message";
const COMPOSER_CLASS = "ck-editor__editable";
const COMPOSER_ID = "ckeditor";

const TEXT_ENTRY_ROLES = ["TextField", "TextArea", "ComboBox", "SecureTextField"];

function messageContainers(root, ctx) {
  let found = ctx.findAll(`//*[domClass="${MESSAGE_CLASS}"]`, root);
  if (found.length === 0) found = ctx.findAll(`//*[domId^="${MESSAGE_ID_PREFIX}"]`, root);
  if (found.length === 0) {
    found = ctx.node.allWhere(root, (n) => {
      const i = ctx.node.identifier(n);
      return i !== undefined && i.startsWith(MESSAGE_ID_PREFIX);
    });
  }
  return ctx.sortedByVisualOrder(found, root.frame);
}

function composerOf(root, ctx) {
  return (
    ctx.find(`//*[domClass*="${COMPOSER_CLASS}"]`, root) ||
    ctx.find(`//*[domId="${COMPOSER_ID}"]`, root) ||
    // Last resort: a text-entry field whose placeholder or description says "message".
    ctx.node.allWhere(root, (n) => {
      if (!TEXT_ENTRY_ROLES.includes(n.role)) return false;
      const joined = [ctx.node.placeholder(n), ctx.node.label(n)].filter((v) => v !== undefined).join(" ");
      return joined.toLowerCase().includes("message");
    })[0]
  );
}

function channelOf(root, title, ctx) {
  for (const h of ctx.findAll("//Heading", root)) {
    const t = ctx.textOf(h);
    if (t !== undefined) return t;
  }
  return title !== undefined ? title : "unknown";
}

function messagesOf(root, ctx) {
  const out = [];
  for (const container of messageContainers(root, ctx)) {
    const author = ctx.find(`//*[domClass="${AUTHOR_CLASS}"]`, container);
    const time = ctx.find(`//*[domClass="${TIMESTAMP_CLASS}"]`, container);
    const sender = author ? ctx.textOf(author) : undefined;
    const timeText = time ? ctx.textOf(time) : undefined;
    const body = ctx.find(`//*[domClass="${BODY_CLASS}"]`, container);
    let texts;
    if (body) {
      texts = ctx.collectStaticTexts(body);
    } else {
      const excluded = [];
      for (const n of [author, time]) if (n) excluded.push(...ctx.collectStaticTexts(n));
      texts = ctx.collectStaticTexts(container).filter((t) => !excluded.includes(t));
    }
    if (texts.length === 0) {
      const described = ctx.textOf(container);
      if (described === undefined) continue;
      const m = ctx.message(undefined, timeText, [described], false);
      if (m !== undefined) out.push(m);
      continue;
    }
    const [author2, isUser] = ctx.resolveUser(sender);
    const m = ctx.message(author2, timeText, texts, isUser);
    if (m !== undefined) out.push(m);
  }
  return out;
}

// Splits an absolute URL string into path, query and fragment. The caller passes a redacted URL.
function urlParts(raw) {
  const m = /^[a-zA-Z][a-zA-Z0-9+.\-]*:(?:\/\/[^\/?#]*)?([^?#]*)(?:\?([^#]*))?(?:#([\s\S]*))?$/.exec(raw);
  return m ? { path: m[1], query: m[2], fragment: m[3] } : undefined;
}

// The text after the first of `markers` in `haystack`, up to the next `/`, `?`, `&` or `#`.
function segmentAfter(haystack, markers) {
  for (const marker of markers) {
    const at = haystack.indexOf(marker);
    if (at < 0) continue;
    const rest = haystack.slice(at + marker.length);
    const end = rest.search(/[\/?&#]/);
    const id = end < 0 ? rest : rest.slice(0, end);
    if (id !== "") return id;
  }
  return undefined;
}

// The conversation id from the URL path or fragment. Works on the redacted URL only.
function conversationId(rawUrl, ctx) {
  const parts = urlParts(ctx.url.redact(rawUrl));
  if (!parts) return undefined;
  const markers = ["/conversations/", "/l/chat/", "/l/channel/", "/chat/"];
  const fromFragment = parts.fragment !== undefined ? segmentAfter(parts.fragment, markers) : undefined;
  return fromFragment !== undefined ? fromFragment : segmentAfter(parts.path, markers);
}

function threadKey(snapshot, title, ctx) {
  const id = snapshot.url !== undefined && snapshot.url !== null ? conversationId(snapshot.url, ctx) : undefined;
  return id !== undefined ? `teams:${id}` : `teams:${ctx.slug(title)}`;
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const composer = composerOf(root, ctx);
  const draft = ctx.draft(composer);
  const all = messagesOf(root, ctx);
  const hadMessages = all.length > 0;
  if (draft !== undefined) all.push(draft);
  if (all.length === 0) {
    // The one refusal: a compose-only chat whose draft is empty. Teams' calendar, files
    // and apps tabs share this host and are left to the generic parser.
    return composer !== undefined && !hadMessages ? { refuse: "empty-compose" } : null;
  }
  const title = channelOf(root, ctx.windowTitle(snapshot), ctx);
  const key = threadKey(snapshot, title, ctx);
  // Teams' anchors expose no channel-versus-chat marker.
  const content = { kind: "conversation", title, is_group: false, messages: all };
  return ctx.item(snapshot, PARSER_ID, key, title, undefined, content);
}
