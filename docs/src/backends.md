# Backends

Treebars is backend-agnostic. The progress interface dispatches to
backend-specific implementations via Julia's type system. A `nothing` backend
disables progress (all operations return `nothing`).

## Term.jl (`:term`)

Terminal progress bars using [Term.jl](https://github.com/FedeClaworkers/Term.jl).
Loaded via the `TermExt` package extension — `using Term` activates it.

```julia
using Treebars, Term

p = initialize_progress!(:term; width=120)
```

Features:

- Background render thread for smooth animation
- ETA calculation
- Coloured progress bars with completion percentage
- Labelled sub-rows for metadata via `update_progress!` kwargs

## StateProgress (`:state`)

Thread-safe, inspectable progress backend for web / remote / polling use
cases. State lives in a mutable [`StateProgress`](@ref) struct guarded by a
`ReentrantLock`.

```julia
p = initialize_progress!(:state; description="My task")
child = initialize_progress!(p, 100; description="Step 1")
update_progress!(child, 50)
```

Each node exposes lifecycle queries — see [`is_pending`](@ref),
[`is_running`](@ref), [`is_finished`](@ref), [`is_failed`](@ref),
[`is_skipped`](@ref), [`is_reused`](@ref), [`duration`](@ref).

## HTMXObjects.jl integration

When `HTMXObjects` is loaded, `StateProgress` trees can be rendered as HTML.
Loaded via the `HTMXObjectsExt` package extension.

```julia
using Treebars, HTMXObjects

root = initialize_progress!(:state; description="Fitting")
job = initialize_progress!(root, 100; description="Chain 1")
update_progress!(job, 42)

html = htmx_render(root)   # HTMX Node tree
```

The rendered HTML uses `<progress>` elements plus toggle pills (rendered by
[`htmx_render_children`](@ref)) that group pending, finished, reused, skipped,
and failed children at each tree level.

### Assets

Include the styles + duration ticker once in your app's `<head>` via
`extra_head`:

```julia
htmx(...; extra_head=(htmx_treebar_styles(), htmx_treebar_script(), ...))
```

- [`htmx_treebar_styles`](@ref) returns a `<style>` node with all
  `treebar-*` CSS classes.
- [`htmx_treebar_script`](@ref) returns a `<script>` node with a client-side
  duration ticker that advances running nodes locally between server polls
  (so the elapsed-time counter doesn't stutter). It also owns pausing,
  board reconciliation and each live region's
  [freshness](#freshness-how-current-the-live-view-is).

### Polling with cancel — `polling_fetchindex`

[`polling_fetchindex`](@ref) wraps the entire fetchindex + HTMX polling +
progress rendering pattern into a single call. The poller wrapper survives
across polls (only its inner progress fragment swaps), so pill toggle state
persists between polls.

```julia
polling_fetchindex(app.results, key;
    poll_url=query_url("/results/$key"),
    label="Computation ($key)",
    cancel_url=query_url("/cancel/$key"),  # optional Stop button
    poll_interval="200ms",
) do rv
    render_my_result(rv)
end
```

Three states are handled automatically:

- **Running** — renders the progress tree inside a `.treebar-poller` wrapper;
  each poll only swaps the inner fragment. The wrapper carries one
  `.treebar-badge` — a hairline strip plus a panel (pause/play control,
  progress bar and status) above the live tree, expanded by default so a
  first-load region shows progress immediately. Pass `chrome=:quiet` to
  collapse a poller beside already-visible content to the strip (hover/focus
  re-expands it); a poller diverted into HTMXObjects' live-refresh reporter
  is quiet automatically.
- **Failed** — renders the exception as an `<article>` with the error message;
  polling stops naturally because the error article has no `hx-trigger`.
- **Completed** — calls the `render_result` callback and terminalizes the stable
  wrapper as `.treebar-terminal`; no active poll transport or controls remain.

While it polls in-flight work, `polling_fetchindex` also reports the compute to
HTMXObjects' job ledger (`HTMXObjects.track_job!`), so hand-rolled pollers show
on HTMXObjects' runtime dashboard and job boards. Pass `track_job=false` to opt
out.

#### Feeding a poller from a push source

A server-sent-events stream or another socket can deliver a poller's answers
instead of its polls. The source hands each answer — the response a poll
would have received — to the page script:

```js
treebarUpdatePoller(el, html)   // apply one pushed answer
treebarUpdatePoller(el)         // heartbeat: the shown answer is still current
treebarPollerLost(el, why)      // the source failed; `why` empty = unreachable
```

`el` is the `.treebar-poller` wrapper or any element inside it (the wrapper
is never replaced while the poller is live). The answer is applied exactly as
htmx applies a poll answer, so the finished result terminalizes the poller as
usual. From the first call, Treebars suspends the poller's own polls; while
the viewer has paused it, Treebars holds the newest pushed answer and shows it
on resume. `treebarPollerLost` hands the poller back to its own polls, which
retry by themselves. Both functions return `false` once the poller has
finished, failed or left the page, so the source stops pushing to it. A page
without [`htmx_treebar_script`](@ref) has no `treebarUpdatePoller`, and its
pollers keep polling.

The source confirms each poller at least every five poll intervals (at least
5s) while it runs, with an answer or a heartbeat; a poller it leaves quiet
longer reads as [stale](#freshness-how-current-the-live-view-is).

### Live boards — `htmx_render_board`

[`htmx_render_board`](@ref) renders a keyed, changing collection of progress
trees: a "running jobs" list whose members appear, update in place, and leave.
The board is generic — the caller supplies the entries:

```julia
entries = [
    (; key=job.id, label=job.label, state=job.state,        # :queued/:running/:done/:failed
       elapsed_ms=job.elapsed_ms, node=job.progress,        # optional ProgressNode
       meta=(route=job.route, polls=job.polls),             # small label/value pairs
       href=job.url),                                       # optional link
    …
]
htmx_render_board(entries; poll_url="/jobs", poll_interval="1s",
                  empty="No running jobs.", id="jobs")
```

Each poll returns the full current list, and the client script reconciles it
by `key`: existing items keep their `.treebar-board-item` wrapper (so an
expanded tree and pill toggles survive) and swap only their content, new items
are inserted in server order, and items that drop out of the list show their
final state for `linger_ms` before leaving (a `:done`/`:failed` entry stays as
long as the server lists it). Running
items tick locally between polls; queued items render dim, like pending nodes
(`meta=(position=3,)` reads "queued · #3"). The header carries the
running/queued count and a Pause button that stops the board's polls and
freezes it.

For push instead of polling, [`ws_board`](@ref) sends the same full snapshots
over a WebSocket (the htmx `ws` extension hands each frame to the same
reconciler); other transports can call `window.treebarUpdateBoard(html)`.

### Freshness: how current the live view is

A live region shows the server's state as of its last update. When that
state is old, the region says so, with no setup beyond the page assets:

- **Stale.** No update has arrived for five poll intervals (at least 5s).
  Common causes: a backgrounded tab stopped polling, or the server is slow.
  The region reads "Updated 1m 4s ago" until the next update, and the
  poller's strip stops pulsing.
- **Connection lost.** Every update attempt has failed for 5s straight: the
  server is down, a gateway answers 502/503/504, or the socket dropped. The
  region reads "Connection lost · updated 1m 4s ago · retrying" ("Updates
  failing (HTTP 404)" for other error statuses). The live tree dims, its
  running clocks hold their last known values, the poller's strip turns the
  error color, and a quiet poller opens its panel. A single failed poll that
  the next one recovers from shows nothing.

A lost region keeps retrying (polls keep their timer, the htmx `ws`
extension reconnects after an abnormal close, and a poller whose
[push source](#feeding-a-poller-from-a-push-source) failed returns to its own
polls). It stays marked lost until an update succeeds, then clears at once.

The notice appears in the poller badge, in a live board's header, and at the
top of each WebSocket frame ([`htmx_ws_progress`](@ref) /
[`htmx_ws_render`](@ref)). Static renders carry none. A stream that ended
normally after its last update, with nothing still running, is settled and
never goes stale.

### Words in the page's language — `treebar_texts`

Every word Treebars writes on a page comes from a [`TreebarTexts`](@ref)
value: durations ("— 6s so far"), pills ("3 finished"), the poller's badge,
pause control and Stop button, the freshness notes, the phase overview and
the job board. [`treebar_texts`](@ref) builds one for `:en` (the default) or
`:de`, with any single text replaceable by keyword:

```julia
htmx_render(root; texts=treebar_texts(:de))           # "— 6 s bisher", "3 abgeschlossen"
treebar_texts(:de; stop="Anhalten")                    # one word changed
```

Every HTML renderer takes `texts=`: [`htmx_render`](@ref),
[`htmx_render_children`](@ref), [`polling_fetchindex`](@ref) (HTTP and
WebSocket), [`htmx_ws_render`](@ref), [`htmx_ws_progress`](@ref), the
producer form of [`ws_progress`](@ref), [`htmx_render_board`](@ref),
[`htmx_ws_render_board`](@ref) and [`ws_board`](@ref). Left out, it follows
the page language the HTMXObjects route being answered declares
(`__lang__ = "de"` on its mount chain, the declaration that also writes
`<html lang>`): `de` and every `de-*` tag select German, anything else
English. That needs an HTMXObjects that exposes the answer's language
(`HTMXObjects.page_lang()`); on one without it, `texts=` left out means
English.

German durations put a space before the unit and use a decimal comma
(`3,9 s`, `1 min 23 s`). The words the page script writes between updates —
the ticking duration, the badge's status word and pause label, the freshness
notes, a board item that ended — travel with the region as a
`data-treebar-texts` attribute, so [`htmx_treebar_script`](@ref) needs no
setting. English markup carries no such attribute and is unchanged.
[`render_text`](@ref) and the `:term` backend always write English: they are
read by developers, not by the app's audience.

#### Notes a package writes — `treebar_notes`

A package that writes a note into a node — DynamicObjects' "from disk:
26.9 MB" while it loads a cached value — writes it once, often on a background
task and into a node every viewer shares, so it cannot know the page's
language. It writes a [`TreebarNote`](@ref) instead of a string, and each
renderer writes the note in the language of its texts. The package declares its
words once, English required, in a [`treebar_notes`](@ref) table:

```julia
const progress_notes = treebar_notes(
    en = (from_disk = "from disk: {size}", cached = "(cached)"),
    de = (from_disk = "aus dem Zwischenspeicher ({size})", cached = "(zwischengespeichert)"))

update_progress!(node, progress_notes(:from_disk; size = ByteSize(n)))  # "aus dem Zwischenspeicher (26,9 MB)"
update_progress!(node, progress_notes(:cached))
update_progress!(node, treebar_note(:queued_position; position = 2))     # Treebars' own words: "wartet · Nr. 2"
```

A note's values are strings and integers, written as given, and
[`ByteSize`](@ref), which uses the language's decimal separator. A language
that leaves a text out falls back to English, and [`render_text`](@ref) and the
`:term` backend write the English text. An app rewords a package's texts in the
texts it renders with, checked against the package's table:

```julia
treebar_texts(:de, progress_notes => (from_disk = "von der Festplatte ({size})",))
```

An unknown language or text, a `{placeholder}` the English text does not take,
or a missing or unsupported value (a float, `true`) throws an `ArgumentError`.

## HTTP / WebSocket (`ws_progress`)

When `HTTP` is loaded, the `HTTPExt` package extension provides
[`ws_progress`](@ref): a push loop that sends rendered progress over a
WebSocket until the node finalises.

```julia
@ws ws = begin
    p = initialize_progress!(:state; description="Running")
    task = Threads.@spawn expensive_computation(p)
    ws_progress(__ws__, p; render=htmx_ws_render)
    send(__ws__, render_result(fetch(task)))
end
```

The default `render` is `repr`; load `HTMXObjects` to use
[`htmx_ws_render`](@ref) which wraps `htmx_render` in a stable-id `<div>` for
HTMX swap-by-id.

## Custom backends

Implement the progress interface for your own types. The minimum surface is:

```julia
struct MyProgress
    # your state
end

Treebars.initialize_progress!(::Val{:mybackend}; kwargs...) = ProgressNode(MyProgress(), …)
Treebars.initialize_progress!(p::MyProgress, N::Integer; kwargs...) = MyProgress(…)
Treebars.update_progress!(p::MyProgress, i::Integer) = …
Treebars.update_progress!(p::MyProgress, msg::AbstractString) = …
Treebars.finalize_progress!(p::MyProgress) = …

# Optional
Treebars.fail_progress!(p::MyProgress, exception) = …
Treebars.start_progress!(p::MyProgress) = …    # if the backend supports a pending state
```

See `ext/TermExt.jl` and `src/implementation.jl` (the `StateProgress` backend)
for full reference implementations.
