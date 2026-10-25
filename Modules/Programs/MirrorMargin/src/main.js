import { Compartment, EditorState, RangeSetBuilder } from "@codemirror/state";
import { Decoration, EditorView } from "@codemirror/view";
import DOMPurify from "dompurify";
import { unzipSync } from "fflate";
import { marked } from "marked";

const $ = (selector) => document.querySelector(selector);
const paneIds = ["left", "right"];
const intermediateSyncInterval = 48;
const minimumReaderFontSize = 16;
const maximumReaderFontSize = 26;
let readerFontSize = 20;
const panes = Object.fromEntries(paneIds.map((id) => [id, {
  id, view: null, model: null, source: null, anchor: 0, anchorDy: 0, measureRequest: 0, syncTimer: null, intermediateTimer: null, resizeObserver: null,
  decorations: new Compartment(), selectionTimer: null,
  suppressScrollUntil: 0, suppressionReason: null, lastScroll: null, recoveryPending: false, mouseProbe: null,
}]));
let automaticPoints = [];
let manualPoints = [];
let syncInProgress = false;
let activeSync = null;
let nextSyncOperation = 0;
let pendingSync = null;
let resizeFrame;
let persistTimer;
let syncSequence = 0;
const traceStartedAt = performance.now();
const traceEntries = [];
const traceLimit = 5000;

function rounded(value) {
  return Number.isFinite(value) ? Math.round(value * 100) / 100 : null;
}

function paneSnapshot(id) {
  const pane = panes[id];
  const view = pane.view;
  const scroller = view?.scrollDOM;
  return {
    anchor: { position: pane.anchor, dy: rounded(pane.anchorDy) },
    documentLength: pane.model?.text.length ?? null,
    viewport: view ? { from: view.viewport.from, to: view.viewport.to } : null,
    scroll: scroller ? {
      top: rounded(scroller.scrollTop), height: rounded(scroller.scrollHeight), clientHeight: rounded(scroller.clientHeight),
    } : null,
  };
}

function trace(event, details = {}) {
  traceEntries.push({
    sequence: traceEntries.length + 1,
    milliseconds: rounded(performance.now() - traceStartedAt),
    event,
    syncInProgress,
    ...details,
  });
  if (traceEntries.length > traceLimit) traceEntries.splice(0, traceEntries.length - traceLimit);
}

function traceBoth(event, details = {}) {
  trace(event, { ...details, panes: Object.fromEntries(paneIds.map((id) => [id, paneSnapshot(id)])) });
}

function downloadTrace() {
  traceBoth("trace-download-requested", { location: window.location.href });
  const contents = JSON.stringify({
    format: "mirror-margin-scroll-trace-v1",
    capturedAt: new Date().toISOString(),
    location: window.location.href,
    entries: traceEntries,
  }, null, 2);
  const link = document.createElement("a");
  link.href = URL.createObjectURL(new Blob([contents], { type: "application/json" }));
  link.download = `mirror-margin-trace-${new Date().toISOString().replaceAll(/[:.]/g, "-")}.json`;
  link.click();
  setTimeout(() => URL.revokeObjectURL(link.href), 0);
}

const databaseName = "mirror-margin";
const databaseStore = "session";
const lookupStore = "lookups";
const lookupEventStore = "lookup-events";
const lookups = new Map();
const bridgeToken = new URLSearchParams(window.location.search).get("bridge");
let activeSelection = null;
let activeLookup = null;
let lookupDrag = null;

function openDatabase() {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(databaseName, 2);
    request.onupgradeneeded = () => {
      const database = request.result;
      if (!database.objectStoreNames.contains(databaseStore)) database.createObjectStore(databaseStore);
      if (!database.objectStoreNames.contains(lookupStore)) database.createObjectStore(lookupStore, { keyPath: "key" });
      if (!database.objectStoreNames.contains(lookupEventStore)) database.createObjectStore(lookupEventStore, { keyPath: "id" });
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function requestResult(request) {
  return new Promise((resolve, reject) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

async function loadLookups() {
  const database = await openDatabase();
  const records = await requestResult(database.transaction(lookupStore).objectStore(lookupStore).getAll());
  for (const record of records) lookups.set(record.key, record);
  refreshLookupDecorations();
}

async function storeLookup(record) {
  const database = await openDatabase();
  const transaction = database.transaction([lookupStore, lookupEventStore], "readwrite");
  transaction.objectStore(lookupStore).put(record);
  transaction.objectStore(lookupEventStore).put({
    id: crypto.randomUUID(), key: record.key, occurredAt: record.lastViewedAt, answer: record.answer,
  });
  await new Promise((resolve, reject) => {
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

async function loadSession() {
  const database = await openDatabase();
  return new Promise((resolve, reject) => {
    const request = database.transaction(databaseStore).objectStore(databaseStore).get("current");
    request.onsuccess = () => resolve(request.result ?? null);
    request.onerror = () => reject(request.error);
  });
}

async function saveSession() {
  const books = Object.fromEntries(paneIds
    .filter((id) => panes[id].source)
    .map((id) => [id, panes[id].source]));
  const database = await openDatabase();
  await new Promise((resolve, reject) => {
    const transaction = database.transaction(databaseStore, "readwrite");
    transaction.objectStore(databaseStore).put({
      books,
      anchors: Object.fromEntries(paneIds.map((id) => [id, { position: panes[id].anchor, dy: panes[id].anchorDy }])),
      manualPoints,
      readerFontSize,
    }, "current");
    transaction.oncomplete = resolve;
    transaction.onerror = () => reject(transaction.error);
    transaction.onabort = () => reject(transaction.error);
  });
}

function scheduleSave() {
  clearTimeout(persistTimer);
  persistTimer = setTimeout(() => saveSession().catch((error) => console.warn("Could not save local reading state", error)), 300);
}

function applyReaderFontSize(value, { persist = true } = {}) {
  readerFontSize = Math.max(minimumReaderFontSize, Math.min(maximumReaderFontSize, Math.round(value)));
  document.documentElement.style.setProperty("--reader-font-size", `${readerFontSize}px`);
  $("#font-size").textContent = `${readerFontSize} px`;
  const anchors = Object.fromEntries(paneIds.map((id) => [id, { position: panes[id].anchor, dy: panes[id].anchorDy }]));
  for (const id of paneIds) panes[id].view?.requestMeasure();
  // Font-size reflow is exactly the operation logical anchors are intended to
  // survive. Wait for the stylesheet change to take effect, then re-place each.
  requestAnimationFrame(() => requestAnimationFrame(() => {
    for (const id of paneIds) if (panes[id].view) placeAnchor(id, anchors[id], "font-size-change");
  }));
  traceBoth("reader-font-size-changed", { readerFontSize, anchors });
  if (persist) scheduleSave();
}

const theme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "transparent", color: "#2c2924" },
  ".cm-scroller": {
    fontFamily: 'Inter, "Aptos", "Segoe UI Variable", ui-sans-serif, system-ui, sans-serif', fontSize: "var(--reader-font-size)", lineHeight: "1.72",
    // CodeMirror changes the estimated height of its virtual spacers as it
    // discovers wrapped lines. Native scroll anchoring keeps the visible text
    // fixed through those corrections (notably in Firefox on Windows).
    overflowAnchor: "auto", overflowY: "scroll", overflowX: "hidden", scrollbarGutter: "stable",
    scrollbarWidth: "thin", scrollbarColor: "#9d907b transparent",
  },
  ".cm-scroller::-webkit-scrollbar": { width: "12px" },
  ".cm-scroller::-webkit-scrollbar-thumb": { backgroundColor: "#9d907b", border: "3px solid transparent", borderRadius: "999px", backgroundClip: "content-box" },
  ".cm-scroller::-webkit-scrollbar-track": { backgroundColor: "transparent" },
  ".cm-content": { padding: "2.5rem clamp(1.25rem, 4vw, 3.5rem) 10rem", caretColor: "transparent" },
  ".cm-line": { padding: "0", textIndent: "1.2em" },
  ".cm-mm-heading": { textIndent: "0", marginTop: "2.6em", marginBottom: ".75em", fontWeight: "650", fontSize: "1.5em", lineHeight: "1.22" },
  ".cm-mm-title": { textIndent: "0", marginTop: "0", marginBottom: "1.25em", fontWeight: "650", fontSize: "2em", lineHeight: "1.13" },
  ".cm-mm-epigraph": { textIndent: "0", marginLeft: "12%", fontSize: ".93em", color: "#665f55" },
  ".mm-bold": { fontWeight: "700" },
  ".mm-italic": { fontStyle: "italic" },
  ".mm-link": { color: "#775b29", textDecoration: "underline", textDecorationColor: "#b8a884" },
  ".cm-selectionBackground, ::selection": { backgroundColor: "#d9c99d !important" },
});

function normalizeText(value) {
  return value.replace(/\s+/g, " ").trim();
}

function nameOf(element) {
  return element.localName?.toLowerCase() ?? "";
}

function inlineRuns(element, inherited = {}) {
  const runs = [];
  for (const child of element.childNodes) {
    if (child.nodeType === Node.TEXT_NODE) {
      const value = child.nodeValue.replace(/\s+/g, " ");
      if (value) runs.push({ text: value, ...inherited });
      continue;
    }
    if (child.nodeType !== Node.ELEMENT_NODE) continue;
    const tag = nameOf(child);
    if (tag === "image") continue;
    const style = {
      ...inherited,
      bold: inherited.bold || tag === "strong" || tag === "b",
      italic: inherited.italic || tag === "emphasis" || tag === "em" || tag === "i" || tag === "style",
      link: inherited.link || tag === "a",
    };
    runs.push(...inlineRuns(child, style));
  }
  const merged = [];
  for (const run of runs) {
    const previous = merged.at(-1);
    if (previous && previous.bold === run.bold && previous.italic === run.italic && previous.link === run.link) previous.text += run.text;
    else merged.push({ ...run });
  }
  return merged;
}

function directChildren(element, tag) {
  return [...element.children].filter((child) => nameOf(child) === tag);
}

function directChild(element, tag) {
  return directChildren(element, tag)[0];
}

function elementsNamed(element, tag) {
  return [...element.getElementsByTagNameNS("*", tag)];
}

function textOf(element) {
  return normalizeText(element?.textContent ?? "");
}

function addBlock(blocks, runs, kind) {
  const normalizedRuns = [];
  let needsSpace = false;
  for (const run of runs) {
    for (const token of run.text.match(/\S+|\s+/g) ?? []) {
      if (/^\s+$/.test(token)) {
        needsSpace ||= normalizedRuns.length > 0;
        continue;
      }
      if (needsSpace) normalizedRuns.push({ text: " " });
      normalizedRuns.push({ ...run, text: token });
      needsSpace = false;
    }
  }
  const text = normalizedRuns.map((run) => run.text).join("");
  if (text) blocks.push({ kind, text, runs: normalizedRuns });
}

function semanticChapterKey(title) {
  const value = normalizeText(title).toLocaleLowerCase();
  if (/^\d+$/.test(value)) return `chapter:${Number(value)}`;
  if (/epilogue|epiloog/.test(value)) return "epilogue";
  if (!/part|deel/.test(value)) return null;
  const match = value.match(/(?:part|deel)\s*(1|2|3|one|two|three|een|twee|drie|i|ii|iii)/);
  const numbers = { "1": 1, one: 1, een: 1, i: 1, "2": 2, two: 2, twee: 2, ii: 2, "3": 3, three: 3, drie: 3, iii: 3 };
  return match ? `part:${numbers[match[1]]}` : null;
}

function finalizeBook(title, blocks, markers, language = null) {
  if (!blocks.length) throw new Error("The selected book has no readable prose blocks.");
  let offset = 0;
  const decorations = [];
  for (const block of blocks) {
    block.from = offset;
    block.to = offset + block.text.length;
    decorations.push({ from: block.from, to: block.from, decoration: Decoration.line({ class: `cm-mm-${block.kind}` }) });
    let runOffset = block.from;
    for (const run of block.runs) {
      const to = runOffset + run.text.length;
      const classes = [run.bold && "mm-bold", run.italic && "mm-italic", run.link && "mm-link"].filter(Boolean).join(" ");
      if (classes && to > runOffset) decorations.push({ from: runOffset, to, decoration: Decoration.mark({ class: classes }) });
      runOffset = to;
    }
    offset = block.to + 1;
  }
  const text = blocks.map((block) => block.text).join("\n");
  const uniqueMarkers = new Map();
  for (const marker of markers) {
    if (!marker.title || marker.blockIndex >= blocks.length) continue;
    const previous = uniqueMarkers.get(marker.blockIndex);
    if (!previous || (!semanticChapterKey(previous.title) && semanticChapterKey(marker.title))) uniqueMarkers.set(marker.blockIndex, marker);
  }
  const ordered = [...uniqueMarkers.values()].sort((a, b) => a.blockIndex - b.blockIndex);
  if (!ordered.length || ordered[0].blockIndex > 0) ordered.unshift({ title: title || "Beginning", blockIndex: 0 });
  const chapters = ordered.map((marker, index) => ({
    id: `chapter-${index}`,
    title: marker.title,
    syncKey: semanticChapterKey(marker.title),
    from: blocks[marker.blockIndex].from,
    to: index + 1 < ordered.length ? blocks[ordered[index + 1].blockIndex].from : text.length,
  })).filter((chapter) => chapter.to > chapter.from);
  return { title, language, text, decorations, chapters };
}

function parseFb2(source, fallbackTitle) {
  const xml = new DOMParser().parseFromString(source, "application/xml");
  if (xml.querySelector("parsererror")) throw new Error("The selected file is not valid FB2 XML.");
  const bodies = [...xml.getElementsByTagNameNS("*", "body")];
  const body = bodies.find((candidate) => !candidate.getAttribute("name"));
  if (!body) throw new Error("The FB2 file has no main text body.");

  const bookTitle = textOf(xml.querySelector("description title-info book-title")) || fallbackTitle;
  const blocks = [];
  const markers = [];

  const collectSection = (section, depth) => {
    const title = directChild(section, "title");
    const chapterTitle = textOf(title);
    if (chapterTitle) markers.push({ title: chapterTitle, blockIndex: blocks.length });
    if (title) addBlock(blocks, inlineRuns(title), depth === 0 ? "title" : "heading");
    for (const child of section.children) {
      const tag = nameOf(child);
      if (tag === "title") continue;
      if (tag === "section") collectSection(child, depth + 1);
      else if (tag === "p" || tag === "subtitle" || tag === "text-author") addBlock(blocks, inlineRuns(child), tag === "text-author" ? "epigraph" : "paragraph");
      else if (tag === "poem" || tag === "epigraph" || tag === "cite") {
        for (const paragraph of child.querySelectorAll(":scope p")) addBlock(blocks, inlineRuns(paragraph), tag === "epigraph" ? "epigraph" : "paragraph");
      }
    }
  };

  const topSections = directChildren(body, "section");
  const sections = topSections.length ? topSections : [body];
  sections.forEach((section) => collectSection(section, 0));
  return finalizeBook(bookTitle, blocks, markers, textOf(elementsNamed(xml, "lang")[0]) || null);
}

function parseXml(source, label) {
  // Older EPUB generators often emit HTML's named nbsp entity in otherwise XML XHTML.
  const xml = new DOMParser().parseFromString(source.replaceAll("&nbsp;", "&#160;"), "application/xml");
  if (xml.querySelector("parsererror")) throw new Error(`${label} is not valid XML.`);
  return xml;
}

function zipPath(base, href) {
  return decodeURIComponent(new URL(href, `https://book.invalid/${base ? `${base}/` : ""}`).pathname.slice(1));
}

const xmlEncodingAliases = new Map([
  ["utf8", "utf-8"],
  ["us-ascii", "windows-1252"],
  ["iso-8859-1", "windows-1252"],
  ["latin1", "windows-1252"],
  ["cp1251", "windows-1251"],
  ["cp1252", "windows-1252"],
]);

function decodeXmlBytes(bytes) {
  // XML declarations are ASCII-compatible, so Windows-1252 safely reads this
  // small prefix without assuming that the document body is UTF-8.
  const header = new TextDecoder("windows-1252").decode(bytes.subarray(0, 512));
  const declared = header.match(/<\?xml\b[^>]*\bencoding\s*=\s*["']([^"']+)["']/i)?.[1]?.trim().toLowerCase();
  const encoding = xmlEncodingAliases.get(declared) ?? declared;
  const candidates = [...new Set([encoding, "utf-8", "windows-1252"].filter(Boolean))];
  for (const candidate of candidates) {
    try {
      return new TextDecoder(candidate, { fatal: true }).decode(bytes);
    } catch {
      // Try the next standards-compatible fallback below.
    }
  }
  return new TextDecoder("windows-1252").decode(bytes);
}

function zipText(files, path) {
  const value = files[path];
  if (!value) throw new Error(`The book archive is missing ${path}.`);
  return decodeXmlBytes(value);
}

function parseEpub(files, fallbackTitle) {
  if (files["META-INF/encryption.xml"]) throw new Error("Encrypted/DRM EPUB files are not supported.");
  const container = parseXml(zipText(files, "META-INF/container.xml"), "The EPUB container");
  const rootfile = elementsNamed(container, "rootfile").find((node) => node.getAttribute("full-path"));
  if (!rootfile) throw new Error("The EPUB container has no package document.");
  const opfPath = rootfile.getAttribute("full-path");
  const opfBase = opfPath.slice(0, opfPath.lastIndexOf("/"));
  const opf = parseXml(zipText(files, opfPath), "The EPUB package document");
  const metadataTitle = textOf(elementsNamed(opf, "title")[0]);
  const manifest = new Map(elementsNamed(opf, "item").filter((item) => nameOf(item.parentElement) === "manifest").map((item) => [item.getAttribute("id"), {
    path: zipPath(opfBase, item.getAttribute("href")), mediaType: item.getAttribute("media-type") ?? "",
  }]));
  const spine = elementsNamed(opf, "itemref").filter((item) => nameOf(item.parentElement) === "spine").map((item) => manifest.get(item.getAttribute("idref"))).filter(Boolean);
  if (!spine.length) throw new Error("The EPUB has no readable spine.");
  const ncx = [...manifest.values()].find((item) => item.mediaType === "application/x-dtbncx+xml" || item.path.endsWith(".ncx"));
  const targets = new Map();
  if (ncx) {
    const ncxBase = ncx.path.slice(0, ncx.path.lastIndexOf("/"));
    const navigation = parseXml(zipText(files, ncx.path), "The EPUB table of contents");
    for (const point of elementsNamed(navigation, "navPoint")) {
      const label = textOf(elementsNamed(point, "text")[0]);
      const source = elementsNamed(point, "content")[0]?.getAttribute("src");
      if (!label || !source) continue;
      const [href, fragment = ""] = source.split("#", 2);
      targets.set(`${zipPath(ncxBase, href)}#${fragment}`, label);
    }
  }
  const blocks = [];
  const markers = [];
  const seenTargets = new Set();
  const mark = (key, title) => {
    if (title && !seenTargets.has(key)) {
      seenTargets.add(key);
      markers.push({ title, blockIndex: blocks.length });
    }
  };
  for (const item of spine) {
    if (!/(xhtml|html)/.test(item.mediaType) && !/\.x?html?$/i.test(item.path)) continue;
    const document = parseXml(zipText(files, item.path), `The EPUB document ${item.path}`);
    mark(`${item.path}#`, targets.get(`${item.path}#`));
    const content = elementsNamed(document, "body")[0] ?? document.documentElement;
    for (const element of elementsNamed(content, "*").filter((node) => /^(h[1-6]|p|blockquote|li)$/.test(nameOf(node)))) {
      if (element.id) mark(`${item.path}#${element.id}`, targets.get(`${item.path}#${element.id}`));
      const tag = nameOf(element);
      const heading = /^h[1-6]$/.test(tag);
      const value = textOf(element);
      if (heading && value && !element.id) markers.push({ title: value, blockIndex: blocks.length });
      addBlock(blocks, inlineRuns(element), heading ? "heading" : tag === "blockquote" ? "epigraph" : "paragraph");
    }
  }
  return finalizeBook(metadataTitle || fallbackTitle, blocks, markers, textOf(elementsNamed(opf, "language")[0]) || null);
}

function parseBookBytes(bytes, fallbackTitle) {
  const isZip = bytes[0] === 0x50 && bytes[1] === 0x4b;
  if (!isZip) return parseFb2(decodeXmlBytes(bytes), fallbackTitle);
  const files = unzipSync(bytes);
  if (files["META-INF/container.xml"] || new TextDecoder().decode(files.mimetype ?? new Uint8Array()).trim() === "application/epub+zip") return parseEpub(files, fallbackTitle);
  const fb2Path = Object.keys(files).find((path) => path.toLocaleLowerCase().endsWith(".fb2"));
  if (fb2Path) return parseFb2(decodeXmlBytes(files[fb2Path]), fallbackTitle);
  throw new Error("This ZIP contains neither an EPUB nor an FB2 file.");
}

function decorationSet(model) {
  const builder = new RangeSetBuilder();
  for (const item of [...model.decorations].sort((a, b) => a.from - b.from || a.to - b.to)) builder.add(item.from, item.to, item.decoration);
  return builder.finish();
}

function lookupKey(text) {
  return normalizeText(text).toLocaleLowerCase();
}

function isWord(text) {
  return /^\p{L}[\p{L}\p{M}'’-]*$/u.test(text);
}

function escapedPattern(text) {
  return text.replace(/[.*+?^${}()|[\]\\]/g, "\\$&").replace(/\s+/g, "\\s+");
}

function lookupDecorations(model) {
  const decorations = [];
  for (const record of lookups.values()) {
    if (!record.normalized) continue;
    const count = Math.min(record.count, 5);
    const className = `${isWord(record.normalized) ? "mm-looked-up-word" : "mm-looked-up-phrase"} mm-lookup-count-${count}`;
    const decoration = Decoration.mark({
      class: className,
      attributes: { title: `Looked up ${record.count} ${record.count === 1 ? "time" : "times"}`, style: `--mm-lookup-count:${count}` },
    });
    const pattern = isWord(record.normalized)
      ? new RegExp(`\\p{L}[\\p{L}\\p{M}'’-]*`, "gu")
      : new RegExp(escapedPattern(record.normalized), "giu");
    for (const match of model.text.matchAll(pattern)) {
      if (lookupKey(match[0]) === record.key) decorations.push({ from: match.index, to: match.index + match[0].length, decoration });
    }
  }
  return decorations;
}

function combinedDecorationSet(model) {
  const builder = new RangeSetBuilder();
  const decorations = [...model.decorations, ...lookupDecorations(model)]
    .sort((a, b) => a.from - b.from || a.to - b.to);
  for (const item of decorations) builder.add(item.from, item.to, item.decoration);
  return builder.finish();
}

function refreshLookupDecorations() {
  for (const id of paneIds) {
    const pane = panes[id];
    if (pane.view && pane.model) pane.view.dispatch({ effects: pane.decorations.reconfigure(EditorView.decorations.of(combinedDecorationSet(pane.model))) });
  }
}

function selectedRange(id) {
  const view = panes[id].view;
  if (!view) return null;
  const selection = view.state.selection.main;
  if (selection.empty) return null;
  return { from: selection.from, to: selection.to, text: view.state.doc.sliceString(selection.from, selection.to) };
}

function wordRangeAt(view, position) {
  return view.state.wordAt(Math.max(0, Math.min(view.state.doc.length, position)));
}

function sentenceRangeAt(view, position) {
  const text = view.state.doc.toString();
  let from = Math.max(0, Math.min(text.length, position));
  let to = from;
  while (from > 0 && !/[.!?…]/.test(text[from - 1])) from -= 1;
  while (from < text.length && /\s/.test(text[from])) from += 1;
  while (to < text.length && !/[.!?…]/.test(text[to])) to += 1;
  if (to < text.length) to += 1;
  while (to < text.length && /[”’"')\]]/.test(text[to])) to += 1;
  return { from, to };
}

function hideSelectionAction() {
  activeSelection = null;
  $("#selection-action").hidden = true;
}

function showSelectionAction(id) {
  const range = selectedRange(id);
  if (!range || !range.text.trim()) return hideSelectionAction();
  const view = panes[id].view;
  const rect = view.coordsAtPos(range.to);
  if (!rect) return hideSelectionAction();
  activeSelection = { pane: id, ...range };
  const action = $("#selection-action");
  action.hidden = false;
  const width = action.offsetWidth || 70;
  action.style.left = `${Math.max(8, Math.min(window.innerWidth - width - 8, rect.right + 8))}px`;
  action.style.top = `${Math.max(8, rect.top - action.offsetHeight - 8)}px`;
}

function scheduleSelectionAction(id) {
  const pane = panes[id];
  clearTimeout(pane.selectionTimer);
  pane.selectionTimer = setTimeout(() => showSelectionAction(id), 180);
}

async function codexExplain(text, language) {
  if (!bridgeToken) throw new Error("Codex explanations need Mirror Margin to be started with nix run.");
  const response = await fetch("/api/explain", {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-Mirror-Margin-Token": bridgeToken },
    body: JSON.stringify({ text, language: language ?? "" }),
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || !payload.answer) throw new Error(payload.error ?? "Codex did not return an explanation.");
  return payload.answer;
}

function renderExplanation(value) {
  // The model response is never trusted as HTML. Marked provides the reading
  // format and DOMPurify enforces a deliberately small, link-safe subset.
  return DOMPurify.sanitize(marked.parse(value, { async: false, breaks: true, gfm: true }), {
    ALLOWED_TAGS: ["p", "br", "strong", "em", "del", "code", "pre", "ul", "ol", "li", "blockquote", "a", "h1", "h2", "h3", "hr"],
    ALLOWED_ATTR: ["href", "title"],
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto):|[^a-z]|[a-z+.-]+(?:[^a-z+.-:]|$))/i,
  });
}

function showLookupCard(id, record) {
  const card = $("#lookup-card");
  activeLookup = record;
  $("#lookup-kind").textContent = record.answerKind === "codex" ? "Codex · luna · low effort" : record.answerKind === "error" ? "Codex request failed" : "Asking Codex…";
  $("#lookup-text").textContent = record.text;
  $("#lookup-answer").innerHTML = renderExplanation(record.answer);
  $("#lookup-count").textContent = `Looked up ${record.count} ${record.count === 1 ? "time" : "times"} · stored on this device`;
  card.hidden = false;
}

function closeLookupCard() {
  $("#lookup-card").hidden = true;
  activeLookup = null;
}

function escapeHtml(value) {
  return value.replace(/[&<>"']/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[character]);
}

function openLookupInNewTab() {
  if (!activeLookup) return;
  const title = escapeHtml(activeLookup.text);
  const answer = renderExplanation(activeLookup.answer);
  const contents = `<!doctype html><meta charset="utf-8"><title>${title} — Mirror Margin</title><style>body{max-width:52rem;margin:4rem auto;padding:0 1.5rem;background:#f1ede4;color:#29261f;font:18px/1.6 Inter,Aptos,"Segoe UI Variable",ui-sans-serif,system-ui,sans-serif}small{font:14px Inter,Aptos,"Segoe UI Variable",ui-sans-serif,system-ui,sans-serif;color:#71695d}h1{line-height:1.25}.answer>*:first-child{margin-top:1.5rem}.answer p{margin:.8rem 0}.answer code{padding:.08em .28em;border-radius:.22em;background:#e4ded2}.answer pre{overflow:auto;padding:1rem;border-radius:.4rem;background:#e4ded2}.answer a{color:#71592f}</style><small>Mirror Margin · Codex · luna · low effort · looked up ${activeLookup.count} ${activeLookup.count === 1 ? "time" : "times"}</small><h1>${title}</h1><main class="answer">${answer}</main>`;
  const url = URL.createObjectURL(new Blob([contents], { type: "text/html" }));
  window.open(url, "_blank", "noopener");
  setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

async function requestExplanation(id, range, trigger) {
  const text = normalizeText(range.text);
  if (!text) return;
  hideSelectionAction();
  const key = lookupKey(text);
  const now = new Date().toISOString();
  const existing = lookups.get(key);
  const record = {
    key,
    normalized: key,
    text: existing?.text ?? text,
    answer: existing?.answer ?? "Asking Codex…",
    answerKind: existing?.answerKind ?? "pending",
    count: (existing?.count ?? 0) + 1,
    firstViewedAt: existing?.firstViewedAt ?? now,
    lastViewedAt: now,
  };
  trace("lookup-requested", { pane: id, trigger, key, count: record.count, length: text.length });
  if (existing?.answerKind === "codex") {
    lookups.set(key, record);
    refreshLookupDecorations();
    showLookupCard(id, record);
    try {
      await storeLookup(record);
    } catch (error) {
      trace("lookup-store-failed", { message: error.message, key });
    }
    return;
  }
  showLookupCard(id, record);
  try {
    record.answer = await codexExplain(text, panes[id].model.language);
    record.answerKind = "codex";
    lookups.set(key, record);
    refreshLookupDecorations();
    showLookupCard(id, record);
    await storeLookup(record);
  } catch (error) {
    trace("lookup-store-failed", { message: error.message, key });
    record.answer = error.message;
    record.answerKind = "error";
    showLookupCard(id, record);
    console.warn("Could not request or save explanation", error);
  }
}

function makeView(id, model, source) {
  const pane = panes[id];
  trace("view-replaced", { pane: id, previous: paneSnapshot(id), nextDocumentLength: model.text.length });
  pane.view?.destroy();
  pane.resizeObserver?.disconnect();
  const host = $(`#${id}-reader`);
  host.replaceChildren();
  pane.model = model;
  pane.source = source;
  pane.anchor = 0;
  pane.anchorDy = 0;
  const state = EditorState.create({
    doc: model.text,
    extensions: [
      EditorState.readOnly.of(true),
      EditorView.editable.of(false),
      EditorView.lineWrapping,
      pane.decorations.of(EditorView.decorations.of(combinedDecorationSet(model))),
      EditorView.updateListener.of((update) => {
        if (update.selectionSet) scheduleSelectionAction(id);
      }),
      EditorView.contentAttributes.of({ "aria-label": `${id === "left" ? "Sample" : "Reference"} text` }),
      theme,
    ],
  });
  pane.view = new EditorView({ state, parent: host });
  pane.view.scrollDOM.addEventListener("mousedown", (event) => {
    if (event.button !== 0) return;
    traceMouseProbe(id, event);
    if (!event.ctrlKey && event.detail === 3) {
      const position = pane.view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (position === null) return;
      const range = sentenceRangeAt(pane.view, position);
      event.preventDefault();
      event.stopPropagation();
      pane.view.dispatch({ selection: { anchor: range.from, head: range.to } });
      return;
    }
    if (!event.ctrlKey) return;
    const existing = selectedRange(id);
    const position = pane.view.posAtCoords({ x: event.clientX, y: event.clientY });
    const word = position === null ? null : wordRangeAt(pane.view, position);
    const range = existing ?? (word && { from: word.from, to: word.to, text: pane.view.state.doc.sliceString(word.from, word.to) });
    if (!range) return;
    event.preventDefault();
    event.stopPropagation();
    if (!existing) pane.view.dispatch({ selection: { anchor: range.from, head: range.to } });
    requestExplanation(id, range, existing ? "ctrl-selection" : "ctrl-word");
  }, { capture: true });
  pane.view.scrollDOM.addEventListener("pointerdown", (event) => {
    if (event.pointerType !== "touch") return;
    const previous = pane.lastTap;
    const closeEnough = previous && event.timeStamp - previous.time < 450
      && Math.hypot(event.clientX - previous.x, event.clientY - previous.y) < 28;
    const count = closeEnough ? previous.count + 1 : 1;
    pane.lastTap = { time: event.timeStamp, x: event.clientX, y: event.clientY, count };
    if (count !== 3) return;
    pane.lastTap = null;
    const position = pane.view.posAtCoords({ x: event.clientX, y: event.clientY });
    if (position === null) return;
    const range = sentenceRangeAt(pane.view, position);
    event.preventDefault();
    pane.view.dispatch({ selection: { anchor: range.from, head: range.to } });
  }, { passive: false, capture: true });
  pane.view.scrollDOM.addEventListener("scroll", () => {
    hideSelectionAction();
    trace("scroll-event", { pane: id, state: paneSnapshot(id) });
    observeScrollAnchor(id);
    if (performance.now() < pane.suppressScrollUntil) {
      trace("scroll-event-suppressed", {
        pane: id, reason: pane.suppressionReason, remainingMilliseconds: rounded(pane.suppressScrollUntil - performance.now()),
      });
      return;
    }
    scheduleSync(id, "scroll-settle", 100);
    if (pane.intermediateTimer === null) {
      pane.intermediateTimer = setTimeout(() => {
        pane.intermediateTimer = null;
        scheduleSync(id, "scroll-intermediate", 0);
      }, intermediateSyncInterval);
    }
  }, { passive: true });
  pane.view.scrollDOM.addEventListener("scrollend", () => {
    trace("scroll-end", { pane: id, state: paneSnapshot(id) });
    if (performance.now() < pane.suppressScrollUntil) return;
    clearTimeout(pane.intermediateTimer);
    pane.intermediateTimer = null;
    scheduleSync(id, "scrollend", 0);
  }, { passive: true });
  pane.resizeObserver = new ResizeObserver((entries) => {
    trace("resize-observer", {
      pane: id,
      contentRect: entries[0] ? { width: rounded(entries[0].contentRect.width), height: rounded(entries[0].contentRect.height) } : null,
    });
    scheduleResizeRestore();
  });
  pane.resizeObserver.observe(host);
  $(`#${id}-title`).textContent = model.title;
  updatePanePosition(id);
  traceBoth("view-created", { pane: id, title: model.title, documentLength: model.text.length });
}

function chapterAt(model, position) {
  return model.chapters.find((chapter) => position >= chapter.from && position <= chapter.to) ?? model.chapters.at(-1);
}

function updatePanePosition(id, position = panes[id].anchor) {
  const pane = panes[id];
  if (!pane.model || !pane.view) return;
  const chapter = chapterAt(pane.model, position);
  const fraction = chapter ? Math.max(0, Math.min(1, (position - chapter.from) / Math.max(1, chapter.to - chapter.from))) : 0;
  const positionLabel = $(`#${id}-position`);
  if (positionLabel) positionLabel.textContent = chapter ? `${chapter.title} · ${Math.round(fraction * 100)}%` : "—";
}

function sampleViewportAnchor(view) {
  const viewport = view.scrollDOM.getBoundingClientRect();
  const x = viewport.left + Math.max(1, Math.min(viewport.width - 1, viewport.width / 2));
  const maximumProbe = Math.min(80, Math.max(1, viewport.height - 1));
  for (let offset = 1; offset <= maximumProbe; offset += 4) {
    const position = view.posAtCoords({ x, y: viewport.top + offset });
    if (position === null) continue;
    const character = view.coordsAtPos(position);
    if (character) return { position, dy: character.top - viewport.top, probeOffset: offset };
  }
  return null;
}

function traceMouseProbe(id, event) {
  const pane = panes[id];
  const view = pane.view;
  if (!view) return;
  const scroller = view.scrollDOM.getBoundingClientRect();
  const content = view.contentDOM.getBoundingClientRect();
  let position = null;
  let error = null;
  try {
    position = view.posAtCoords({ x: event.clientX, y: event.clientY });
  } catch (caught) {
    error = caught.message;
  }
  const probe = { clientX: event.clientX, clientY: event.clientY, position };
  pane.mouseProbe = probe;
  trace("mouse-pointer-probe", {
    pane: id, button: event.button, detail: event.detail, client: probe,
    page: { x: event.pageX, y: event.pageY }, screen: { x: event.screenX, y: event.screenY },
    devicePixelRatio: window.devicePixelRatio,
    visualViewport: window.visualViewport ? { scale: window.visualViewport.scale, offsetLeft: window.visualViewport.offsetLeft, offsetTop: window.visualViewport.offsetTop } : null,
    scroller: { left: rounded(scroller.left), top: rounded(scroller.top), width: rounded(scroller.width), height: rounded(scroller.height) },
    content: { left: rounded(content.left), top: rounded(content.top), width: rounded(content.width), height: rounded(content.height) }, error,
  });
  requestAnimationFrame(() => {
    if (pane.mouseProbe !== probe || pane.view !== view) return;
    const selection = view.state.selection.main;
    const coordinates = view.coordsAtPos(selection.head);
    trace("mouse-selection-resolved", {
      pane: id, probe, selection: { anchor: selection.anchor, head: selection.head },
      selectionCoordinates: coordinates ? { left: rounded(coordinates.left), top: rounded(coordinates.top), bottom: rounded(coordinates.bottom) } : null,
    });
    pane.mouseProbe = null;
  });
}

function observeScrollAnchor(id) {
  const pane = panes[id];
  const view = pane.view;
  if (!view || !pane.model) return;
  const now = performance.now();
  const currentScroll = { top: view.scrollDOM.scrollTop, height: view.scrollDOM.scrollHeight };
  const previousScroll = pane.lastScroll;
  const retainedAnchor = { position: pane.anchor, dy: pane.anchorDy };
  const sample = sampleViewportAnchor(view);
  pane.lastScroll = currentScroll;
  if (!sample) return;

  // CodeMirror refines virtual spacer heights as it encounters wrapped text.
  // When Firefox turns such a refinement into a large scroll jump, retain the
  // pre-correction logical anchor instead of accepting the wrong viewport.
  const heightChanged = previousScroll && Math.abs(currentScroll.height - previousScroll.height) > Math.max(10_000, previousScroll.height * 0.08);
  const documentJumped = Math.abs(sample.position - retainedAnchor.position) > Math.max(3_000, pane.model.text.length * 0.02);
  if (heightChanged && documentJumped && now >= pane.suppressScrollUntil && !pane.recoveryPending) {
    pane.recoveryPending = true;
    trace("viewport-discontinuity", {
      pane: id, retainedAnchor, observedAnchor: { position: sample.position, dy: sample.dy },
      previousScroll, currentScroll,
    });
    requestAnimationFrame(() => {
      pane.recoveryPending = false;
      if (pane.view !== view) return;
      trace("viewport-recovery-started", { pane: id, anchor: retainedAnchor });
      placeAnchor(id, retainedAnchor, "viewport-recovery", () => {
        trace("viewport-recovery-finished", { pane: id, anchor: retainedAnchor, state: paneSnapshot(id) });
      });
    });
    return;
  }
  pane.anchor = sample.position;
  pane.anchorDy = sample.dy;
  updatePanePosition(id);
}

function measureAnchor(id, reason, callback) {
  const pane = panes[id];
  const view = pane.view;
  if (!view) return callback(null);
  const request = ++pane.measureRequest;
  let completed = false;
  const finish = (sample) => {
    if (completed) return;
    completed = true;
    clearTimeout(timeout);
    callback(sample);
  };
  const timeout = setTimeout(() => {
    trace("anchor-measure-timeout", { pane: id, reason, request });
    finish(null);
  }, 900);
  // requestMeasure can be deferred indefinitely while CodeMirror is extending
  // a virtual viewport during a long fling. This is a read-only public-view
  // query, so prefer it as the source anchor and retain requestMeasure only as
  // a fallback for the rare frame where browser layout is not ready yet.
  const immediate = sampleViewportAnchor(view);
  if (immediate) {
    const previous = { position: pane.anchor, dy: pane.anchorDy };
    pane.anchor = immediate.position;
    pane.anchorDy = immediate.dy;
    updatePanePosition(id);
    trace("anchor-measured-immediate", { pane: id, reason, previous, anchor: { position: pane.anchor, dy: pane.anchorDy }, probeOffset: immediate.probeOffset });
    return finish({ position: pane.anchor, dy: pane.anchorDy });
  }
  view.requestMeasure({
    read(measuredView) {
      return sampleViewportAnchor(measuredView);
    },
    write(sample) {
      if (pane.view !== view || pane.measureRequest !== request) {
        trace("anchor-measure-stale", { pane: id, reason, request });
        finish(null);
        return;
      }
      if (!sample) {
        trace("anchor-measure-failed", { pane: id, reason });
        requestAnimationFrame(() => finish(null));
        return;
      }
      const previous = { position: pane.anchor, dy: pane.anchorDy };
      pane.anchor = sample.position;
      pane.anchorDy = sample.dy;
      updatePanePosition(id);
      requestAnimationFrame(() => {
        trace("anchor-measured", { pane: id, reason, previous, anchor: { position: pane.anchor, dy: pane.anchorDy }, probeOffset: sample.probeOffset });
        finish({ position: pane.anchor, dy: pane.anchorDy });
      });
    },
  });
}

function currentPoints() {
  return [...automaticPoints, ...manualPoints]
    .sort((a, b) => a.left - b.left || a.right - b.right)
    .filter((point, index, all) => index === 0 || point.left !== all[index - 1].left || point.right !== all[index - 1].right);
}

function rebuildAutomaticPoints() {
  if (!panes.left.model || !panes.right.model) return;
  const left = panes.left.model, right = panes.right.model;
  automaticPoints = [{ left: 0, right: 0 }];
  const rightByKey = new Map(right.chapters.filter((chapter) => chapter.syncKey).map((chapter) => [chapter.syncKey, chapter]));
  let matches = 0;
  for (const chapter of left.chapters) {
    const counterpart = chapter.syncKey && rightByKey.get(chapter.syncKey);
    if (!counterpart) continue;
    matches += 1;
    automaticPoints.push({ left: chapter.from, right: counterpart.from });
    automaticPoints.push({ left: chapter.to, right: counterpart.to });
  }
  if (!matches) {
    for (let index = 0; index < Math.min(left.chapters.length, right.chapters.length); index += 1) {
      automaticPoints.push({ left: left.chapters[index].from, right: right.chapters[index].from });
      automaticPoints.push({ left: left.chapters[index].to, right: right.chapters[index].to });
    }
  }
  automaticPoints.push({ left: left.text.length, right: right.text.length });
  manualPoints = [];
  updateAlignmentStatus();
  trace("automatic-points-rebuilt", { automaticPointCount: automaticPoints.length, semanticChapterMatches: matches });
}

function mapPosition(from, position) {
  const source = from === "left" ? "left" : "right";
  const target = source === "left" ? "right" : "left";
  const points = currentPoints().map((point) => ({ source: point[source], target: point[target] })).sort((a, b) => a.source - b.source);
  if (!points.length) return position;
  const after = points.find((point) => point.source >= position) ?? points.at(-1);
  const before = [...points].reverse().find((point) => point.source <= position) ?? points[0];
  if (before === after || after.source === before.source) return before.target;
  const fraction = (position - before.source) / (after.source - before.source);
  return Math.round(before.target + fraction * (after.target - before.target));
}

function placeAnchor(id, requestedAnchor, reason, done = () => {}) {
  const pane = panes[id];
  if (!pane.model || !pane.view) {
    trace("anchor-place-no-view", { pane: id, reason });
    done();
    return;
  }
  const position = Math.max(0, Math.min(pane.model.text.length, requestedAnchor.position));
  const dy = Number.isFinite(requestedAnchor.dy) ? requestedAnchor.dy : 0;
  const view = pane.view;
  pane.anchor = position;
  pane.anchorDy = dy;
  pane.lastScroll = null;
  pane.suppressScrollUntil = Math.max(pane.suppressScrollUntil, performance.now() + 400);
  pane.suppressionReason = reason;
  updatePanePosition(id, position);
  let completed = false;
  const finish = () => {
    if (completed) return;
    completed = true;
    clearTimeout(timeout);
    requestAnimationFrame(done);
  };
  const timeout = setTimeout(() => {
    trace("anchor-place-timeout", { pane: id, position, dy, reason });
    finish();
  }, 1200);
  const reveal = (attempt, details = {}) => {
    trace("anchor-place-reveal", { pane: id, position, dy, reason, attempt, ...details });
    // Dispatch outside CodeMirror's measure write phase, then give its
    // virtualized viewport a frame to materialize before measuring again.
    requestAnimationFrame(() => {
      if (pane.view !== view) return finish();
      view.dispatch({ effects: EditorView.scrollIntoView(position, { y: "start", yMargin: 0 }) });
      setTimeout(() => place(attempt + 1), 48);
    });
  };
  const place = (attempt) => {
    trace("anchor-place-intent", { pane: id, requestedAnchor, position, dy, reason, attempt, before: paneSnapshot(id) });
    requestAnimationFrame(() => view.requestMeasure({
      read(measuredView) {
        const character = measuredView.coordsAtPos(position);
        const viewport = measuredView.scrollDOM.getBoundingClientRect();
        return character ? { characterTop: character.top, viewportTop: viewport.top } : null;
      },
      write(measurement) {
        if (pane.view !== view) {
          trace("anchor-place-stale", { pane: id, position, dy, reason, attempt });
          finish();
          return;
        }
        if (!measurement) {
          trace("anchor-place-not-rendered", { pane: id, position, dy, reason, attempt });
          // The common, in-viewport path must never use scrollIntoView: it
          // snaps the target line to the top before our sub-line correction,
          // producing a visible up/down pulse during continuous scrolling.
          // Reveal only a genuinely unrendered target, then measure again.
          if (attempt < 2) reveal(attempt, { cause: "not-rendered" });
          else finish();
          return;
        }
        const correction = measurement.characterTop - measurement.viewportTop - dy;
        // coordsAtPos may return an estimated coordinate for a position beyond
        // the materialized viewport. Only direct-adjust a nearby line; reveal
        // first when the correction shows that this is a virtual projection.
        if (Math.abs(correction) > 80 && attempt < 2) {
          trace("anchor-place-nonlocal", { pane: id, position, dy, reason, attempt, correction });
          reveal(attempt, { cause: "nonlocal", correction });
          return;
        }
        if (Math.abs(correction) > 0.25) view.scrollDOM.scrollTop += correction;
        trace("anchor-place-corrected", { pane: id, position, dy, reason, attempt, correction });
        requestAnimationFrame(() => view.requestMeasure({
          read(finalView) {
            const character = finalView.coordsAtPos(position);
            const viewport = finalView.scrollDOM.getBoundingClientRect();
            return character ? { actualDy: character.top - viewport.top } : null;
          },
          write(finalMeasurement) {
            if (pane.view !== view) {
              trace("anchor-place-stale", { pane: id, position, dy, reason, attempt, phase: "settle" });
              finish();
              return;
            }
            trace("anchor-place-settled", { pane: id, position, dy, reason, actualDy: finalMeasurement?.actualDy ?? null });
            finish();
          },
        }));
      },
    }));
  };
  place(0);
}

function resetViewports() {
  if (!panes.left.view || !panes.right.view || syncInProgress) return;
  const anchors = Object.fromEntries(paneIds.map((id) => [id, { position: panes[id].anchor, dy: panes[id].anchorDy }]));
  traceBoth("viewport-reset-requested", { anchors });
  const operation = beginSync("viewport-reset", "viewport-reset");
  let remaining = paneIds.length;
  for (const id of paneIds) {
    placeAnchor(id, anchors[id], "manual-viewport-reset", () => {
      if (--remaining || activeSync !== operation) return;
      traceBoth("viewport-reset-finished", { anchors });
      releaseSync(operation, { reason: "viewport-reset" });
    });
  }
}

function beginSync(sequence, purpose) {
  const operation = { id: ++nextSyncOperation, sequence, purpose, released: false, watchdog: null };
  activeSync = operation;
  syncInProgress = true;
  operation.watchdog = setTimeout(() => {
    traceBoth("sync-watchdog-fired", { sequence, purpose, operation: operation.id });
    releaseSync(operation, { reason: "watchdog" });
  }, 1500);
  trace("sync-acquired", { sequence, purpose, operation: operation.id });
  return operation;
}

function releaseSync(operation, details) {
  if (activeSync !== operation || operation.released) {
    trace("sync-release-stale", { sequence: operation?.sequence, operation: operation?.id, ...details });
    return;
  }
  operation.released = true;
  clearTimeout(operation.watchdog);
  traceBoth("sync-settled", { sequence: operation.sequence, operation: operation.id, ...details });
  syncInProgress = false;
  activeSync = null;
  trace("sync-released", { sequence: operation.sequence, operation: operation.id, ...details });
  const followUp = pendingSync;
  pendingSync = null;
  if (followUp) {
    trace("sync-follow-up", followUp);
    requestAnimationFrame(() => scheduleSync(followUp.source, `after-${followUp.trigger}`, followUp.delay));
  }
}

function scheduleSync(source, trigger, delay) {
  if (!panes.left.model || !panes.right.model) {
    trace("sync-ignored", { source, trigger, reason: "book-not-ready" });
    return;
  }
  if (syncInProgress) {
    pendingSync = { source, trigger, delay, requestedAt: rounded(performance.now() - traceStartedAt) };
    trace("sync-queued", { ...pendingSync, activeOperation: activeSync?.id ?? null });
    return;
  }
  const pane = panes[source];
  clearTimeout(pane.syncTimer);
  const sequence = ++syncSequence;
  traceBoth("sync-debounced", { sequence, source, trigger, delay });
  pane.syncTimer = setTimeout(() => {
    pane.syncTimer = null;
    if (syncInProgress) {
      pendingSync = { source, trigger, delay, requestedAt: rounded(performance.now() - traceStartedAt) };
      traceBoth("sync-cancelled", { sequence, source, reason: "sync-became-in-progress" });
      return;
    }
    const operation = beginSync(sequence, `scroll:${trigger}`);
    measureAnchor(source, `sync-source:${sequence}`, (sourceAnchor) => {
      if (activeSync !== operation) return;
      if (!sourceAnchor) return releaseSync(operation, { source, reason: "source-measure-failed" });
      const target = source === "left" ? "right" : "left";
      const targetAnchor = { position: mapPosition(source, sourceAnchor.position), dy: sourceAnchor.dy };
      traceBoth("sync-started", { sequence, source, target, sourceAnchor, targetAnchor });
      placeAnchor(target, targetAnchor, `sync:${sequence}:${source}->${target}`, () => {
        if (activeSync !== operation) return;
        scheduleSave();
        releaseSync(operation, { source, target, sourceAnchor, targetAnchor });
      });
    });
  }, delay);
}

function scheduleResizeRestore() {
  cancelAnimationFrame(resizeFrame);
  traceBoth("resize-restore-scheduled");
  resizeFrame = requestAnimationFrame(() => {
    if (syncInProgress) {
      traceBoth("resize-restore-cancelled", { reason: "sync-in-progress" });
      return;
    }
    const operation = beginSync("resize", "resize-restore");
    traceBoth("resize-restore-started");
    const ready = paneIds.filter((id) => panes[id].view && panes[id].model);
    let remaining = ready.length;
    if (!remaining) return releaseSync(operation, { reason: "no-ready-panes" });
    for (const id of ready) {
      const pane = panes[id];
      placeAnchor(id, { position: pane.anchor, dy: pane.anchorDy }, `resize-restore:${id}`, () => {
        remaining -= 1;
        if (!remaining) releaseSync(operation, { reason: "resize-restore" });
      });
    }
  });
}

function updateAlignmentStatus() {
  const ready = panes.left.model && panes.right.model;
  $("#add-alignment").disabled = !ready;
  $("#reset-alignment").disabled = !ready || manualPoints.length === 0;
  const status = $("#alignment-status");
  if (ready && status) status.textContent = `${automaticPoints.length} automatic points · ${manualPoints.length} manual points`;
}

function openBookSource(id, source, name) {
  const record = typeof source === "string"
    ? { name, bytes: new TextEncoder().encode(source) }
    : { name: source.name, bytes: source.bytes instanceof Uint8Array ? source.bytes : new Uint8Array(source.bytes) };
  trace("book-open-started", { pane: id, name: record.name, sourceLength: record.bytes.byteLength });
  const title = record.name.replace(/\.(fb2|epub)(\.zip)?$/i, "");
  const model = parseBookBytes(record.bytes, title);
  makeView(id, model, record);
  traceBoth("book-opened", { pane: id, name, documentLength: model.text.length, chapterCount: model.chapters.length });
}

async function openBook(id, file) {
  try {
    openBookSource(id, { name: file.name, bytes: new Uint8Array(await file.arrayBuffer()) }, file.name);
    if (panes.left.model && panes.right.model) rebuildAutomaticPoints();
    scheduleSave();
  } catch (error) {
    window.alert(error.message);
  }
}

async function restoreSession() {
  try {
    trace("session-restore-started");
    const session = await loadSession();
    if (!session?.books) {
      trace("session-restore-empty");
      return;
    }
    if (Number.isFinite(session.readerFontSize)) applyReaderFontSize(session.readerFontSize, { persist: false });
    for (const id of paneIds) {
      const book = session.books[id];
      if (book?.bytes && book?.name) openBookSource(id, book, book.name);
      else if (book?.source && book?.name) openBookSource(id, book.source, book.name);
    }
    if (panes.left.model && panes.right.model) rebuildAutomaticPoints();
    manualPoints = Array.isArray(session.manualPoints)
      ? session.manualPoints.filter((point) => Number.isInteger(point?.left) && Number.isInteger(point?.right))
      : [];
    updateAlignmentStatus();
    for (const id of paneIds) {
      const savedAnchor = session.anchors?.[id];
      if (panes[id].model && Number.isInteger(savedAnchor)) {
        // Session format before v2 stored only the character position.
        panes[id].anchor = savedAnchor;
        panes[id].anchorDy = 0;
      } else if (panes[id].model && Number.isInteger(savedAnchor?.position)) {
        panes[id].anchor = savedAnchor.position;
        panes[id].anchorDy = Number.isFinite(savedAnchor.dy) ? savedAnchor.dy : 0;
      }
    }
    requestAnimationFrame(() => {
      for (const id of paneIds) {
        const pane = panes[id];
        if (pane.model) placeAnchor(id, { position: pane.anchor, dy: pane.anchorDy }, `session-restore:${id}`);
      }
      traceBoth("session-restore-finished", { manualPointCount: manualPoints.length });
    });
  } catch (error) {
    trace("session-restore-failed", { message: error.message });
    console.warn("Could not restore local reading state", error);
  }
}

$("#left-file").addEventListener("change", (event) => event.target.files[0] && openBook("left", event.target.files[0]));
$("#right-file").addEventListener("change", (event) => event.target.files[0] && openBook("right", event.target.files[0]));
$("#download-trace").addEventListener("click", downloadTrace);
$("#reset-views").addEventListener("click", resetViewports);
$("#decrease-font").addEventListener("click", () => applyReaderFontSize(readerFontSize - 1));
$("#increase-font").addEventListener("click", () => applyReaderFontSize(readerFontSize + 1));
$("#explain-selection").addEventListener("pointerdown", (event) => event.preventDefault());
$("#explain-selection").addEventListener("click", () => {
  if (activeSelection) requestExplanation(activeSelection.pane, activeSelection, "selection-control");
});
$("#close-lookup").addEventListener("click", closeLookupCard);
$("#open-lookup-tab").addEventListener("click", openLookupInNewTab);
$("#lookup-drag-handle").addEventListener("pointerdown", (event) => {
  if (event.button !== 0 || event.target.closest("button")) return;
  const card = $("#lookup-card");
  const rect = card.getBoundingClientRect();
  card.style.left = `${rect.left}px`;
  card.style.top = `${rect.top}px`;
  card.style.transform = "none";
  lookupDrag = { pointerId: event.pointerId, offsetX: event.clientX - rect.left, offsetY: event.clientY - rect.top };
  event.currentTarget.setPointerCapture(event.pointerId);
  event.preventDefault();
});
$("#lookup-drag-handle").addEventListener("pointermove", (event) => {
  if (!lookupDrag || lookupDrag.pointerId !== event.pointerId) return;
  const card = $("#lookup-card");
  const rect = card.getBoundingClientRect();
  const left = Math.max(0, Math.min(window.innerWidth - Math.min(rect.width, 96), event.clientX - lookupDrag.offsetX));
  const top = Math.max(0, Math.min(window.innerHeight - Math.min(rect.height, 48), event.clientY - lookupDrag.offsetY));
  card.style.left = `${left}px`;
  card.style.top = `${top}px`;
});
$("#lookup-drag-handle").addEventListener("pointerup", (event) => {
  if (lookupDrag?.pointerId === event.pointerId) lookupDrag = null;
});
$("#lookup-drag-handle").addEventListener("pointercancel", () => { lookupDrag = null; });
window.addEventListener("keydown", (event) => {
  if (event.key === "Escape" && !$("#lookup-card").hidden) closeLookupCard();
  if ((event.ctrlKey || event.metaKey) && event.key.toLowerCase() === "q") {
    event.preventDefault();
    if (!bridgeToken || !window.confirm("Stop the local Mirror Margin server?")) return;
    fetch("/api/shutdown", { method: "POST", headers: { "X-Mirror-Margin-Token": bridgeToken } })
      .catch(() => {})
      .finally(() => { document.title = "Mirror Margin — stopped"; });
  }
});
$("#add-alignment").addEventListener("click", () => {
  if (syncInProgress) return;
  const operation = beginSync("manual-point", "manual-alignment");
  measureAnchor("left", "manual-point:left", (leftAnchor) => {
    if (activeSync !== operation) return;
    measureAnchor("right", "manual-point:right", (rightAnchor) => {
      if (activeSync !== operation) return;
      if (leftAnchor && rightAnchor) {
        const point = { left: leftAnchor.position, right: rightAnchor.position };
        manualPoints.push(point);
        updateAlignmentStatus();
        scheduleSave();
        traceBoth("manual-point-added", { point, manualPointCount: manualPoints.length });
      } else {
        traceBoth("manual-point-failed");
      }
      releaseSync(operation, { reason: "manual-point" });
    });
  });
});
$("#reset-alignment").addEventListener("click", () => {
  manualPoints = [];
  updateAlignmentStatus();
  scheduleSave();
  traceBoth("manual-points-reset");
});

for (const id of paneIds) {
  const host = $(`#${id}-reader`);
  host.textContent = id === "left" ? "Open the sample-language FB2." : "Open the reference-language FB2.";
}

restoreSession();
loadLookups().catch((error) => {
  trace("lookup-load-failed", { message: error.message });
  console.warn("Could not load lookup history", error);
});
