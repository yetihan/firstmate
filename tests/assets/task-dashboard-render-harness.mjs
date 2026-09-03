// Render a built task dashboard's shipped inline script under a minimal DOM
// shim and print what the page actually produced, so dashboard behavior is
// asserted through the real template rather than by reading its source.
//
// Usage: node task-dashboard-render-harness.mjs <built-dashboard.html>
// Prints one JSON document:
//   { stats:[{n,label}], sections:[{name,count,cards:[...]}], cards:[...],
//     empty:[...], foot:[...] }
import { readFileSync } from "node:fs";

const html = readFileSync(process.argv[2], "utf8");

class Node {
  constructor(tag) {
    this.tagName = tag;
    this.className = "";
    this.children = [];
    this._text = "";
    this.type = "";
    this.value = "";
    this.href = "";
  }
  get textContent() {
    return this.children.length
      ? this.children.map((c) => c.textContent).join("")
      : this._text;
  }
  set textContent(v) { this._text = String(v); this.children = []; }
  appendChild(n) { n.parentNode = this; this.children.push(n); return n; }
  replaceChildren(...nodes) {
    this.children = [];
    nodes.forEach((n) => this.appendChild(n));
  }
  setAttribute(k, v) { this["attr_" + k] = v; }
  addEventListener() {}
}

const byId = new Map();
const dataNode = new Node("script");
dataNode.textContent = html
  .split('<script id="task-dashboard-data" type="application/json">')[1]
  .split("</script>")[0];
byId.set("task-dashboard-data", dataNode);

globalThis.document = {
  createElement: (tag) => new Node(tag),
  createTextNode: (text) => {
    const n = new Node("#text");
    n.textContent = text;
    return n;
  },
  // Lazily mint any element the page asks for: the shim tracks whatever ids
  // the shipped template actually uses instead of pinning a fixed list.
  getElementById: (id) => {
    if (!byId.has(id)) byId.set(id, new Node("div"));
    return byId.get(id);
  },
};

const script = html.slice(html.indexOf("<script>") + "<script>".length, html.lastIndexOf("</script>"));
new Function(script)();

const classes = (n) => n.className.split(/\s+/);
const walk = function* (n) {
  for (const c of n.children) {
    yield c;
    yield* walk(c);
  }
};
const find = (n, cls) => [...walk(n)].find((c) => classes(c).includes(cls));
const findAll = (n, cls) => [...walk(n)].filter((c) => classes(c).includes(cls));

const cardsOf = (host) =>
  findAll(host, "fm-card").map((card) => {
    const outputs = findAll(find(card, "dash-card__outputs") || new Node("div"), "dash-out")
      .map((row) => row.textContent);
    return {
      title: find(card, "dash-card__title")?.textContent ?? "",
      badges: findAll(card, "fm-badge").map((b) => ({
        tone: b.className.replace(/.*fm-badge--/, "").trim(),
        text: b.textContent,
      })),
      meta: find(card, "dash-card__meta")?.textContent ?? "",
      outputs,
      live: find(card, "dash-live")?.textContent ?? null,
    };
  });

const sectionsRoot = byId.get("sections") || new Node("div");
const sections = (sectionsRoot.children[0]?.children || [])
  .filter((n) => classes(n).includes("dash-section"))
  .map((sec) => ({
    name: find(sec, "dash-section__name")?.textContent ?? "",
    count: find(sec, "dash-section__count")?.textContent ?? "",
    cards: cardsOf(find(sec, "dash-cards") || new Node("div")),
  }));

const stats = (byId.get("stats") || new Node("div")).children.flatMap((host) =>
  host.children.map((t) => ({
    n: Number(find(t, "dash-stat__num")?.textContent),
    label: find(t, "dash-stat__label")?.textContent ?? "",
  })));

const foot = (byId.get("foot") || new Node("div")).children.map((d) => d.textContent);
const empty = (sectionsRoot.children[0]?.children || [])
  .filter((n) => classes(n).includes("dash-empty"))
  .map((n) => n.textContent);
const error = (sectionsRoot.children[0]?.children || [])
  .filter((n) => classes(n).includes("dash-error"))
  .map((n) => n.textContent)
  .join(" ");

process.stdout.write(JSON.stringify({
  stats, sections, cards: sections.flatMap((s) => s.cards), empty, foot, error,
}) + "\n");
