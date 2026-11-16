// Terminal emulators (Terminal.app, Warp, iTerm2).
//
// A terminal exposes its whole scrollback as one text area. The parser learns one prompt
// shape from the first prompt-looking line, splits the buffer into commands and their output
// on that shape only, and keeps the newest segments within a character cap.

export const meta = {
  api: 1,
  kind: "parser",
  match: {
    bundleIds: ["com.apple.Terminal", "dev.warp.Warp-Stable", "dev.warp.Warp", "com.googlecode.iterm2"],
  },
};

// Rendered characters kept per capture. Oldest segments go first.
const CONTENT_CAP = 8000;

// A prompt terminator that may follow a path or `user@host path`.
const PROMPT_CHARS = ["%", "$", "#", ">", "❯"];
// Characters that end a path component run in a prompt or title.
const PATH_STOP_CHARS = [" ", "\t", "\n", ":", "%", "$", "#", ">", "❯"];

// Rust `char::is_whitespace` (Unicode White_Space), which differs from JS `\s`.
const isWs = (c) =>
  c === " " || (c >= "\t" && c <= "\r") || c === "\u0085" || c === " " || c === " " ||
  (c >= " " && c <= " ") || c === " " || c === " " || c === " " ||
  c === " " || c === "　";

const isAlnum = (c) => /^[\p{Alphabetic}\p{N}]$/u.test(c);

const chars = (s) => [...s];

// Rust `str::lines`: split on "\n", drop one trailing "\r" per terminated line, and no empty
// final line after a trailing "\n".
const rustLines = (s) => {
  const parts = s.split("\n");
  const last = parts.length - 1;
  if (parts[last] === "") parts.pop();
  return parts.map((p, i) => (i < last && p.endsWith("\r") ? p.slice(0, -1) : p));
};

// Terminal's own slug: trimmed, lowercased, spaces to dashes.
const slug = (s) => s.trim().toLowerCase().split(" ").join("-");

const isPromptChar = (c) => PROMPT_CHARS.includes(c);

// One command and what it printed. `command` is undefined for output before the first prompt
// and for a buffer whose prompt could not be learned.
const segmentLines = (seg) => {
  const out = [];
  if (seg.command !== undefined) out.push(`$ ${seg.command}`);
  const output = seg.output.replace(/\n+$/, "");
  if (output !== "") out.push(output);
  return out;
};
const segmentText = (seg) => segmentLines(seg).join("\n");

// Where a prompt of `shape` ends in `line` (an array of chars), if the line starts with one.
const promptHeadEnd = (line, shape) => {
  if (shape === "userHost") {
    // `^\S+@\S+\s`: the first word holds an `@` with text on both sides, then whitespace.
    const wordEnd = line.findIndex(isWs);
    if (wordEnd < 0) return undefined;
    let qualifies = false;
    for (let i = 0; i < wordEnd; i++) {
      if (line[i] === "@" && i > 0 && i + 1 < wordEnd) qualifies = true;
    }
    return qualifies ? wordEnd + 1 : undefined;
  }
  // `^[~/]\S* [%$❯](\s|$)`
  if (line[0] !== "~" && line[0] !== "/") return undefined;
  const wordEnd = line.findIndex(isWs);
  if (wordEnd < 0) return undefined;
  if (line[wordEnd] !== " ") return undefined;
  const terminator = line[wordEnd + 1];
  if (terminator === undefined) return undefined;
  if (terminator !== "%" && terminator !== "$" && terminator !== "❯") return undefined;
  const after = line[wordEnd + 2];
  if (after === undefined) return wordEnd + 2;
  if (isWs(after)) return wordEnd + 3;
  return undefined;
};

// The shape of the first line that looks like a prompt. Every later split uses that one
// shape, so a path printed by a command cannot start a segment.
const promptShape = (lines) => {
  for (const line of lines) {
    const cs = chars(line);
    for (const shape of ["userHost", "path"]) {
      if (promptHeadEnd(cs, shape) !== undefined) return shape;
    }
  }
  return undefined;
};

const trimBlanks = (s) => s.replace(/^[ \t]+/, "").replace(/[ \t]+$/, "");

// What the user typed on a prompt line: empty for an idle prompt, undefined for an output line.
const commandText = (line, shape) => {
  const cs = chars(line);
  const head = promptHeadEnd(cs, shape);
  if (head === undefined) return undefined;
  let rest = cs.slice(Math.min(head, cs.length));
  if (shape === "userHost") {
    // Only `user@host ` was consumed. The cwd and the terminator follow it. The path
    // shape already consumed its terminator, so it must not be stripped twice.
    for (let i = 0; i < rest.length; i++) {
      if (isPromptChar(rest[i]) && (i + 1 >= rest.length || isWs(rest[i + 1]))) {
        rest = rest.slice(Math.min(i + 2, rest.length));
        break;
      }
    }
  }
  return trimBlanks(rest.join(""));
};

// Splits a scrollback blob into segments on the learned prompt shape.
const segments = (blob) => {
  const lines = blob.split("\n");
  const shape = promptShape(lines);
  if (shape === undefined) {
    // A full-screen program, a pager or an unknown prompt theme.
    return [{ command: undefined, output: blob, running: false }];
  }
  const out = [];
  let preamble = [];
  let open = null; // { command, output: [] }

  const flush = (running) => {
    if (open !== null) {
      out.push({ command: open.command, output: open.output.join("\n"), running });
      open = null;
    } else if (preamble.length > 0) {
      out.push({ command: undefined, output: preamble.join("\n"), running: false });
      preamble = [];
    }
  };

  for (const line of lines) {
    const command = commandText(line, shape);
    if (command === undefined) {
      if (open !== null) open.output.push(line);
      else preamble.push(line);
      continue;
    }
    flush(false);
    // An idle prompt closes the previous segment and opens nothing.
    open = command !== "" ? { command, output: [] } : null;
  }
  // Still open at the end means no trailing prompt, so the command has not returned.
  flush(open !== null);
  return out;
};

// The first `~` or `/Users/<name>` path at or after `from`, with its trailing components.
// Returns char indices [start, end] of the match.
const USERS = chars("/Users/");
const findPath = (cs, from) => {
  const allowed = (c) => !PATH_STOP_CHARS.includes(c);
  for (let start = from; start < cs.length; start++) {
    let end;
    if (cs[start] === "~") {
      end = start + 1;
    } else if (USERS.every((c, k) => cs[start + k] === c)) {
      const nameStart = start + 7;
      let nameLen = 0;
      while (nameStart + nameLen < cs.length && cs[nameStart + nameLen] !== "/" && cs[nameStart + nameLen] !== " ") {
        nameLen += 1;
      }
      if (nameLen === 0) continue;
      end = nameStart + nameLen;
    } else {
      continue;
    }
    // `(/[^ \t\n:%$#>❯]+)*`
    while (cs[end] === "/" && cs[end + 1] !== undefined && allowed(cs[end + 1])) {
      end += 1;
      while (cs[end] !== undefined && allowed(cs[end])) end += 1;
    }
    return [start, end];
  }
  return undefined;
};

// The full cwd path, read from the window title only. Prompt text is untrusted captured
// content and does not decide the session's directory.
const cwdPath = (windowTitle) => {
  if (windowTitle === undefined || windowTitle === null) return undefined;
  const title = chars(windowTitle);
  const found = findPath(title, 0);
  if (found === undefined) return undefined;
  return title.slice(found[0], found[1]).join("");
};

// The final component of a `~/...` or `/Users/...` path, slugged. With `requirePrompt` the
// path must be followed by a prompt terminator, so file arguments and paths in output are not
// mistaken for the shell's directory.
const lastPathComponent = (s, requirePrompt) => {
  const cs = chars(s);
  let from = 0;
  let start;
  let end;
  for (;;) {
    const found = findPath(cs, from);
    if (found === undefined) return undefined;
    [start, end] = found;
    if (!requirePrompt) break;
    const after = cs.slice(end).find((c) => !isWs(c));
    if (after !== undefined && isPromptChar(after)) break;
    from = start + 1;
  }
  const path = cs.slice(start, end).join("");
  const last = path.split("/").reverse().find((c) => c !== "");
  if (last === undefined) return undefined;
  // A real cwd rarely looks like a file name.
  const lc = chars(last);
  const dot = lc.lastIndexOf(".");
  if (dot > 0) {
    const ext = lc.slice(dot + 1);
    if (ext.length <= 5 && ext.every(isAlnum)) return undefined;
  }
  return slug(last);
};

// The thread key: the app plus the directory of the most recent prompt, else of the
// window title, else the bare app. Titles of full-screen programs change on every read,
// so they are never used as a key.
const threadKey = (appName, scrollbackText, windowTitle) => {
  const app = slug(appName);
  let dir;
  const lines = rustLines(scrollbackText);
  for (let i = lines.length - 1; i >= 0; i--) {
    dir = lastPathComponent(lines[i], true);
    if (dir !== undefined) break;
  }
  if (dir === undefined && windowTitle !== undefined && windowTitle !== null) {
    dir = lastPathComponent(windowTitle, false);
  }
  return dir !== undefined ? `terminal:${app}/${dir}` : `terminal:${app}`;
};

// The scrollback: the longest non-empty text area. Small text areas are search boxes.
const scrollback = (snapshot, ctx) => {
  let best;
  let bestLen = 0;
  for (const node of ctx.findAll("//TextArea", snapshot.root)) {
    if (ctx.node.isSecure(node)) continue;
    const v = node.value;
    if (v === undefined || v === null || v === "") continue;
    const len = chars(v).length;
    if (best === undefined || len > bestLen) {
      best = v;
      bestLen = len;
    }
  }
  return best;
};

// Drops the oldest segments until the text fits `cap`, keeping at least one. A single
// segment that is still too long keeps its tail. Returns the text and whether it was cut.
const bound = (segs, cap) => {
  const cost = (s) => chars(segmentText(s)).length + 1;
  let total = Math.max(0, segs.reduce((n, s) => n + cost(s), 0) - 1);
  let cut = false;
  while (segs.length > 1 && total > cap) {
    total = Math.max(0, total - cost(segs.shift()));
    cut = true;
  }
  let text = segs.map(segmentText).filter((t) => t !== "").join("\n");
  const cs = chars(text);
  if (cs.length > cap) {
    text = cs.slice(cs.length - cap).join("");
    cut = true;
  }
  return [text, cut];
};

export function parse(snapshot, ctx) {
  const blob = scrollback(snapshot, ctx);
  if (blob === undefined) return null;
  const title = snapshot.window_title;
  const [text, truncated] = bound(segments(blob), CONTENT_CAP);
  const docTitle = cwdPath(title) ?? title ?? "";
  const out = ctx.item(
    snapshot,
    "terminal/v1",
    threadKey(snapshot.app.name, blob, title),
    docTitle === "" ? snapshot.app.name : docTitle,
    undefined,
    { kind: "document", title: docTitle, text },
  );
  // Terminal items never carry a URL.
  delete out.url;
  out.truncated = truncated;
  return out;
}
