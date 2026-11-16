// Apple Messages (iMessage and SMS). Ported from MaxMi's MessagesParser.
//
// The window title is the open chat's name (a contact or a group). The transcript is the list
// with identifier "message-list"; only text inside it is read, because the sidebar next to it
// holds other contacts' names and the search field. Every text area or static text with a
// value in the transcript is one bubble, in visual order.
//
// A bubble right of the window's centre line is the user's. A group chat gives each incoming
// bubble its sender as the description; a 1:1 chat gives none, so the sender is the chat name.
//
// Current macOS builds have no "message-list". There the transcript is the group with
// identifier "TranscriptCollectionView", and each labelled child group is one bubble whose
// label reads like VoiceOver:
//
//   <sender>, <text>, <time>          (incoming; the sender is the chat name in a 1:1 chat)
//   Your iMessage, <text>, <time>     (outgoing; "Your SMS" and similar for other services)
//
// The bubble's text comes from its `CKBalloonTextView` text area when it has one, else from
// the label between sender and time (links, photos). Unlabelled children are timestamps,
// read receipts and reaction buttons, and are skipped.
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.MobileSMS"] },
};

const PARSER_ID = "messages/v1";
const TRANSCRIPT = '//List[identifier="message-list"]';
const BUBBLE_ROLES = ["TextArea", "StaticText"];
const LIVE_TRANSCRIPT = '//*[identifier="TranscriptCollectionView"]';
const BALLOON = '//TextArea[identifier="CKBalloonTextView"]';
// "Your iMessage, ", "Your SMS, ", "Your message, ".
const OUTGOING = /^Your [^,]{1,20}, /;
// "11:44", "4:02 PM", "Yesterday 11:44".
const TIME_TAIL = /, ((?:[^,]* )?\d{1,2}[:.]\d{2}(?:\s?[AP]M)?)$/i;

const trimmed = (v) => (typeof v === "string" ? v.trim() : "");

// Frames are screen coordinates, so compare against the window's own centre: a window moved
// to another screen keeps every bubble on the same side.
function isUserBubble(bubble, root) {
  const f = bubble.frame;
  const w = root.frame;
  if (!f || !w || !(w.width > 0)) return false;
  return f.x + f.width / 2 > w.x + w.width / 2;
}

function chatName(snapshot) {
  const title = trimmed(snapshot.window_title);
  if (title !== "") return title;
  const name = trimmed(snapshot.root.name);
  return name !== "" ? name : "unknown";
}

// One bubble of the current builds' transcript, from its VoiceOver label.
function liveBubble(group, chat, ctx) {
  let label = trimmed(ctx.node.label(group));
  if (label === "") return undefined;
  let sentAt;
  const t = label.match(TIME_TAIL);
  if (t) {
    sentAt = t[1];
    label = label.slice(0, t.index);
  }
  const out = OUTGOING.exec(label);
  let author;
  let rest;
  if (out) {
    author = "You";
    rest = label.slice(out[0].length);
  } else {
    const comma = label.indexOf(", ");
    if (comma <= 0) return undefined;
    author = label.slice(0, comma).trim() || chat;
    rest = label.slice(comma + 2);
  }
  const balloon = ctx.find(BALLOON, group);
  const text = trimmed(balloon && !ctx.node.isSecure(balloon) ? balloon.value : "") || rest.trim();
  if (text === "") return undefined;
  const m = { author, text, is_me: !!out, draft: false };
  if (sentAt !== undefined) m.sent_at = sentAt;
  return m;
}

function liveMessages(transcript, chat, ctx) {
  const groups = ctx.node.children(transcript).filter((n) => !ctx.node.isSecure(n));
  const out = [];
  for (const g of ctx.sortedByVisualOrder(groups, transcript.frame)) {
    const m = liveBubble(g, chat, ctx);
    if (m !== undefined) out.push(m);
  }
  return out;
}

function listMessages(transcript, root, chat, ctx) {
  const found = ctx.node.allWhere(
    transcript,
    (n) => BUBBLE_ROLES.includes(n.role) && !ctx.node.isSecure(n) && trimmed(n.value) !== "",
  );
  const messages = [];
  for (const bubble of ctx.sortedByVisualOrder(found, transcript.frame)) {
    const text = trimmed(bubble.value);
    const isMe = isUserBubble(bubble, root);
    let author = "You";
    if (!isMe) {
      const label = trimmed(ctx.node.label(bubble));
      author = (label !== "" ? ctx.senderLabel([label, text]) : undefined) ?? chat;
    }
    messages.push({ author, text, is_me: isMe, draft: false });
  }
  return messages;
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const chat = chatName(snapshot);
  let messages;
  const transcript = ctx.find(TRANSCRIPT, root);
  if (transcript) {
    messages = listMessages(transcript, root, chat, ctx);
  } else {
    const live = ctx.find(LIVE_TRANSCRIPT, root);
    if (!live) return null;
    messages = liveMessages(live, chat, ctx);
  }
  if (messages.length === 0) return null;

  // A 1:1 chat has one other sender; a group chat's bubbles name several.
  const others = new Set(messages.filter((m) => !m.is_me).map((m) => m.author));
  const content = { kind: "conversation", title: chat, is_group: others.size > 1, messages };
  return ctx.item(snapshot, PARSER_ID, `imessage:${ctx.slug(chat) || "unknown"}`, chat, undefined, content);
}
