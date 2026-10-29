# Text browser — design & work plan

Status: **planned, not started.** This document is the spec for a text-mode
web browser that lives in a DN desktop window: HTML5 parsing, a CSS subset, a
text renderer into the `TWin` cell grid, and a JS bridge that drives an
**external** process. The target is to be a better browser than `lynx` on the
sites that matter — documentation, news, RFCs, wikis, local files — and to
render JS-driven pages that `lynx` cannot load at all.

## Why

DN already opens local files in the viewer (F3) and the editor (F4), and it
already reaches the network through external tools: `bsdtar` for archives
(`src/dnarcvfs.pas`), the OpenSSH client for SFTP (`src/dnsftp.pas`), and
`ffplay`/`mpg123` for audio (`src/dnplayer.pas`). It has no way to open a
**URL**.

`lynx` is the reference, and it is old: it renders HTML 4, has weak UTF-8
support, no JS, and no link to a file manager. The gap this browser fills is
not "more features than lynx" — it is:

- **Modern HTML5** — `lynx` mishandles HTML5 elements, and its CSS support
  is a stub.
- **Real UTF-8** — the `dnscreen` helpers (`Utf8Len`, `Utf8Copy`,
  `Utf8PadRight`) already do codepoint-correct column math.
- **Integration with the panels** — a downloaded file lands in the panel; the
  current panel path is a base URL; `Enter` on a `.html` file opens it in the
  browser window like `Enter` on a `.txt` opens MicroEd.
- **JS-driven pages** — `lynx` does not execute scripts, so it cannot read
  SPAs and modern news sites. This browser executes the DOM-mutating scripts
  in an external process and renders the resulting DOM.

## Scope

In scope (this milestone):

- **HTTP/HTTPS fetch** through `curl` (the existing external-tool pattern),
  with redirects, cookies, gzip, and a disk cache under
  `~/.cache/dnfpc/browser/`.
- **HTML5 parsing**: the tokenizer state machine, tree construction with
  insertion modes, the implied-tag rules (`<p>`, `<li>`, `<table>`), and the
  foster-parenting rules for stray table content.
- **A CSS subset**: type / class / id / descendant selectors; the cascade and
  specificity; `display` (`block`, `inline`, `none`, `list-item`, `table`),
  `font-weight`, `font-style`, `text-decoration`, `text-align`, `margin`,
  `padding`, `border`, `width`/`height` in `em`/`px`/`%`, `color`,
  `background-color`, `list-style-type`, `white-space`, and the `@media`
  `screen`/`all` block. No `flex`, no `grid`, no animations.
- **Layout**: block and inline flow, line breaking, tables as fixed text
  grids, lists, `<pre>` verbatim, `<hr>`, and images as `[alt]` placeholders.
- **Text render into a `TWin` cell grid**: rows of `(codepoint, fg, bg,
  attrs)`, scrollback, and a link map from screen cells to targets.
- **Navigation**: `Tab`/`Shift-Tab` and arrow keys move the cursor between
  links; `Enter` follows; `Backspace`/`Alt-Left` goes back; `g` opens a URL
  prompt; `Alt-Home` goes to the start page; `Ctrl-R` reloads; `F3`/`F4` open
  the current page's HTML source in the viewer/editor.
- **History, bookmarks, start page**: a persisted history file and a
  `dn.mnu`-style bookmark file under the config directory.
- **`file://` and `data:` URLs** through the same loader, so local HTML is a
  first-class page.
- **JS bridge**: a `TBrowserJs` class that runs an external JS process,
  feeds it the parsed DOM, receives the mutated DOM, and renders that. See
  "JS bridge" below.

Out of scope (deliberately):

- **A JS engine inside DN.** The JS runs in an external process. This is the
  decision that keeps the milestone at 11–16 months instead of 2.5–3 years.
- **`flex`/`grid`, animations, transforms, transitions.** The text renderer
  cannot show them; the cascade computes their used values away.
- **`canvas`, `webgl`, video, audio elements.** `canvas` renders as
  `[canvas]`, media as `[media]`.
- **Frames and iframes.** An `<iframe>` renders as a nested block; no
  separate browsing contexts.
- **Form submission beyond `GET`/`POST`** — `GET` builds a query string,
  `POST` sends a body; no `multipart` uploads in v1.
- **Web APIs beyond the DOM**: no `fetch`, no `WebSocket`, no
  `IntersectionObserver`, no `localStorage`. A script that calls a missing
  API gets a thrown `ReferenceError`; the page still renders its static DOM.

## Fetch — `src/dnhttp.pas`

New unit `src/dnhttp.pas` (pure logic where possible — unit-tested):

- `THttpClient` class wrapping `curl`:
  - `Get(const Url: AnsiString; out Body: AnsiString; out FinalUrl: AnsiString;
    out Err: AnsiString): Boolean`.
  - `CurlCmd` resolves the binary from `PATH`, or from the `DN_CURL_CMD`
    environment variable (the test seam, like `DN_SFTP_CMD`).
  - Arguments: `-sSL --max-time 30 --compressed --cookie-jar <jar>
    --cookie <jar> -A <ua> -w` for the final URL and the status code.
  - Response headers land in a sidecar file (`-D`), so `Content-Type` and
    `Location` are readable without a second request.
  - A **disk cache**: key = SHA-1 of the URL; store the body, the headers and
    a timestamp under `~/.cache/dnfpc/browser/`. `Cache-Control: no-store`
    and `POST` responses are never cached.
  - `curl` runs through the existing `RunCapture`-style pipe
    (`src/dnvfs.pas:117`), with a timeout and a `Ctrl-C` kill.
- `TUrl` helpers: parse `scheme://user@host:port/path?query#fragment`;
  resolve a relative URL against a base (RFC 3986 merge and remove-dot
  algorithm); percent-decode; build a query string from a form.
- `TCookieJar`: a Netscape-format cookie file read and written, so `curl`
  does the cookie work and DN only owns the file.

The `DN_CURL_CMD` seam lets tests point at a shell script that prints a
fixture body, so no test touches the network.

## HTML parsing — `src/dnhtml.pas`

New unit `src/dnhtml.pas` (pure logic, no ncurses — unit-tested):

- `THtmlTokenizer` — the WHATWG tokenizer state machine over a UTF-8 buffer:
  data, tag open, tag name, attribute name / value, comment, doctype,
  RAWTEXT (`<script>`, `<style>`), and character references.
- `THtmlParser` — tree construction:
  - the **stack of open elements** and the **list of active formatting
    elements**;
  - **insertion modes**: initial, before html, before head, in head, after
    head, in body, in table, in table text, in caption, in column group,
    in table body, in row, in cell, in select, in template, after body,
    after after body;
  - **implied end tags** and the `<p>`-closing rules;
  - **foster parenting** for stray table content;
  - **adoption agency** for misnested formatting elements (simplified:
    handle the common `<b><i></b></i>` case; full agency is a stretch).
- `TDomNode` — element / text / comment nodes with attributes, children,
  parent, and a tag-name index. `TDomDoc` — the document, the `head`/`body`
  shortcuts, and `GetElementById` / `GetElementsByTagName` /
  `QuerySelector` (the simple-selector subset only).
- `THtmlEntities` — the named character reference table (the common
  subset: `&amp;`, `&lt;`, `&gt;`, `&quot;`, `&nbsp;`, `&mdash;`,
  `&copy;`, the accented Latin range) plus numeric references.
- `HTMLSanitize` — strip `<script>` bodies from the *static* render when the
  JS bridge is disabled; keep them when it is enabled.

The parser is validated against the `html5lib` tree-construction test data
(hand-translated fixtures, not the full suite) and against a corpus of real
pages: an RFC page, a Wikipedia article, a Hacker News thread, a
documentation page, and a news article.

## CSS — `src/dncss.pas`

New unit `src/dncss.pas` (pure logic, no ncurses — unit-tested):

- `TCssTokenizer` — tokens per CSS Syntax Level 3: ident, function, at-keyword,
  hash, string, url, number, percentage, dimension, delim, and the block
  structures.
- `TCssParser` — rules, selectors, declarations. At-rules: `@media` (the
  `screen`/`all` condition only), `@import` (resolved as a second fetch),
  `@font-face` and `@keyframes` (skipped).
- `TCssSelector` — the supported subset: type, `.class`, `#id`, `*`,
  descendant (space), child (`>`), and the comma list. `:hover`, `:focus`,
  `::before`, `::after`, `:nth-child` and attribute selectors are parsed
  and **ignored**.
- `TCssCascade` — specificity, `!important`, source order, and the
  inherited properties (`color`, `font-*`, `text-align`, `white-space`,
  `list-style-type`).
- `TCssStyle` — the computed style record per node:
  `Display`, `FontWeight`, `FontStyle`, `Underline`, `Align`, `Color`,
  `BgColor`, `MarginTop/Right/Bottom/Left`, `Padding*`, `Width`, `Height`,
  `ListStyle`, `WhiteSpace`, `Border`.
- `TCssDefaults` — the user-agent stylesheet: the HTML5 default rendering
  rules (block vs inline per element, `<b>`/`<strong>` bold, `<i>`/`<em>`
  italic, `<h1>`–`<h6>` size, `<ul>`/`<ol>` markers, `<pre>` monospace,
  `<table>` borders, `<hr>`, `<br>`).

## Layout — `src/dnlayout.pas`

New unit `src/dnlayout.pas` (pure logic, no ncurses — unit-tested):

- `TLayoutBox` — a box record: `X, Y, W, H`, the node, the computed style,
  and the children. The output is a **box tree**, not pixels.
- Block layout: stack children vertically, apply `margin` collapse (the simple
  adjacent-sibling case), compute `width` from the containing block.
- Inline layout: gather inline runs, break at whitespace, wrap at the
  content width, apply `white-space: pre` and `nowrap`.
- Table layout: a **fixed grid** — count columns from the first row, equal
  widths by default, honour `<td width>` and `<th>` (bold, centred). Cell
  content is laid out into its column rect.
- Lists: `<ul>`/`<ol>` markers (`*`, `-`, `1.`, `a.`, `i.`), nesting
  indentation, and `list-style-type`.
- Images: `<img>` becomes `[alt]` or `[img]` sized to `width`/`height`
  attributes in columns.
- `TLayoutEngine.Layout(Doc, ViewportCols, ViewportRows): TLayoutBox` is
  the entry point; it is a pure function of the DOM, the stylesheet and the
  viewport, so it is unit-tested without a terminal.

## Text render — `src/dnbrowser.pas`

New unit `src/dnbrowser.pas` with a `TBrowserWin = class(TWin)`, following
the `dnview.pas` / `dnedit.pas` / `dnplayer.pas` pattern exactly:

- `OpenBrowser(const Url: AnsiString): TBrowserWin` — the entry point.
- `DrawContent` — walk the box tree, draw each text run at its
  `(row, col)` into the window's inner rect, clipped to the frame. Use the
  `dnscreen` UTF-8 helpers for column math. Colors map to the fixed
  `dnscreen` pairs where possible, and to an **on-demand pair cache**
  (`PairFor(fg, bg)`, LRU, `init_pair` from a free id) like the terminal
  plan (`TERMINAL.md` §3).
- `StatusText` — the URL, the title, the load state, and the JS state.
- `HandleKey` — the navigation keys above, plus the scroll keys.
- `HandleClick` — click a link to follow it; click the scrollbar; wheel to
  scroll.
- `ConfirmClose` — kill the JS child process and the `curl` child, so no
  stray process is left.
- `TLinkMap` — a per-screen map from cell to link target, rebuilt on every
  layout and scroll; the cursor snaps to the nearest link on `Tab`.

The window opens from:

- `Tools > Browser` (a new `cmBrowser` command id in
  `src/dnmenu.pas` and a menu item, the `cmPlayer` / `cmConsole`
  pattern);
- `Enter` on a `.html`/`.htm`/`.xhtml` file in a panel: the `dn.ext`
  mapping (`src/dnconfig.pas:70`) resolves the extension, and a new
  `@browse` verb opens the browser window (the `@edit` / `@view` verbs in
  `TryLaunch`, `src/dn.pas:751`, are the model);
- a `http://` / `https://` URL typed on the command line and `Enter`
  pressed: the command-line path runs a command, so a URL opens the browser
  instead (a branch in the command execution path).

## JS bridge — `src/dnjs.pas`

New unit `src/dnjs.pas` (pure logic for the protocol, unit-tested):

- `TBrowserJs` — the bridge to the external JS process:
  - `Start(const Scripts: TStringList; const Html: AnsiString)`;
  - `ApplyDom(Doc: TDomDoc; out Err: AnsiString): Boolean` — send the
    serialized DOM, receive the mutated DOM;
  - `Stop` — `fpKill` + `fpWaitPid`, no zombie.
- **The external process** is resolved from `DN_JS_CMD` (the test seam),
  then `deno`, then `node`, then `quickjs`, then `d8`. If none is
  present, the bridge is **off**: scripts are skipped and the page renders
  its static DOM with a status note `js: no engine`.
- **The protocol** is a line-based JSON over the child's stdin/stdout, one
  request per line:
  - request: `{"op":"dom","html":"<serialized DOM>"}`;
  - reply: `{"op":"dom","html":"<serialized DOM>"}` or
    `{"op":"error","message":"..."}`.
  The serialized DOM is a **flat node list**: `[{id, parent, tag, text,
    attrs:{...}}]`, which is simple to build and parse on both sides.
- **The JS shim** (shipped as a string in `dnjs.pas`, written to a temp
  file at `Start`): a small JS program that
  - builds a **minimal DOM** from the flat list,
  - provides the DOM API: `document.getElementById`,
    `querySelector` (the simple-selector subset), `createElement`,
    `appendChild`, `removeChild`, `textContent`, `innerHTML`,
    `setAttribute`, `getAttribute`, `classList`, `addEventListener`
    (a no-op stub — events are not delivered),
  - runs the page's scripts in order,
  - serializes the DOM back to the flat list and prints it.
- **Sandboxing**: the child runs with no network (no `fetch` shim, so a
  call throws), no filesystem, and a wall-clock timeout (`DN_JS_TIMEOUT_MS`,
  default 3000 ms). A timeout kills the child and renders the **pre-script**
  DOM with a status note `js: timeout`.
- **Why an external process and not an in-process engine**: the DN code is
  synchronous, single-threaded, and has no GC (`TThread` is unused, and
  memory is manual `Free` / `try..finally` throughout). A JS engine needs a
  GC and an event loop. Running it in-process would force a GC and a
  cooperative scheduler into `TWin`. Running it out of process keeps DN as
  it is and puts the GC where it belongs.

## Work plan

Each step lands with tests in `tests/` and leaves `make test` green.

1. **`dnhttp.pas` skeleton** — `THttpClient`, `TUrl`, `TCookieJar`, the
   `DN_CURL_CMD` seam, and the disk cache. Unit tests point
   `DN_CURL_CMD` at a script that prints a fixture. No UI.
2. **`dnhtml.pas` tokenizer** — `THtmlTokenizer` over a UTF-8 buffer.
   Unit tests feed byte streams and assert on the token list; include the
   `html5lib` fixtures for the common cases.
3. **`dnhtml.pas` tree construction** — the insertion modes, the implied
   end tags, and foster parenting. Unit tests assert on the DOM tree; the
   `html5lib` tree-construction fixtures are the reference.
4. **`dncss.pas`** — tokenizer, parser, selectors, cascade, the
   user-agent stylesheet. Unit tests assert on the computed style per node.
5. **`dnlayout.pas`** — block, inline, table and list layout into the
   box tree. Unit tests assert on the box tree for a fixture page; this is
   the largest chunk of pure logic and it needs no terminal.
6. **`dnbrowser.pas` window** — draw the box tree, scroll, and the link
   map. TUI tests open the window and assert on rows and the cursor.
7. **Navigation** — `Tab`/arrows, `Enter`, `Backspace`, `g`, `Ctrl-R`,
   history and bookmarks. TUI tests drive keys and assert on the status
   line and the URL.
8. **`dnjs.pas` protocol** — `TBrowserJs`, the flat-DOM serialize and
   parse, the shim, and the timeout. Unit tests point `DN_JS_CMD` at a
   script that echoes a mutated DOM; no real engine needed.
9. **JS integration** — the pre- and post-script DOM in the render path,
   the `js: no engine` and `js: timeout` status notes. TUI tests with a
   fixture page and a fake engine script.
10. **Integration** — `cmBrowser` menu item, the `dn.ext` entry
    `html=@browse` (the `@edit` / `@view` pattern), the command-line
    URL branch, `ConfirmClose`. End-to-end tests through the menu, through
    `Enter` on a file, and through a typed URL with `DN_CURL_CMD`.

## Test seams

- `DN_CURL_CMD` — the HTTP fetch command (like `DN_SFTP_CMD`).
- `DN_JS_CMD` — the external JS process (like `DN_PLAYER_CMD`).
- `DN_JS_TIMEOUT_MS` — the JS wall-clock timeout (default 3000).
- `DN_BROWSER_TICK_MS` — the window tick, if the render needs one
  (like `DN_PLAYER_TICK_MS`).
- `DN_BROWSER_CACHE_DIR` — the cache and cookie directory.
- `DN_BROWSER_UA` — the user-agent string.

The `tests/` harness (`tests/tuitest.py`) already runs a curses app in a pty
and asserts on screen text, colors and layout; the browser tests use it
exactly as `tests/test_console.py` and `tests/test_sftp.py` do.

## Risks

- **Layout is the hard part, not JS.** The text renderer cannot show
  `flex`/`grid`, and real pages lean on them. The mitigation is the
  target: documentation, news, RFCs, wikis, local files — sites whose
  layout is block and inline flow. A page that is a `grid` app renders as
  a flat column; the status line says `layout: degraded`.
- **The DOM bridge is the underestimated part.** A flat node list is simple
  to serialize, but a script that builds a large DOM or mutates it in a loop
  makes the round trip expensive. The mitigation is the timeout and the
  size cap (`DN_JS_MAX_NODES`, default 20000); past the cap the child is
  killed and the pre-script DOM renders.
- **No `fetch` in the sandbox** means a script that loads data fails. The
  mitigation is the status note; the page still renders its static DOM.
  A later milestone can add a `fetch` shim backed by `dnhttp.pas`, but that
  is out of scope here.
- **`curl` and the JS engine are external dependencies.** `lynx` is one
  binary; this browser is DN + `curl` + an engine. The trade is explicit:
  more functionality, more dependencies. `curl` is on every target already;
  a JS engine is not, and the bridge is off without one.
- **`Ctrl-L` collision** — check the key map before choosing the browser
  hotkey; the `dn.ext` mapping and the menu item are the primary entries,
  and they have no collision.
- **Correctness is validated by real pages, not unit tests alone.** The
  `html5lib` fixtures cover the parser; the layout needs a corpus of real
  pages, and debugging is iterative.
- **Character sets** — a page in a legacy encoding (CP1251, CP866) needs a
  codepage table, the same one the viewer wants (`ROADMAP.md` M4, 8.1).
  Until it lands, a non-UTF-8 page renders with replacement characters.

## Not doing (deliberately)

- **A JS engine inside DN.** The whole point of the bridge is to keep the
  GC and the event loop out of the synchronous DN process. See "JS bridge".
- **A headless-browser wrapper.** Wrapping Chromium would give a browser,
  but not *our* renderer, and it would make the dependency a browser
  runtime. This milestone is a renderer of our own; the JS bridge is the
  concession to the modern web, and it is bounded.
- **`flex`/`grid`, animations, `canvas`, media, frames.** The text
  renderer cannot show them; the cascade computes them away or the layout
  degrades.
- **Forms beyond `GET`/`POST`.** No file uploads, no `multipart` in v1.
- **TLS of our own.** `curl` owns TLS; DN never sees a certificate.

## Where it plugs in

- `src/dnmenu.pas` — a new `cmBrowser` command id and a
  `Tools > Browser` menu item (the `cmPlayer` / `cmConsole` pattern).
- `src/dn.pas` — the `cmBrowser` case in `ExecCmd`, the `@browse` verb
  in `TryLaunch` (the `@edit` / `@view` branches are the model), the
  command-line URL branch, and the `OpenBrowser` call.
- `src/dnconfig.pas` — the `dn.ext` mapping already resolves an
  extension to a command; `@browse` joins `@edit` / `@view`.
- `src/dnhighlite.pas` — the `FILES *.htm;*.html;*.xml;*.xhtml;*.svg;*.plist`
  group already marks HTML files; the browser entry uses the same
  extensions.
- `Makefile` — the new units in the `bin/unittests` dependency line, so
  the pure-logic units are unit-tested (`dnhtml`, `dncss`, `dnlayout`,
  `dnhttp`, `dnjs`).

## Milestone size

- **Pure logic** (`dnhttp`, `dnhtml`, `dncss`, `dnlayout`, `dnjs`):
  ~13–20k lines of Pascal, 9–13 months, unit-tested without a terminal.
- **UI** (`dnbrowser`): ~1.5–3k lines, 2–3 months, TUI-tested.
- **Total: ~15–23k lines, 11–16 months** for one strong developer,
  plus the JS shim (a few hundred lines of JS, shipped as a string).

This is the honest size of the milestone. It is a project of its own, on the
scale of the whole current DN (11 891 lines); it is not a feature of DN.
