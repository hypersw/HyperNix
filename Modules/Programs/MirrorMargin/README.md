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

## Prototype behavior

- Loads one FB2 XML file into each read-only CodeMirror view.
- Renders only CodeMirror's viewport region rather than an eager browser DOM for
  the entire book.
- Uses the character position at the top of each pane as its logical anchor.
  A resize restores that anchor after wrapping changes.
- Saves the original FB2 text, titles, reading anchors, and manual alignment
  points in browser-local IndexedDB, then restores them after a reload.
- Creates automatic pairs at corresponding top-level chapter starts and ends;
  **Add alignment point** adds a user pair at the two current anchors.  Mapping
  between pairs is linear in character offsets, so the two translations need
  not have matching paragraphs.
- Supports paragraph text plus simple FB2 bold, emphasis, and links.  Images,
  notes, `.fb2.zip`, and Codex explanations are intentionally not in this first
  slice.

The forthcoming lookup feature should use a deliberately separate local bridge:
the static reader must never be able to send book text to a model without an
explicit user action.
