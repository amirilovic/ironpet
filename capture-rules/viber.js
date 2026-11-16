// Viber for macOS (Qt Quick). Its accessibility tree has the open chat's messages as text
// fields, but never the chat's name: the header is drawn without an accessible element, the
// window title is always "Rakuten Viber" and the chat list is not exposed at all. So this rule
// asks lookback to read the header strip from the screen (`ocrRegions`) and keys the thread by
// the name read there. Without the Screen Recording permission there is no name, and the
// generic rule stores the window as before.
//
// Shape (identifiers are QML type paths; only their stable parts are matched):
//   Group  …StackView_QMLTYPE…                the open chat, header at its top
//     Button …SearchButton… / …InfoButton…    header buttons, right of the chat name
//     TextField …FeedDelegate…TextEditItem…   one per message; the user's own sit right
//     TextField …QQuickTextEdit…              the composer
export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.viber.osx"] },
};

const PARSER_ID = "viber/v1";
const PANE = `//Group[identifier*="StackView_QMLTYPE"]`;
const MESSAGE = "TextEditItem_QMLTYPE";
const COMPOSER = "QQuickTextEdit";
// The header strip under the pane's top edge: avatar, then the name and a subtitle line.
const HEADER_HEIGHT = 84;
const AVATAR_WIDTH = 80;
// A group's subtitle lists members ("Ana, Bo, Cy") or counts them ("12 members"). A direct
// chat's is a phone number or a presence line ("Last seen yesterday at 20:49", "Online").
const GROUP_SUBTITLE = /, |\b\d+\s+(members|participants)\b/i;

const clean = (s) =>
  typeof s === "string" ? s.replace(/[‎‏‪-‮⁦-⁩]/g, "").trim() : "";

function pane(root, ctx) {
  return ctx.find(PANE, root);
}

// The left edge of the header buttons (search, call, info), or the pane's right edge.
function headerRight(p) {
  const top = p.frame.y + HEADER_HEIGHT;
  let right = p.frame.x + p.frame.width;
  for (const c of p.children ?? []) {
    const f = c.frame;
    if (!f || f.y >= top) continue;
    if (c.role === "Button" || c.role === "CheckBox") right = Math.min(right, f.x);
  }
  return right;
}

export function ocrRegions(snapshot, ctx) {
  const p = pane(snapshot.root, ctx);
  if (!p || !p.frame) return [];
  const x = p.frame.x + AVATAR_WIDTH;
  const width = headerRight(p) - 8 - x;
  if (width < 40) return [];
  return [{ name: "header", x, y: p.frame.y, width, height: HEADER_HEIGHT }];
}

export function parse(snapshot, ctx) {
  const lines = (snapshot.ocr?.header ?? []).map(clean).filter((l) => l.length > 1);
  const chat = lines[0] ?? "";
  if (chat === "") return null;
  const subtitle = lines[1] ?? "";
  const direct = !GROUP_SUBTITLE.test(subtitle);

  const root = snapshot.root;
  const p = pane(root, ctx) ?? root;
  const middle = p.frame ? p.frame.x + p.frame.width / 2 : undefined;
  const bubbles = ctx.sortedByVisualOrder(
    ctx.findAll(`//TextField[identifier*="${MESSAGE}"]`, p),
    p.frame,
  );
  const messages = [];
  for (const b of bubbles) {
    if (ctx.node.isSecure(b)) continue;
    const text = clean(ctx.textOf(b));
    if (text === "") continue;
    const f = b.frame;
    const isMe = middle !== undefined && f ? f.x + f.width / 2 > middle : false;
    const m = { text, is_me: isMe, draft: false };
    // A group's bubbles do not say who wrote them; a direct chat's are the other person's.
    if (isMe) m.author = "You";
    else if (direct) m.author = chat;
    messages.push(m);
  }
  const composer = ctx.find(`//TextField[identifier*="${COMPOSER}"]`, p);
  const draft = composer ? ctx.draft(composer) : undefined;
  if (draft !== undefined) messages.push(draft);
  if (messages.length === 0) return { refuse: "no-messages" };

  const content = { kind: "conversation", title: chat, is_group: !direct, messages };
  return ctx.item(snapshot, PARSER_ID, `viber:${ctx.slug(chat)}`, chat, undefined, content);
}
