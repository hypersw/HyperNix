# Mirror Margin

An early, local-first prototype for reading two FB2 books in parallel.

Run it from the HyperNix checkout:

```sh
nix run .#Modules-Programs-MirrorMargin
```

The launcher builds static files, serves them on `127.0.0.1:8000`, and opens the
URL in the default browser.  It uses content-fingerprinted assets, a fresh URL
on each launch, and no-cache response headers, so a new build does not depend on
a manual hard refresh.  Set `NO_BROWSER=1` to leave the browser closed or set
`PORT` to choose another local port.  The generated site has no server-side
component and can be hosted by any trivial static-file server.

If port 8000 is already occupied, the launcher exits before opening a browser;
choose another port, for example `PORT=8011 nix run .#Modules-Programs-MirrorMargin`.

The local launcher is Node-based. It serves the static files and, for an
explicit lookup, runs the Nix-provided Codex CLI through a loopback bridge. A
portable Windows-suitable asset ZIP can be built with:

```sh
nix build .#Modules-Programs-MirrorMargin.portableZip
```

After copying and extracting it on Windows, run `node bridge.mjs --site site`.
That machine needs Node.js plus its own logged-in Codex CLI; the distribution
contains no executable, Nix store reference, or credential.

## Prototype behavior

- Loads FB2, common FB2-in-ZIP archives, and unencrypted EPUB 2/3 archives
  into each read-only CodeMirror view. EPUB content is normalized into the
  same text model; its OPF spine and NCX/TOC supply chapter anchors.
- Renders only CodeMirror's viewport region rather than an eager browser DOM for
  the entire book.
- Uses the character position at the top of each pane as its logical anchor.
  A resize restores that anchor after wrapping changes.
- Saves the original FB2 text, titles, reading anchors, and manual alignment
  points in browser-local IndexedDB, then restores them after a reload.
- Creates automatic pairs from matching semantic anchors—numbered chapters,
  parts, and epilogues—rather than raw section order. **Add alignment point**
  adds a user pair at the two current anchors. Mapping between pairs is linear
  in character offsets, so the two translations need not have matching
  paragraphs.
- Supports paragraph text plus simple FB2 bold, emphasis, and links. Common
  FB2-in-ZIP and unencrypted EPUB 2/3 files are supported; images and notes
  are intentionally outside this slice.
- Keeps a book-independent local lookup ledger in IndexedDB. Double-click/tap
  selects a word; triple-click/tap selects a sentence; any settled selection
  gets an **Explain** control. On a desktop, `Ctrl`-click queries the current
  selection, or the clicked word when there is no selection.
- Starts a loopback-only Codex bridge when run through `nix run`. It uses the
  pinned Nix `codex` CLI with `gpt-6-luna` and low reasoning effort, sending
  only the explicitly selected text. Responses are cached locally. Lookup data
  is stored as normalized text plus append-only local events, so a later sync
  provider can merge it without tying history to a particular book. Looked-up
  words receive a subtle dotted underline; multi-word selections use a fading
  edge highlight.

No book text is sent until the user explicitly selects/queries it. The bridge
uses the user's local Codex login from `~/.codex`; no credentials enter the
flake, site, or browser storage.
