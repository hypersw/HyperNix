import { Compartment, EditorState, RangeSetBuilder } from "@codemirror/state";
import { Decoration, EditorView } from "@codemirror/view";

const $ = (selector) => document.querySelector(selector);
const paneIds = ["left", "right"];
const intermediateSyncInterval = 48;
const panes = Object.fromEntries(paneIds.map((id) => [id, {
  id, view: null, model: null, source: null, anchor: 0, anchorDy: 0, measureRequest: 0, syncTimer: null, intermediateTimer: null, resizeObserver: null,
  decorations: new Compartment(), selectionTimer: null,
  suppressScrollUntil: 0, suppressionReason: null,
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

const theme = EditorView.theme({
  "&": { height: "100%", backgroundColor: "transparent", color: "#2c2924" },
  ".cm-scroller": {
    fontFamily: 'Georgia, "Iowan Old Style", serif', fontSize: "20px", lineHeight: "1.72",
    overflowAnchor: "none", overflowY: "scroll", overflowX: "hidden", scrollbarGutter: "stable",
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

function textOf(element) {
  return normalizeText(element?.textContent ?? "");
}

function parseFb2(source, fallbackTitle) {
  const xml = new DOMParser().parseFromString(source, "application/xml");
  if (xml.querySelector("parsererror")) throw new Error("The selected file is not valid FB2 XML.");
  const bodies = [...xml.getElementsByTagNameNS("*", "body")];
  const body = bodies.find((candidate) => !candidate.getAttribute("name"));
  if (!body) throw new Error("The FB2 file has no main text body.");

  const bookTitle = textOf(xml.querySelector("description title-info book-title")) || fallbackTitle;
  const blocks = [];
  const chapters = [];
  const addBlock = (runs, kind, chapterId) => {
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
    const value = normalizedRuns.map((run) => run.text).join("");
    if (!value) return;
    blocks.push({ kind, chapterId, text: value, runs: normalizedRuns });
  };

  const collectSection = (section, chapter, depth) => {
    const title = directChild(section, "title");
    if (title) addBlock(inlineRuns(title), depth === 0 ? "title" : "heading", chapter.id);
    for (const child of section.children) {
      const tag = nameOf(child);
      if (tag === "title") continue;
      if (tag === "section") collectSection(child, chapter, depth + 1);
      else if (tag === "p" || tag === "subtitle" || tag === "text-author") addBlock(inlineRuns(child), tag === "text-author" ? "epigraph" : "paragraph", chapter.id);
      else if (tag === "poem" || tag === "epigraph" || tag === "cite") {
        for (const paragraph of child.querySelectorAll(":scope p")) addBlock(inlineRuns(paragraph), tag === "epigraph" ? "epigraph" : "paragraph", chapter.id);
      }
    }
  };

  const topSections = directChildren(body, "section");
  const sections = topSections.length ? topSections : [body];
  sections.forEach((section, index) => {
    const title = textOf(directChild(section, "title")) || `Chapter ${index + 1}`;
    const chapter = { id: `chapter-${index}`, title, from: 0, to: 0 };
    chapter.from = blocks.length;
    collectSection(section, chapter, 0);
    chapter.to = blocks.length;
    if (chapter.to > chapter.from) chapters.push(chapter);
  });
  if (!blocks.length) throw new Error("The FB2 body has no readable prose blocks.");

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
  for (const chapter of chapters) {
    const first = blocks[chapter.from];
    const last = blocks[chapter.to - 1];
    chapter.from = first.from;
    chapter.to = last.to;
  }
  return { title: bookTitle, text, decorations, chapters };
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

function mockAnswer(text) {
  const compact = normalizeText(text);
  const wordCount = compact ? compact.split(" ").length : 0;
  return `Mock explanation: “${compact}” has been saved as a ${wordCount === 1 ? "word" : `${wordCount}-word selection`}. A future Codex responder will replace this placeholder while preserving the same local history and cached answer.`;
}

function showLookupCard(id, record) {
  const card = $("#lookup-card");
  activeLookup = record;
  $("#lookup-text").textContent = record.text;
  $("#lookup-answer").textContent = record.answer;
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
  const answer = escapeHtml(activeLookup.answer);
  const contents = `<!doctype html><meta charset="utf-8"><title>${title} — Mirror Margin</title><style>body{max-width:52rem;margin:4rem auto;padding:0 1.5rem;background:#f1ede4;color:#29261f;font:18px/1.6 Georgia,serif}small{font:14px system-ui;color:#71695d}h1{line-height:1.25}p{white-space:pre-wrap}</style><small>Mirror Margin · mock Codex response · looked up ${activeLookup.count} ${activeLookup.count === 1 ? "time" : "times"}</small><h1>${title}</h1><p>${answer}</p>`;
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
    answer: existing?.answer ?? mockAnswer(text),
    count: (existing?.count ?? 0) + 1,
    firstViewedAt: existing?.firstViewedAt ?? now,
    lastViewedAt: now,
  };
  lookups.set(key, record);
  refreshLookupDecorations();
  showLookupCard(id, record);
  trace("lookup-requested", { pane: id, trigger, key, count: record.count, length: text.length });
  try {
    await storeLookup(record);
  } catch (error) {
    trace("lookup-store-failed", { message: error.message, key });
    console.warn("Could not save lookup history", error);
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
  view.requestMeasure({
    read(measuredView) {
      const viewport = measuredView.scrollDOM.getBoundingClientRect();
      const x = viewport.left + Math.max(1, Math.min(viewport.width - 1, viewport.width / 2));
      const maximumProbe = Math.min(80, Math.max(1, viewport.height - 1));
      for (let offset = 1; offset <= maximumProbe; offset += 4) {
        const position = measuredView.posAtCoords({ x, y: viewport.top + offset });
        if (position === null) continue;
        const character = measuredView.coordsAtPos(position);
        if (character) return { position, dy: character.top - viewport.top, probeOffset: offset };
      }
      return null;
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
  for (let index = 0; index < Math.min(left.chapters.length, right.chapters.length); index += 1) {
    automaticPoints.push({ left: left.chapters[index].from, right: right.chapters[index].from });
    automaticPoints.push({ left: left.chapters[index].to, right: right.chapters[index].to });
  }
  automaticPoints.push({ left: left.text.length, right: right.text.length });
  manualPoints = [];
  updateAlignmentStatus();
  trace("automatic-points-rebuilt", { automaticPointCount: automaticPoints.length });
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
  pane.suppressScrollUntil = Math.max(pane.suppressScrollUntil, performance.now() + 400);
  pane.suppressionReason = reason;
  view.dispatch({ effects: EditorView.scrollIntoView(position, { y: "start", yMargin: 0 }) });
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
          if (attempt < 2) place(attempt + 1);
          else finish();
          return;
        }
        const correction = measurement.characterTop - measurement.viewportTop - dy;
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
  trace("book-open-started", { pane: id, name, sourceLength: source.length });
  const model = parseFb2(source, name.replace(/\.fb2$/i, ""));
  makeView(id, model, { name, source });
  traceBoth("book-opened", { pane: id, name, documentLength: model.text.length, chapterCount: model.chapters.length });
}

async function openBook(id, file) {
  try {
    openBookSource(id, await file.text(), file.name);
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
    for (const id of paneIds) {
      const book = session.books[id];
      if (book?.source && book?.name) openBookSource(id, book.source, book.name);
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
