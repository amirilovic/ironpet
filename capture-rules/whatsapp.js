// WhatsApp for macOS (the Catalyst app). The open chat's name is the label of
// `NavigationBar_HeaderViewButton`, and every message is a `WAMessageBubbleTableViewCell`
// whose label reads like VoiceOver:
//
//   message, <text>, <time>, Received from <name>
//   Your message, <text>, <time>, Sent to <name>, Read
//   Message from <sender>, <text>, <time>, Received in <group>
//   Replying to <name>.\n<one of the above>.\nQuoted message.\n<quoted text>
//
// Calls, photos and other non-text bubbles have no "message" prefix; their whole lead is kept
// as the text ("Photo", "Missed voice call"). Labels carry U+200E marks, which are dropped.
//
// Older builds name the chat in a heading labelled "conversation title" and give each bubble
// either a "Name: text" label or its text and time as child texts. There the side of the
// window a bubble sits on tells the user's own messages apart.
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["net.whatsapp.WhatsApp"] },
};

const PARSER_ID = "whatsapp/v1";
const HEADER = "NavigationBar_HeaderViewButton";
const MESSAGES = "ChatMessagesTableView";
const BUBBLE = "WAMessageBubbleTableViewCell";
const COMPOSER = "ChatBar_ComposerTextView";
const MESSAGES_PREFIX = "Messages in chat with ";
const LEGACY_TITLE_LABEL = "conversation title";
// "16:02" or "4:02 PM", the trailing child text of a legacy bubble.
const LEGACY_TIME = /^\d{1,2}:\d{2}(\s?[AP]M)?$/i;
// The VoiceOver-style label of current builds.
const VOICEOVER = /^(Replying to |Your message, |message, |Message from )|, (Received from|Received in|Sent to) /;

// Direction marks, bidi embeddings and isolates that WhatsApp wraps names and labels in.
const clean = (s) =>
  typeof s === "string" ? s.replace(/[‎‏‪-‮⁦-⁩]/g, "").trim() : "";

// "13:43", "7:05 PM", "25. October at 12:10", "October 25 at 12:10 PM", "Yesterday at 9:00".
const TIME_TAIL = /, ((?:[^,]* at )?\d{1,2}[:.]\d{2}(?:\s?[AP]M)?)$/i;

// The direction marker that ends the message part of a bubble label.
const DIRECTION = /, (Received from|Received in|Sent to) ([^,]*)(?:, .*)?$/;

function parseBubble(raw, chat) {
  let text = clean(raw);
  if (text === "") return undefined;
  // A reply quotes the original after the message; keep the reply itself.
  let lines = text.split("\n").map(clean);
  if (lines[0].startsWith("Replying to ")) lines = lines.slice(1);
  let main = lines[0] ?? "";
  if (main.endsWith(".")) main = main.slice(0, -1);

  let direction;
  let peer;
  const d = main.match(DIRECTION);
  if (d) {
    direction = d[1];
    peer = clean(d[2]);
    main = main.slice(0, d.index);
  }
  let sentAt;
  const t = main.match(TIME_TAIL);
  if (t) {
    sentAt = t[1];
    main = main.slice(0, t.index);
  }

  let isMe = direction === "Sent to";
  let author;
  if (main.startsWith("Your message, ")) {
    isMe = true;
    main = main.slice("Your message, ".length);
  } else if (main.startsWith("Message from ")) {
    // Group chats: "Message from <sender>, <text>".
    const rest = main.slice("Message from ".length);
    const comma = rest.indexOf(", ");
    if (comma > 0) {
      author = clean(rest.slice(0, comma));
      main = rest.slice(comma + 2);
    }
  } else if (main.startsWith("message, ")) {
    main = main.slice("message, ".length);
  }
  if (isMe) author = "You";
  else if (author === undefined && direction === "Received from") author = peer || chat;

  main = clean(main);
  if (main === "") return undefined;
  const m = { text: main, is_me: isMe, draft: false };
  if (author !== undefined && author !== "") m.author = author;
  if (sentAt !== undefined) m.sent_at = sentAt;
  return m;
}

// A bubble from an older build: "Name: text" in the label, or the text and its time as child
// texts. `rightSide` marks the user's own bubbles there.
function parseLegacyBubble(cell, chat, rightSide, ctx) {
  const label = clean(ctx.node.label(cell));
  const colon = label.indexOf(": ");
  if (colon > 0) {
    const sender = label.slice(0, colon).trim();
    const text = label.slice(colon + 2).trim();
    if (text === "") return undefined;
    const isMe = sender === "You";
    return { author: isMe ? "You" : sender, text, is_me: isMe, draft: false };
  }
  const texts = ctx.staticTextsExcluding(cell, () => false).map(clean).filter((t) => t !== "");
  let sentAt;
  if (texts.length > 1 && LEGACY_TIME.test(texts[texts.length - 1])) sentAt = texts.pop();
  const text = texts.length > 0 ? texts.join(" ") : label;
  if (text === "") return undefined;
  const m = { author: rightSide ? "You" : chat, text, is_me: rightSide, draft: false };
  if (sentAt !== undefined) m.sent_at = sentAt;
  return m;
}

function isRightSide(cell, root) {
  const f = cell.frame;
  const w = root.frame;
  if (!f || !w || !(w.width > 0)) return false;
  return f.x + f.width / 2 > w.x + w.width / 2;
}

// The header button's label is the chat name. Its value is a subtitle: "Members: Ana, Bo …"
// in a group, so it must not win over the label the way `ctx.textOf` would let it.
function chatName(root, ctx) {
  const header = ctx.find(`//*[identifier="${HEADER}"]`, root);
  const name = header ? clean(ctx.node.label(header)) || clean(header.name) : "";
  if (name !== "") return name;
  const list = ctx.find(`//*[identifier="${MESSAGES}"]`, root);
  const label = list ? clean(ctx.node.label(list)) : "";
  if (label.startsWith(MESSAGES_PREFIX)) return label.slice(MESSAGES_PREFIX.length).trim();
  const subtitle = header ? clean(header.value) : "";
  if (subtitle !== "" && !subtitle.startsWith("Members:")) return subtitle;
  const legacy = ctx.find(`//Heading[label="${LEGACY_TITLE_LABEL}"]`, root);
  return legacy ? clean(ctx.textOf(legacy)) : "";
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const chat = chatName(root, ctx);
  if (chat === "") {
    // Messages with no chat to file them under: the header is not there yet, mid-switch.
    // Generic would store the chat list of every unopened chat instead, so store nothing.
    if (ctx.find(`//*[identifier="${BUBBLE}"]`, root)) return { refuse: "unconfirmed-chat" };
    // No open chat (Updates, Calls, settings): let the generic rule have it.
    return null;
  }

  const list = ctx.find(`//*[identifier="${MESSAGES}"]`, root) ?? root;
  const bubbles = ctx.sortedByVisualOrder(ctx.findAll(`//*[identifier="${BUBBLE}"]`, list), list.frame);
  const messages = [];
  for (const b of bubbles) {
    if (ctx.node.isSecure(b)) continue;
    const label = clean(ctx.node.label(b));
    const m = VOICEOVER.test(label)
      ? parseBubble(label, chat)
      : parseLegacyBubble(b, chat, isRightSide(b, root), ctx);
    if (m !== undefined) messages.push(m);
  }
  const composer = ctx.find(`//*[identifier="${COMPOSER}"]`, root);
  const draft = composer ? ctx.draft(composer) : undefined;
  if (draft !== undefined) messages.push(draft);
  if (messages.length === 0) return null;

  // A group bubble names its sender; a 1:1 chat never does.
  const isGroup = messages.some((m) => !m.is_me && m.author !== undefined && m.author !== chat);
  const content = { kind: "conversation", title: chat, is_group: isGroup, messages };
  return ctx.item(snapshot, PARSER_ID, `whatsapp:${ctx.slug(chat)}`, chat, undefined, content);
}
