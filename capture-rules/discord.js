// Discord, the desktop app (Electron) and discord.com. Ported from MaxMi's DiscordParser.
//
// The transcript is the list whose description (or identifier) contains "Messages in". Its
// frames are unreliable (a virtualised list), so the groups are walked in tree order and
// geometry is never read. Each child of the list is one message group: its first heading is
// the sender and every static text after it is one message. A group with no heading continues
// the previous group's sender, the way Discord shows consecutive messages from one person.
//
// The channel and server come from the window title, "#<channel> | <server> - Discord".
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.hnc.Discord"], hosts: ["discord.com", "www.discord.com"] },
};

const PARSER_ID = "discord/v1";
const LIST_MARKER = "Messages in";
// Static texts that are buttons and badges, not message text.
const CHROME = new Set([
  "Add Reaction", "More", "Message", "Edited", "Reply", "Forward", "React", "Add a reaction", "Text Channel",
]);

// The first non-blank of value and name. Live trees report a missing value as "".
function ownText(n) {
  for (const raw of [n.value, n.name]) {
    if (typeof raw !== "string") continue;
    const t = raw.trim();
    if (t !== "") return t;
  }
  return undefined;
}

// Static texts and headings under `node` in tree order. Secure subtrees are skipped. Texts
// inside a heading are marked so they are never read as a message body.
function textNodes(node, ctx) {
  const out = [];
  const visit = (n, inHeading) => {
    if (ctx.node.isSecure(n)) return;
    if (n.role === "StaticText" || n.role === "Heading") {
      const value = ownText(n);
      if (value !== undefined) out.push({ role: n.role, value, inHeading });
    }
    const nowInHeading = inHeading || n.role === "Heading";
    for (const c of ctx.node.children(n)) visit(c, nowInHeading);
  };
  visit(node, false);
  return out;
}

function messageList(root, ctx) {
  return (
    ctx.find(`//List[label*="${LIST_MARKER}"]`, root) ??
    ctx.find(`//List[identifier*="${LIST_MARKER}"]`, root)
  );
}

function messagesOf(list, ctx) {
  const out = [];
  let lastSender;
  for (const group of ctx.node.children(list)) {
    const values = textNodes(group, ctx);
    // A heading with no text of its own is labelled by the static text inside it.
    const heading = values.find((v) => v.role === "Heading" || v.inHeading);
    const bodies = values
      .filter((v) => v.role === "StaticText" && !v.inHeading)
      .map((v) => v.value)
      .filter((v) => !CHROME.has(v) && [...v].length > 1);
    const headingSender = heading ? ctx.senderLabel([heading.value, ...bodies.slice(0, 1)]) : undefined;
    if (headingSender !== undefined) lastSender = headingSender;
    const sender = headingSender ?? lastSender;
    for (const text of bodies) {
      const m = { text, is_me: false, draft: false };
      if (sender !== undefined) m.author = sender;
      out.push(m);
    }
  }
  return out;
}

// "#general | Acme - Discord" -> { channel: "general", server: "Acme" }; a DM title
// ("@someone - Discord", "Friends - Discord") has no server.
function splitTitle(title) {
  let head = title;
  const at = head.lastIndexOf(" - Discord");
  if (at >= 0) head = head.slice(0, at);
  const parts = head.split(" | ");
  const clean = (s) => s.replace(/^[#\s]+|[#\s]+$/g, "");
  if (parts.length >= 2) return { channel: clean(parts[0]), server: clean(parts[1]) };
  return { channel: clean(head), server: undefined };
}

export function parse(snapshot, ctx) {
  const root = snapshot.root;
  const list = messageList(root, ctx);
  if (!list) return null;
  const messages = messagesOf(list, ctx);
  if (messages.length === 0) return null;

  const title = ctx.windowTitle(snapshot) ?? ownText(root);
  let channel = "unknown";
  let key = "discord:unknown";
  if (title !== undefined) {
    const parts = splitTitle(title);
    if (parts.channel !== "") channel = parts.channel;
    key =
      parts.server !== undefined
        ? `discord:${ctx.slug(parts.server)}/${ctx.slug(parts.channel)}`
        : `discord:${ctx.slug(parts.channel) || "unknown"}`;
  }
  const content = { kind: "conversation", title: channel, is_group: true, messages };
  return ctx.item(snapshot, PARSER_ID, key, title ?? channel, undefined, content);
}
