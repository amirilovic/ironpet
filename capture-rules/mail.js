// Apple Mail.
//
// Mail's accessibility tree is far too slow to walk (about 80 ms per node), so mail is read
// through AppleScript. The platform adapter runs the script and stores its output on the root
// node under the `mail_script_output` attribute. The only thing read from the tree itself is
// a compose window, which becomes a draft.

export const meta = {
  api: 1,
  kind: "parser",
  match: { bundleIds: ["com.apple.mail"] },
};

// Rendered characters kept per capture. The oldest messages go first.
const CONTENT_CAP = 32000;
// First line of the script output for selected messages.
const STRUCTURED_HEADER = "LOOKBACK_MAIL_V2";
const RECORD_SEPARATOR = "\u001D";
const FIELD_SEPARATOR = "\u001E";
// The platform adapter stores the AppleScript output on the root node under this attribute
// when the window is a message viewer, so the parser stays a pure function of the snapshot.
const SCRIPT_OUTPUT_ATTR = "mail_script_output";
// The one accessibility attribute worth reading in Mail: the subject field of a compose window.
const SUBJECT_FIELD_IDENTIFIER = "Mail.subjectField";

const INBOX_KEY = "mail:inbox";

const charCount = (s) => [...s].length;
const nonEmpty = (s) => (s !== "" ? s : undefined);
const slug = (s) => s.split(/\s+/).filter(Boolean).join("-").toLowerCase();

// SHA-256 over the UTF-8 bytes of `input`, as lowercase hex. QuickJS has no crypto.
const SHA_K = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const utf8Bytes = (s) => {
  const out = [];
  for (const ch of s) {
    let c = ch.codePointAt(0);
    if (c >= 0xd800 && c <= 0xdfff) c = 0xfffd;
    if (c < 0x80) out.push(c);
    else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
    else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
  }
  return out;
};

const sha256Hex = (input) => {
  const bytes = utf8Bytes(input);
  const bitLen = bytes.length * 8;
  bytes.push(0x80);
  while (bytes.length % 64 !== 56) bytes.push(0);
  const hi = Math.floor(bitLen / 0x100000000);
  const lo = bitLen >>> 0;
  for (const w of [hi, lo]) bytes.push((w >>> 24) & 255, (w >>> 16) & 255, (w >>> 8) & 255, w & 255);
  const h = [0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
  const rotr = (x, n) => (x >>> n) | (x << (32 - n));
  const w = new Array(64);
  for (let off = 0; off < bytes.length; off += 64) {
    for (let i = 0; i < 16; i++) {
      const j = off + i * 4;
      w[i] = ((bytes[j] << 24) | (bytes[j + 1] << 16) | (bytes[j + 2] << 8) | bytes[j + 3]) | 0;
    }
    for (let i = 16; i < 64; i++) {
      const s0 = rotr(w[i - 15], 7) ^ rotr(w[i - 15], 18) ^ (w[i - 15] >>> 3);
      const s1 = rotr(w[i - 2], 17) ^ rotr(w[i - 2], 19) ^ (w[i - 2] >>> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) | 0;
    }
    let [a, b, c, d, e, f, g, hh] = h;
    for (let i = 0; i < 64; i++) {
      const t1 = (hh + (rotr(e, 6) ^ rotr(e, 11) ^ rotr(e, 25)) + ((e & f) ^ (~e & g)) + SHA_K[i] + w[i]) | 0;
      const t2 = ((rotr(a, 2) ^ rotr(a, 13) ^ rotr(a, 22)) + ((a & b) ^ (a & c) ^ (b & c))) | 0;
      hh = g; g = f; f = e; e = (d + t1) | 0; d = c; c = b; b = a; a = (t1 + t2) | 0;
    }
    const add = [a, b, c, d, e, f, g, hh];
    for (let i = 0; i < 8; i++) h[i] = (h[i] + add[i]) | 0;
  }
  return h.map((x) => (x >>> 0).toString(16).padStart(8, "0")).join("");
};

const hash24 = (input) => sha256Hex(input).slice(0, 24);

// How a message reads once rendered, used to size a capture against the cap.
const renderedLen = (m) => {
  const sender = m.is_me === true ? "You" : m.author ?? "unknown";
  let len = "(From: )".length + charCount(sender);
  if (m.draft) len += " (draft)".length;
  if (m.sent_at !== undefined) len += "(sent )".length + charCount(m.sent_at);
  // ": " plus the body, where each continuation line gains a two-space indent.
  return len + 2 + charCount(m.text) + 2 * (m.text.split("\n").length - 1);
};

// Drops the oldest messages until the capture fits `cap`, keeping at least one.
const bound = (messages, cap) => {
  let total = Math.max(0, messages.reduce((sum, m) => sum + renderedLen(m) + 1, 0) - 1);
  let start = 0;
  while (messages.length - start > 1 && total > cap) {
    total = Math.max(0, total - (renderedLen(messages[start]) + 1));
    start += 1;
  }
  return [messages.slice(start), start > 0];
};

const conversation = (title, messages) => {
  const [kept, truncated] = bound(messages, CONTENT_CAP);
  return [{ kind: "conversation", title, messages: kept }, truncated];
};

// The per-account inbox listing, one `account » sender | subject` line per message.
const inbox = (raw, threadTitle) => {
  const messages = raw
    .split("\n")
    .map((l) => l.trim())
    .filter((l) => l !== "")
    .map((line) => {
      const at = line.indexOf(" | ");
      const m = at >= 0 ? { author: line.slice(0, at), text: line.slice(at + 3) } : { text: line };
      m.is_me = false;
      m.draft = false;
      return m;
    });
  if (messages.length === 0) return undefined;
  const [content, truncated] = conversation("Inbox", messages);
  return { content, threadKey: INBOX_KEY, threadTitle: threadTitle ?? "Inbox", truncated };
};

const records = (raw) => {
  const payload = raw.slice(STRUCTURED_HEADER.length).trim();
  const out = [];
  for (const record of payload.split(RECORD_SEPARATOR)) {
    const fields = record.split(FIELD_SEPARATOR);
    if (fields.length < 5) continue;
    const r = {
      messageId: fields[0].trim(),
      sender: fields[1].trim(),
      subject: fields[2].trim(),
      date: fields[3].trim(),
      body: fields.slice(4).join(FIELD_SEPARATOR).trim(),
    };
    if (r.sender === "" && r.subject === "" && r.body === "") continue;
    out.push(r);
  }
  return out;
};

// One message per record, titled with the subject. The thread key hashes the message ids
// (or sender and subject when Mail gave no id), so it holds still while the user reads.
const selected = (raw, windowTitle) => {
  const recs = records(raw);
  if (recs.length === 0) return undefined;
  const messages = recs.map((r) => {
    const m = { text: r.body, is_me: false, draft: false };
    const author = nonEmpty(r.sender);
    if (author !== undefined) m.author = author;
    const sentAt = nonEmpty(r.date);
    if (sentAt !== undefined) m.sent_at = sentAt;
    return m;
  });
  const subject = recs.map((r) => r.subject).find((s) => s !== "");
  const identities = recs.map((r) => (r.messageId === "" ? `${r.sender}|${r.subject}` : r.messageId)).join("|");
  const title = subject ?? windowTitle ?? "message";
  const [content, truncated] = conversation(title, messages);
  return { content, threadKey: `mail:thread:${hash24(identities)}`, threadTitle: title, truncated };
};

// Turns AppleScript output into content: either a listing of recent inbox messages or the
// selected messages with their bodies. undefined when there is nothing to store.
const fromScriptOutput = (raw, windowTitle) => {
  const trimmed = raw.trim();
  return trimmed.startsWith(STRUCTURED_HEADER) ? selected(trimmed, windowTitle) : inbox(trimmed, windowTitle);
};

// A frontmost compose window as a single user draft, with the subject as the title.
// undefined for any other window, and for an untouched compose window.
const composeDraft = (root, subjectField, ctx) => {
  const subject = (subjectField.value ?? "").trim();
  // The compose body is the largest text area, and a compose window has no others.
  let body = "";
  for (const n of ctx.findAll("//TextArea", root)) {
    if (ctx.node.isSecure(n) || n.value === undefined || n.value === null) continue;
    const v = n.value.trim();
    if (charCount(v) > charCount(body)) body = v;
  }
  if (subject === "" && body === "") return undefined;
  const title = subject === "" ? "(no subject)" : subject;
  return {
    kind: "conversation",
    title,
    messages: [{ author: "You", text: body, is_me: true, draft: true }],
  };
};

export function parse(snapshot, ctx) {
  // Items carry no URL, and `truncated` comes from the extract, not the snapshot.
  const build = (threadKey, threadTitle, content, truncated) => {
    const out = ctx.item({ ...snapshot, url: undefined }, "mail/v1", threadKey, threadTitle, undefined, content);
    out.truncated = truncated;
    return out;
  };

  const raw = ctx.node.attr(snapshot.root, SCRIPT_OUTPUT_ATTR);
  if (raw !== undefined) {
    const e = fromScriptOutput(raw, snapshot.window_title);
    return e === undefined ? { refuse: "empty-mail" } : build(e.threadKey, e.threadTitle, e.content, e.truncated);
  }
  const subjectField = ctx.find(`//*[identifier="${SUBJECT_FIELD_IDENTIFIER}"]`, snapshot.root);
  // Reading mail goes through AppleScript, not the tree.
  if (!subjectField) return null;
  const content = composeDraft(snapshot.root, subjectField, ctx);
  if (content === undefined) return { refuse: "empty-compose-draft" };
  // Keyed on the subject only. Hashing the body would start a new thread per keystroke.
  return build(`mail:draft:${slug(content.title)}`, content.title, content, false);
}
