// The ctx helper library handed to every rule as its last argument.
// A file starting with "_" is a library, not a rule. This one is evaluated once per runtime
// with the native URL helpers and returns the ctx object (rule API version 1).
(function (native) {
  "use strict";

  // ---- nodes -------------------------------------------------------------------------

  const attr = (n, key) => (n.attrs && n.attrs[key] !== undefined ? n.attrs[key] : undefined);
  const label = (n) => attr(n, "label");
  const subrole = (n) => attr(n, "subrole");
  const identifier = (n) => attr(n, "identifier");
  const nodeUrl = (n) => attr(n, "url");
  const domId = (n) => attr(n, "dom_id");
  const placeholder = (n) => attr(n, "placeholder");
  const headingLevel = (n) => {
    const v = attr(n, "heading_level");
    if (v === undefined || !/^[0-9]+$/.test(v)) return undefined;
    const num = Number(v);
    return num <= 255 ? num : undefined;
  };
  const domClasses = (n) => {
    const raw = attr(n, "dom_classes");
    return raw ? raw.split(/\s+/).filter((c) => c !== "") : [];
  };
  const hasClass = (n, cls) => {
    const want = cls.toLowerCase();
    return domClasses(n).some((c) => c.toLowerCase() === want);
  };
  const hasClassContaining = (n, fragment) => {
    const needle = fragment.toLowerCase();
    return domClasses(n).some((c) => c.toLowerCase().includes(needle));
  };
  // A secure input is the secure role, or any role whose subrole contains "secure".
  const isSecure = (n) => {
    if (n.role === "SecureTextField") return true;
    const s = subrole(n);
    return s !== undefined && s.toLowerCase().includes("secure");
  };
  const isMenuRole = (role) =>
    role === "Menu" || role === "MenuBar" || role === "MenuBarItem" || role === "MenuItem" || role === "MenuButton";
  const children = (n) => n.children || [];

  const walk = (node, fn) => {
    fn(node);
    for (const c of children(node)) walk(c, fn);
  };
  const allWhere = (root, pred) => {
    const out = [];
    walk(root, (n) => {
      if (pred(n)) out.push(n);
    });
    return out;
  };

  // ---- path queries --------------------------------------------------------------------
  // `/Role` direct children, `//Role` any descendant, `*` any role, `[n]` zero-based index,
  // `[attr op "value"]` with op `=`, `^=` or `*=`. A malformed path matches nothing.

  const ATTRS = {
    role: "role",
    subrole: "subrole",
    title: "title",
    name: "title",
    description: "label",
    label: "label",
    value: "value",
    identifier: "identifier",
    domId: "domId",
    domClass: "domClass",
  };

  const parsePredicate = (body) => {
    for (const [token, op] of [["^=", "prefix"], ["*=", "contains"], ["=", "equals"]]) {
      const at = body.indexOf(token);
      if (at < 0) continue;
      const attribute = ATTRS[body.slice(0, at)];
      if (attribute === undefined) return null;
      const rest = body.slice(at + token.length);
      if (rest.length < 2 || !rest.startsWith('"') || !rest.endsWith('"')) return null;
      return { attribute, op, expected: rest.slice(1, rest.length - 1) };
    }
    return null;
  };

  const pathCache = new Map();
  const parsePath = (path) => {
    if (pathCache.has(path)) return pathCache.get(path);
    const steps = parsePathUncached(path);
    pathCache.set(path, steps);
    return steps;
  };
  const parsePathUncached = (path) => {
    if (path === "" || path[0] !== "/") return null;
    const chars = [...path];
    let i = 0;
    const steps = [];
    while (i < chars.length) {
      if (chars[i] !== "/") return null;
      i += 1;
      let axis = "child";
      if (i < chars.length && chars[i] === "/") {
        axis = "descendant";
        i += 1;
      }
      let role = null;
      if (i < chars.length && chars[i] === "*") {
        i += 1;
      } else {
        let token = "";
        while (i < chars.length && /[\p{L}\p{N}_]/u.test(chars[i])) {
          token += chars[i];
          i += 1;
        }
        if (token === "") return null;
        role = token;
      }
      const predicates = [];
      let index = null;
      while (i < chars.length && chars[i] === "[") {
        i += 1;
        const close = chars.indexOf("]", i);
        if (close < 0) return null;
        const body = chars.slice(i, close).join("");
        i = close + 1;
        if (body !== "" && /^[0-9]+$/.test(body)) {
          if (index !== null) return null;
          index = Number(body);
        } else {
          const p = parsePredicate(body);
          if (p === null) return null;
          predicates.push(p);
        }
      }
      steps.push({ axis, role, predicates, index });
      if (i < chars.length && chars[i] !== "/") return null;
    }
    return steps.length === 0 ? null : steps;
  };

  const attributeValues = (n, attribute) => {
    switch (attribute) {
      case "role":
        return [n.role];
      case "subrole": {
        const v = subrole(n);
        return v === undefined ? [] : [v];
      }
      case "title":
        return n.name === undefined || n.name === null ? [] : [n.name];
      case "label": {
        const v = label(n);
        return v === undefined ? [] : [v];
      }
      case "value":
        return n.value === undefined || n.value === null ? [] : [n.value];
      case "identifier": {
        const v = identifier(n);
        return v === undefined ? [] : [v];
      }
      case "domId": {
        const v = domId(n);
        return v === undefined ? [] : [v];
      }
      default:
        return domClasses(n);
    }
  };

  const matchesPredicate = (n, p) => {
    const insensitive = p.attribute === "domClass";
    const expected = insensitive ? p.expected.toLowerCase() : p.expected;
    return attributeValues(n, p.attribute).some((raw) => {
      const actual = insensitive ? raw.toLowerCase() : raw;
      if (p.op === "equals") return actual === expected;
      if (p.op === "prefix") return actual.startsWith(expected);
      return actual.includes(expected);
    });
  };
  const satisfies = (n, step) => {
    if (step.role !== null && n.role !== step.role) return false;
    return step.predicates.every((p) => matchesPredicate(n, p));
  };

  const findAll = (path, root) => {
    const steps = parsePath(path);
    if (steps === null) return [];
    let current = [root];
    for (const step of steps) {
      const produced = [];
      if (step.axis === "child") {
        for (const source of current) {
          for (const child of children(source)) if (satisfies(child, step)) produced.push(child);
        }
      } else {
        const sources = new Set(current);
        const visit = (node, inside) => {
          if (inside && satisfies(node, step)) produced.push(node);
          const nextInside = inside || sources.has(node);
          for (const child of children(node)) visit(child, nextInside);
        };
        visit(root, false);
      }
      current = step.index !== null ? (step.index < produced.length ? [produced[step.index]] : []) : produced;
      if (current.length === 0) return [];
    }
    return current;
  };
  const find = (path, root) => {
    const all = findAll(path, root);
    return all.length > 0 ? all[0] : undefined;
  };

  // ---- ordering and text collection -------------------------------------------------------

  // Sort by (y, x) relative to `origin` (a frame). Equal positions keep their input order.
  const sortedByVisualOrder = (nodes, origin) => {
    const ox = origin ? origin.x : 0;
    const oy = origin ? origin.y : 0;
    const keyed = nodes.map((n, i) => ({
      n,
      i,
      y: (n.frame ? n.frame.y : oy) - oy,
      x: (n.frame ? n.frame.x : ox) - ox,
    }));
    keyed.sort((a, b) => (a.y < b.y ? -1 : a.y > b.y ? 1 : a.x < b.x ? -1 : a.x > b.x ? 1 : a.i - b.i));
    return keyed.map((k) => k.n);
  };

  // Trimmed static-text values under `node` in visual order, empties dropped, adjacent
  // duplicates collapsed. Menu, hidden and secure subtrees are skipped.
  const collectStaticTexts = (node) => {
    const found = [];
    const visit = (n) => {
      if (isMenuRole(n.role) || n.hidden || isSecure(n)) return;
      if (n.role === "StaticText") found.push(n);
      for (const c of children(n)) visit(c);
    };
    visit(node);
    const out = [];
    for (const n of sortedByVisualOrder(found, node.frame)) {
      if (n.value === undefined || n.value === null) continue;
      const v = n.value.trim();
      if (v === "") continue;
      if (out.length === 0 || out[out.length - 1] !== v) out.push(v);
    }
    return out;
  };

  // ---- text and message helpers (shared by the web-app parsers) -----------------------------

  // The readable text of an anchor node: the first non-blank of value, name and label, trimmed.
  // Live AX trees report missing values as "", so a blank value must not hide the name. A secure
  // node never yields text.
  const textOf = (n) => {
    if (isSecure(n)) return undefined;
    for (const raw of [n.value, n.name, label(n)]) {
      if (typeof raw !== "string") continue;
      const t = raw.trim();
      if (t !== "") return t;
    }
    return undefined;
  };

  const editorText = (n) => {
    if (isSecure(n)) return "";
    if (n.value !== undefined && n.value !== null && n.value.trim() !== "") return n.value.trim();
    return collectStaticTexts(n).join("\n").trim();
  };

  const draftMessage = (text) => ({ author: "You", text, is_me: true, draft: true });

  const draft = (composer) => {
    if (!composer || isSecure(composer)) return undefined;
    const text = editorText(composer);
    return text !== "" ? draftMessage(text) : undefined;
  };

  const senderLabel = (values) => {
    if (values.length === 0) return undefined;
    const first = values[0];
    return values.length > 1 && [...first].length <= 80 && !first.includes("\n") ? first : undefined;
  };

  // Maps the `[user]` marker to ["You", true].
  const resolveUser = (sender) =>
    sender !== undefined && sender !== null && sender.toLowerCase() === "[user]" ? ["You", true] : [sender, false];

  const message = (sender, time, texts, isUser) => {
    const values = texts.map((t) => t.trim()).filter((t) => t !== "");
    let author;
    let body;
    if (sender !== undefined && sender !== null && sender !== "") {
      author = sender;
      body = values;
    } else {
      const lab = senderLabel(values);
      if (lab !== undefined) {
        author = lab;
        body = values.slice(1);
      } else {
        author = undefined;
        body = values;
      }
    }
    const text = body.join(" ");
    if (text === "") return undefined;
    const sentAt = time !== undefined && time !== null && time.trim() !== "" ? time.trim() : undefined;
    const m = { text, is_me: isUser, draft: false };
    if (author !== undefined) m.author = author;
    if (sentAt !== undefined) m.sent_at = sentAt;
    return m;
  };

  const focusedComposerDraft = (root) => {
    const find1 = (n, inList) => {
      if (isMenuRole(n.role)) return undefined;
      const nowInList = inList || n.role === "List" || n.role === "Table" || n.role === "Outline";
      if (n.focused && (n.role === "TextArea" || n.role === "TextField") && !isSecure(n) && !nowInList) return n;
      for (const c of children(n)) {
        const r = find1(c, nowInList);
        if (r) return r;
      }
      return undefined;
    };
    const field = find1(root, false);
    if (!field) return undefined;
    const text = (field.value ?? "").trim();
    return text !== "" ? draftMessage(text) : undefined;
  };

  // Static-text values under `root` in visual order, skipping every subtree where `skip(n)`
  // is true. Keeps adjacent duplicates.
  const staticTextsExcluding = (root, skip) => {
    const found = [];
    const visit = (n) => {
      if (isMenuRole(n.role) || n.hidden || isSecure(n) || skip(n)) return;
      if (n.role === "StaticText") found.push(n);
      for (const c of children(n)) visit(c);
    };
    visit(root);
    return sortedByVisualOrder(found, root.frame)
      .map((n) => n.value)
      .filter((v) => v !== undefined && v !== null)
      .map((v) => v.trim())
      .filter((v) => v !== "");
  };

  // Descendant text of the given roles in visual order with adjacent duplicates dropped. A
  // matching node with usable text is not descended into.
  const orderedDescendantText = (node, roles) => {
    const found = [];
    const visit = (n) => {
      if (isMenuRole(n.role) || n.hidden || isSecure(n)) return;
      if (roles.includes(n.role)) {
        const text = textOf(n);
        if (text !== undefined) {
          found.push({ n, text });
          return;
        }
      }
      for (const c of children(n)) visit(c);
    };
    for (const c of children(node)) visit(c);
    const keyed = found.map((f, i) => ({
      f,
      i,
      y: f.n.frame ? f.n.frame.y : 0,
      x: f.n.frame ? f.n.frame.x : 0,
    }));
    keyed.sort((a, b) => (a.y < b.y ? -1 : a.y > b.y ? 1 : a.x < b.x ? -1 : a.x > b.x ? 1 : a.i - b.i));
    const out = [];
    for (const k of keyed) if (out.length === 0 || out[out.length - 1] !== k.f.text) out.push(k.f.text);
    return out;
  };

  const rowCells = (row) => orderedDescendantText(row, ["Cell", "StaticText", "TextField", "TextArea"]);

  const windowTitle = (snapshot) => {
    const t = (snapshot.window_title ?? "").trim();
    return t === "" ? undefined : t;
  };

  // The first " - " part of a title that looks like an email address.
  const emailInTitle = (title) =>
    title
      .split(" - ")
      .map((p) => p.trim())
      .find((p) => p.includes("@") && !/\s/.test(p));

  const pageFromRows = (rows) => ({ kind: "page", title: "", text: rows.join("\n") });

  // Builds a capture item with the redacted URL. `fields` carries threadKey, threadTitle,
  // account (optional) and content.
  const item = (snapshot, parser, threadKey, threadTitle, account, content) => {
    const out = { app: snapshot.app };
    if (snapshot.url !== undefined && snapshot.url !== null) out.url = native.redact(snapshot.url);
    if (snapshot.window_title !== undefined && snapshot.window_title !== null) out.window_title = snapshot.window_title;
    out.thread_key = threadKey;
    out.thread_title = threadTitle;
    if (account !== undefined && account !== null) out.account = account;
    out.content = content;
    out.parser = parser;
    out.truncated = !!snapshot.truncated;
    return out;
  };

  // ---- thread keys -------------------------------------------------------------------------

  // Lowercase, trimmed, whitespace and "/" collapsed to "-", leading "#" and "@" removed.
  const slug = (input) => {
    let s = input.trim();
    s = s.replace(/^[#@]+/, "").trim();
    let out = "";
    let lastDash = false;
    for (const ch of [...s.toLowerCase()]) {
      if (/\s/.test(ch) || ch === "/") {
        if (!lastDash && out !== "") {
          out += "-";
          lastDash = true;
        }
      } else {
        out += ch;
        lastDash = false;
      }
    }
    return out.replace(/-+$/, "");
  };

  const COUNTER_WORDS = new Set([
    "new", "item", "items", "unread", "message", "messages", "mention", "mentions",
    "notification", "notifications", "reply", "replies",
  ]);
  // True for window-title fragments that are counters, not names: "3 new items", "(5)".
  const isCounterFragment = (part) => {
    const p = part.trim().toLowerCase();
    if (p === "") return false;
    const stripped = p.replace(/^\(+/, "").replace(/\)+$/, "");
    if (stripped !== "" && /^[0-9+]+$/.test(stripped)) return true;
    const words = stripped.split(/\s+/).filter((w) => w !== "");
    const first = words.length > 0 ? words[0] : "";
    const rest = words.slice(1);
    const numeric = first !== "" && /^[0-9+]+$/.test(first);
    return numeric && rest.length > 0 && rest.every((w) => COUNTER_WORDS.has(w));
  };

  return {
    api: 1,
    url: {
      redact: native.redact,
      host: native.host,
      hostMatches: native.hostMatches,
      normalize: native.normalize,
    },
    node: {
      attr, label, subrole, identifier, url: nodeUrl, domId, placeholder, headingLevel,
      domClasses, hasClass, hasClassContaining, isSecure, isMenuRole, children, walk, allWhere,
    },
    find, findAll, sortedByVisualOrder, collectStaticTexts,
    textOf, editorText, draft, senderLabel, resolveUser, message, focusedComposerDraft,
    staticTextsExcluding, orderedDescendantText, rowCells, windowTitle, emailInTitle,
    pageFromRows, item,
    slug, isCounterFragment,
  };
})
