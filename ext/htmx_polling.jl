"""
    polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, texts=nothing, pause=nothing, kwargs...)

Generic fetchindex + HTMX polling pattern. Renders the running progress
inside a `.treebar-poller` wrapper containing a `.treebar-poller-inner`
element that carries the polling attributes (`hx-trigger="every Xs [!document.hidden]"
hx-target="this" hx-swap="outerHTML"` — the filter stops a hidden document
from polling for nobody; a returning tab is at most one interval stale). The wrapper also carries one
`.treebar-badge`: a hairline strip plus a panel (pause/play control, poll
label, status word, progress bar, elapsed) above the live tree. The panel
and tree render expanded by default, so a first-load region shows progress
immediately; pass `chrome=:quiet` to collapse a poller to the hairline
strip that expands on hover/focus (emitted as `data-chrome="quiet"`),
and a poller diverted into HTMXObjects' live-refresh reporter is quiet
automatically. On each poll the inner self-swaps; once the task is done,
the response replaces the inner with `.treebar-terminal-content`, which
naturally stops the loop. The client then renames the stable wrapper to
`.treebar-terminal`, removes its polling UX state and badge, and leaves
the rendered result (plus optional frozen progress record) as an
unambiguous terminal fragment. While polling, the wrapper itself is
untouched, so UX state on it (`data-show-finished` / `-failed` /
`-pending` / `-skipped` / `-reused`, set by pill clicks, and `data-chrome`)
persists across polls.

The badge also says how current the tree is: after five intervals (at least
5s) without an update it reads "Updated 1m 4s ago", and once every poll has
failed for 5s straight (server down, gateway 5xx) it reads "Connection lost ·
updated … · retrying", dims the tree and holds its clocks. Polling never
stops on failure, and the first successful poll clears the notice.

A push source (a server-sent-events stream, a custom socket) can feed the
poller instead of its polls: `window.treebarUpdatePoller(el, html)` applies
one pushed answer (the response a poll would have received) exactly as a poll
answer, and `window.treebarUpdatePoller(el)` confirms the shown answer is still
current. The answer is first offered to `htmx:beforeSwap` on the polling
element, so a page's swap gate or rewrite covers it as it covers a poll answer:
the detail has a poll answer's fields, without `xhr` since no request ran, plus
`treebarPushed: true`. A listener can skip the answer (`shouldSwap = false` or
`preventDefault()`), which still confirms the poller live, or change
`serverResponse`, `target`, `selectOverride`, `ignoreTitle` and the style in
`swapOverride` (its modifiers have no effect).
While pushed, the poller's own polls are suspended, the answer of a
poll already in flight is dropped (that poll is left to finish, because htmx
reports an aborted request as an error), a paused poller holds the newest
pushed answer until resume, and the badge stays live as long
as the source confirms it at least every five intervals (at least 5s).
`window.treebarPollerLost(el, why)` hands the poller back to its polls; if
those fail too, it reads "Connection lost" (`why` empty) or "Updates failing
(why)". `el` is the `.treebar-poller` wrapper or any element in it; both
return `false` once the poller has finished, failed or left the page.

The inner's `hx-select` is top-level-only: each branch excludes matches
nested inside another match, so a poll response containing a nested poller
(an explicit `polling_fetchindex` under an `:auto` root, or a finished nested
fragment inside a still-running outer poll) swaps exactly the outermost
region instead of duplicating the nested one into a live sibling.

The host page must include [`htmx_treebar_styles`](@ref) and
[`htmx_treebar_script`](@ref) once, normally through `htmx(...;
extra_head=(htmx_treebar_styles(), htmx_treebar_script()))`. The fragment can
still poll without those page assets, but client-owned behavior is then absent:
the badge renders statically above the fully visible tree (no collapse, no
live status mirror), the duration ticker and pause handler are not installed,
and a completed inner swap leaves the persistent wrapper identified as
`.treebar-poller` instead of terminalizing it in place. The badge's pause
control is inert once its poller stops polling, so even an un-terminalized
badge cannot flip its glyph on a finished poller.

Poll requests deliberately inherit ancestor `hx-vals`/form values (no
`hx-params` isolation): HTMXObjects heals a drifted poll by re-executing with
the poll request's current arguments, which requires those arguments to reach
the server.

Failure path (`keep_progress=true`, default): the compute error — re-thrown by
`fetchindex` before this callback runs (compute-at-most-once) — is caught in
`polling_fetchindex`, recorded + rendered through HTMXObjects' `safely` (disk
log + `@error` + the app's `__on_error__`/`__error__` hooks + the opaque "caught
an error" article), and returned alongside the kept tree inside the polling
inner, so polling stops and the tree survives. With `keep_progress=false` the
error propagates to HTMXObjects' route-boundary catch (a 200 HTML error article
that replaces the polling inner, discarding the tree). Either way polling stops
naturally — no custom OOB / HX-Retarget gymnastics.

- `render_result(rv)`: function that renders the final result (supports `do` syntax)
- `ip`: IndexableProperty (e.g. `app.pathfinder`)
- `keys...`: cache key(s) (variadic — supports multi-index like `f1, f2`)
- `poll_context`: HTMX route struct (`__self__`). When provided, derives `poll_url`
  via `query_url(poll_context; force=false)` and `force` from `poll_context.force`.
  Overrides explicit `poll_url` and `force` kwargs.
- `poll_url`: URL to poll while running (use `query_url`). Ignored when `poll_context` is set.
- `label`: display label (e.g. "Pathfinder (my-model)"). When it equals the
  status root's description, the badge-label and interim-header copies are
  omitted — the root header already carries the string — and the badge
  elapsed is omitted whenever the root row renders its own duration span.
- `force`: force re-computation (default `false`). Ignored when `poll_context` is set.
- `poll_interval`: HTMX polling interval (default "200ms")
- `cancel_url`: optional URL for a "Stop" button shown while running (default `""` = no button).
  Treebars only renders the button (pointing at the caller-provided `cancel_url`).
  NOTE: DynamicObjects' `cancel!` was removed with the compute-at-most-once
  refactor, so an in-flight compute now always runs to completion — the button
  is inert unless the caller's `cancel_url` route does something itself.
- `keep_progress`: keep the finished/failed tree for post-hoc inspection (default
  `true`). On success the frozen tree is appended below the result in a collapsed
  `<details>`. On failure the tree (with the failed node) is shown in an open
  `<details>` beside the recorded error. Set `false` for the old result-only /
  propagate-on-failure behavior; ignored on the `sync` path.
- `sync`: resolve now — wait for the compute and return the final fragment,
  with no poller (default `false`). The result is still wrapped in the
  `.treebar-terminal` `<div>`s: `sync` skips polling, not the wrapper. So it is
  not a way to hand a caller the raw value: a `render_result` that returns an
  `HTTP.Response` or an HTMXObjects `MIMEResponse` / `JSONResponse` has it
  written into the HTML, and a warning says so once. To answer with the raw
  value, resolve the IP yourself (`fetchindex` / `fetch`) and return it from
  the route.
- `error_obj` / `req`: route context threaded to `safely` on the failure path
  (its `obj` for `__on_error__`/`__error__`, its `req` for log metadata).
  Auto-derived from `poll_context`; pass explicitly otherwise. Both optional.
- `parent`: `Treebars.ProgressNode`, `nothing`, or `:auto` (default). When
  a node, the IP compute's live substatus tree hangs under this caller-owned
  node (mirroring DO's `fetchindex!(parent, ip, …)` attachment), so an outer
  `dispatch` or `@progress` job tree shows the embed's real compute as
  children instead of the poller running detached on the IP's own
  `__status__` root. `:auto` resolves the dispatch caller automatically —
  the request's dispatch node first (`HTMXObjects.dispatch_parent(req)`,
  when `req` is passed or derived from `poll_context`), else the ambient
  node `dispatch` bound (`Treebars.current_dispatch_parent`), else detached.
  An explicit `parent=` always wins; pass `nothing` to force detached (the
  historical default behavior). Ignored when the compute was already cached
  (no live substatus to attach); the subtree still detaches from the caller
  on transient finalize, exactly as DO's own `fetchindex!` attachment does.
- `chrome`: `:auto` (default) or `:quiet`. `:auto` renders the badge panel
  and live tree expanded — a first-load region shows progress immediately.
  `:quiet` emits `data-chrome="quiet"` on the wrapper, collapsing the
  poller to the hairline strip (hover/focus expands it); use it for a
  poller beside already-visible content. A poller diverted into
  HTMXObjects' live-refresh reporter is quiet by stylesheet rule either
  way. Anything else throws `ArgumentError`.
- `track_job`: when a poller is emitted for in-flight work, report the compute
  to HTMXObjects' job ledger through `HTMXObjects.track_job!` (with `label`,
  the progress tree and `req`), so hand-rolled pollers appear on the runtime
  dashboard and job boards (default `true`). Skipped on HTMXObjects generations
  without that API; a tracking failure never affects the poller. HTMXObjects'
  own operation transport passes `false` — it records its jobs itself.
- `texts`: the [`TreebarTexts`](@ref) every word of the poller is written in —
  badge status, pause control, Stop button, interim header, durations, pills
  and the kept tree. Left at `nothing` it follows the page language of the
  HTMXObjects answer (`__lang__`, see [`htmx_render`](@ref)); the wrapper
  carries the words the page script writes between polls.
- `pause`: whether the badge shows its ❚❚ pause/play control. Left at
  `nothing` it follows the page, like `texts`: under an HTMXObjects route whose
  mount chain declares `__progress_pause__ = false` (read through
  `HTMXObjects.page_progress_pause()`, on an HTMXObjects that provides it) the
  poller has no pause control, which is what a visitor-facing app wants, since
  pausing only freezes the display while the work runs on. Otherwise the
  control shows. `true` / `false` decide for this poller; anything else throws
  `ArgumentError`. The status word, bar, elapsed time, freshness note and any
  Stop button stay either way.
- `kwargs...`: passed through to `fetchindex`
"""
# Resolve the `parent=:auto` default: the request's dispatch node first (the
# explicitly-passed `req` is the most local statement of dispatch context,
# and it survives the spawned-task boundary that task-local storage does not
# cross on Julia 1.10), else the ambient node `dispatch` bound, else
# detached. The `applicable` guard keeps this inert on HTMXObjects
# generations predating the public `dispatch_parent` accessor (and on
# non-request `req` values): no resolve, no throw — the poller just stays
# detached, exactly as before. The `parent isa ProgressNode` filter at the
# attach site stays the single type gate for whatever this returns.
function _polling_default_parent(req)
    if req !== nothing && isdefined(HTMXObjects, :dispatch_parent) &&
            applicable(HTMXObjects.dispatch_parent, req)
        node = HTMXObjects.dispatch_parent(req)
        node !== nothing && return node
    end
    current_dispatch_parent()
end
function polling_fetchindex(render_result, ip, keys...; poll_context=nothing, poll_url=nothing, label=nothing, force=false, poll_interval="200ms", cancel_url="", sync=false, keep_progress=true, error_obj=nothing, req=nothing, parent=:auto, chrome=:auto, track_job=true, phase_overview::Union{Bool,Symbol}=false, texts=nothing, pause=nothing, kwargs...)
    chrome in (:auto, :quiet) || throw(ArgumentError("polling_fetchindex: chrome must be :auto or :quiet, got $(repr(chrome))"))
    t = _texts(texts)
    show_pause = _pause(pause)
    if !isnothing(poll_context)
        poll_url = HTMXObjects.query_url(poll_context; force=false)
        force = poll_context.force
        # The route struct doubles as the failure-path error context (its
        # __on_error__/__error__ hooks + __req__ for the log), unless the caller
        # passed error_obj/req explicitly.
        isnothing(error_obj) && (error_obj = poll_context)
        isnothing(req) && hasproperty(poll_context, :__req__) && (req = poll_context.__req__)
    end
    # Default-parent resolution (snag make-htmxobjects-7960c091): an absent
    # `parent` follows the dispatch caller; an explicit node — or an explicit
    # `nothing` to force detached — always wins. Resolved here, after the
    # poll_context block, so a derived `req` feeds the request leg.
    parent === :auto && (parent = _polling_default_parent(req))
    # keep_progress: a failed compute is re-thrown by fetchindex BEFORE the
    # callback runs (compute-at-most-once), so wrap the call to catch it, pull
    # the (failed) tree via getstatus, and render the recorded error + tree
    # rather than let the throw reach HTMXObjects' route-boundary catch (which
    # would discard the tree). keep_progress=false (or sync) re-throws as before.
    try
        fetchindex(ip, keys...; force, kwargs...) do rv, status
            # Parent passthrough (snag hang-pdf-embed-c-d79aad34): hang the
            # live substatus under the caller's node so the embed's compute
            # tree renders in the caller's tree. `add_child!` is idempotent on
            # the ThreadsafeSet; `nothing` status = cached/no-live-substatus
            # (a no-op). The subtree still detaches on transient finalize, so
            # this gives the caller the LIVE view, not a post-hoc history.
            (parent isa ProgressNode && !isnothing(status)) && add_child!(parent, status)
            # About to emit a poller for in-flight work: report it to
            # HTMXObjects' job ledger (runtime dashboard / job boards).
            track_job && !sync && _is_unresolved_handle(rv) &&
                _track_job(rv, status, ip; label, req)
            _polling_resolve(rv, status; label, poll_url, poll_interval, cancel_url, render_result, sync, keep_progress,
                             ip_ctx=_ip_ctx(ip, keys, kwargs), chrome=chrome, phase_overview, texts=t, pause=show_pause)
        end
    catch err
        (keep_progress && !sync) || rethrow()
        _polling_wrap(_polling_inner_done(_caught_error_ex(err, error_obj, req),
                                          _kept_progress(HTMXObjects.getstatus(ip, keys...; kwargs...), t; open=true, phase_overview));
                      terminal=true)
    end
end

# DynamicObjects' in-flight handles implement both `Base.isready` and
# `Base.fetch`. Detect that protocol instead of resolving a concrete `Pending`
# type while this extension module is being defined: Treebars should still load
# when HTMXObjects changes where (or whether) it exposes DynamicObjects' handle
# type. `Task` is the previous fetch contract and needs its own readiness test.
#
# `_is_handle` is the readiness-AGNOSTIC companion: does `rv` present the handle
# protocol AT ALL? A resolved VALUE presents neither `isready` nor `fetch`; a DO
# `Pending` (and `Task`/`Future`/`Channel`) presents both. `_is_unresolved_handle`
# is then just "a handle that is not yet ready". The done path (below) needs the
# agnostic form: a handle reaching it is by definition READY (every not-ready one
# took the poll/fetch branch), and `_is_unresolved_handle` cannot see it.
_is_handle(rv::Task) = true
_is_handle(rv) = applicable(Base.isready, rv) && applicable(Base.fetch, rv)
_is_unresolved_handle(rv::Task) = !istaskdone(rv)
_is_unresolved_handle(rv) = _is_handle(rv) && !Base.isready(rv)

# A READY handle reaching the done path must be RESOLVED, never rendered raw.
# DynamicObjects chooses `Pending` from a cache snapshot, then invokes the
# fetchindex callback. The compute may legally finish between those two events,
# so the callback can receive a handle whose value is already ready. `_is_handle`
# proves that the object presents the complete `isready`/`fetch` protocol; fetch
# it silently and let only the VALUE reach `render_result`. A partial or otherwise
# incompatible object does not satisfy that protocol and is not normalized here.

# Keep the old Task contract working while DynamicObjects consumers migrate.
_polling_resolve(rv::Task, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true) =
    istaskfailed(rv) ? throw(rv.result) :
    sync ? _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause) :
        _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome, phase_overview, texts, pause)

# Report a hand-rolled poller's in-flight compute to HTMXObjects' job ledger
# (`HTMXObjects.track_job!`), so it shows on the runtime dashboard and job
# boards like the operations HTMXObjects starts itself. Guarded twice over: an
# HTMXObjects generation without the ledger API is skipped, and a ledger
# failure never reaches the poller. The label never carries the cache keys —
# they are request data — only the caller's label, the tree's own
# description, or the property name.
function _track_job(handle, status, ip; label=nothing, req=nothing)
    isdefined(HTMXObjects, :track_job!) || return nothing
    try
        HTMXObjects.track_job!(handle; label=_track_job_label(label, status, ip),
                               progress=status, req)
    catch err
        @debug "Treebars: job tracking failed; polling continues" exception=(err, catch_backtrace())
    end
    nothing
end

function _track_job_label(label, status, ip)
    isnothing(label) || return string(label)
    if status isa ProgressNode{<:StateProgress}
        description = strip(status.impl.description)
        isempty(description) || return String(description)
    end
    try
        string(HTMXObjects.DynamicObjects.name(ip))
    catch
        "Job"
    end
end

# Human-readable "which IP, which key" for the unresolved-handle error below.
# Best-effort: an IP that does not expose `name`/`o` still yields a usable string.
function _ip_ctx(ip, keys, kwargs)
    ipname = try
        string(HTMXObjects.DynamicObjects.name(ip))
    catch
        string(typeof(ip))
    end
    kwstr = isempty(kwargs) ? "" : "; " * join(("$k=$(repr(v))" for (k, v) in pairs(kwargs)), ", ")
    "$ipname($(join((repr(k) for k in keys), ", "))$kwstr)"
end

# Done — already-cached or just-completed. A first-call-done response is born
# terminal. On running-then-done the response replaces the polling inner and
# the client terminalizes the stable wrapper in place. With keep_progress
# (default, but not on the sync loopback), the frozen tree is appended below
# the result in a collapsed <details>.
function _polling_resolve(rv, status; sync=false, keep_progress=true, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx="", chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true)
    if _is_unresolved_handle(rv)
        return sync ?
            _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause) :
            _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome, phase_overview, texts, pause)
    end
    # A READY handle must never reach render_result raw — resolve it here. This is
    # the guard that `e6f140f` dropped (it deleted `_assert_resolved` and traded
    # Pending-type dispatch for the not-ready duck-test above, which cannot see a
    # ready handle). A compatible ready handle is a legal completion race, so it
    # is normalized silently rather than diagnosed as package skew.
    if _is_handle(rv)
        return _polling_resolve(fetch(rv), status; sync, keep_progress, label, poll_url, poll_interval, cancel_url, render_result, ip_ctx, chrome, phase_overview, texts, pause)
    end
    body = render_result(rv)
    _warn_wrapped_response(body)
    (keep_progress && !sync) ?
        _polling_wrap(_polling_inner_done(body, _kept_progress(status, texts; open=false, phase_overview)); terminal=true) :
        _polling_wrap(_polling_inner_done(body); terminal=true)
end

# A callback that returns a finished answer (a response, not content) has it
# serialized into the poller's HTML, so the caller gets markup where it expected
# JSON or markdown and fails downstream with a serialization error.
# The caller should return the raw
# value from the route instead — so this only says so, once.
_warn_wrapped_response(@nospecialize(body)) = nothing
_warn_wrapped_response(body::Union{HTTP.Response,HTMXObjects.MIMEResponse}) = _warn_wrapped(body)
# `JSONResponse` exists only on newer HTMXObjects.
@static if isdefined(HTMXObjects, :JSONResponse)
    _warn_wrapped_response(body::HTMXObjects.JSONResponse) = _warn_wrapped(body)
end
_warn_wrapped(body) = @warn "polling_fetchindex: render_result returned a $(nameof(typeof(body))), which is written into the poller's HTML instead of being returned. To answer with it, resolve the IP yourself (fetchindex / fetch) and return it from the route." maxlog=1

# Frozen progress tree kept in the final (non-polling) response so a finished or
# failed run can be inspected after polling stops. scoped=true → the
# finished/failed/pending pills act as a static inspector; wrapped in a
# <details> (collapsed on success — stays out of the way; open on failure —
# failed node visible). `treebar-frozen` makes the client ticker skip it, so a
# terminal tree still holding a "running" node is static, not counting up.
# Empty string when there is no status node.
function _kept_progress(status, t::TreebarTexts; open::Bool=false, phase_overview::Union{Bool,Symbol}=false)
    isnothing(status) && return ""
    body = (h.summary(t.progress), _htmx_render(status, t; scoped=true, phase_overview))
    open ? h.details(class="treebar-frozen", open=true)(body...) : h.details(class="treebar-frozen")(body...)
end

# Record + render a caught compute error THROUGH HTMXObjects' exported `safely`,
# so a keep_progress failure gets the SAME treatment as a route-boundary throw —
# disk log (ERROR_DIR/<uid>.log) + @error + the app's __on_error__/__error__
# hooks + the opaque "caught an error" article — WITHOUT discarding the tree. On
# the compute-at-most-once (Pending) model the failure is re-thrown by fetchindex
# before our callback, so polling_fetchindex catches it and hands the exception
# here; we re-raise inside safely to reuse its record+render. error_obj/req carry
# route context (both may be nothing → default article, no hooks/req-meta). The
# returned article is aria-invalid and sits INSIDE the terminal content — the
# poller's top-level-only hx-select excludes nested matches (see
# `_polling_inner_running`) so htmx does not double-insert it.
_caught_error_ex(err, error_obj, req) =
    HTMXObjects.safely(; obj=error_obj, req=req) do
        throw(err)
    end

# Poller running-face dedup (snag expanded-first-l-360630fb). The badge and
# the tree are co-visible in the expanded default chrome, so a string the
# tree already renders must not be restated above it: when the poller `label`
# equals the status root's description, the badge label, the interim
# "<label> — running..." header, and the root header render one string three
# times — and the badge elapsed always restates the root's duration span.
# The running face omits the redundant copies server-side, so the dedup
# holds with or without the page assets; the tree keeps the single
# surviving copy of each.

# The description the poller tree renders for its own root, or `nothing`
# when the root renders no description row (a status that is nothing,
# non-state, or undisplayed, or a root with an empty description). Mirrors
# `htmx_render`'s header rules — keep in lockstep.
function _status_root_description(status)
    status isa ProgressNode || return nothing
    is_displayed(status) || return nothing
    sp = status.impl
    sp isa StateProgress || return nothing
    return lock(sp.lock) do
        isempty(sp.description) ? nothing : sp.description
    end
end

# True when `htmx_render(status)` emits a `.treebar-duration` span for the
# root itself: a counter, a non-annotation message node, or a described
# container. Mirrors `htmx_render`'s header rules above — keep in lockstep.
function _root_renders_duration(status)
    status isa ProgressNode || return false
    is_displayed(status) || return false
    sp = status.impl
    sp isa StateProgress || return false
    return lock(sp.lock) do
        !isnothing(sp.N) && return true
        !_isempty_text(sp.message) && return !get(status.meta, :annotation, false)
        !isempty(sp.description)
    end
end

# True when the poller `label` restates the status root's description: the
# badge-label and interim-header copies are redundant with the root header.
_label_restates_root(label, status) =
    !isnothing(label) && _status_root_description(status) == string(label)

function _polling_running(status; label, poll_url, poll_interval, cancel_url, chrome=:auto, phase_overview::Union{Bool,Symbol}=false, texts::TreebarTexts=_EN_TEXTS, pause::Bool=true)
    t = texts
    stop_btn = isempty(cancel_url) ? "" : h.a(t.stop; role="button", class="outline secondary treebar-stop",
        hx_get=cancel_url, hx_target="closest div", hx_swap="outerHTML")
    inner_body = if isnothing(label)
        _polling_status_tree(status, t; article=true, scoped=false, phase_overview)
    elseif _label_restates_root(label, status)
        # The badge and the root header already carry this string — an
        # interim "<label> — running..." header would restate it a third
        # time. Only the redundant header line goes: the article wrapper
        # stays, and a configured Stop control stays inside it.
        h.article(stop_btn, _polling_status_tree(status, t; scoped=false, phase_overview))
    else
        h.article(h.header(_fill_text(t.running_header; label), stop_btn), _polling_status_tree(status, t; scoped=false, phase_overview))
    end
    _polling_wrap(_polling_inner_running(poll_url, poll_interval, inner_body);
                  pausable=true, badge=_poll_badge(label, status, t; pause), chrome=chrome, texts=t)
end

# The live tree inside a poller. A missing status keeps `htmx_render`'s own
# answer (its error pointing at the uninitialized `__status__`).
_polling_status_tree(status::ProgressNode, t::TreebarTexts; kwargs...) = _htmx_render(status, t; kwargs...)
_polling_status_tree(status, t::TreebarTexts; kwargs...) = htmx_render(status; kwargs...)

# Persistent wrapper. UX state baked in via data-show-*; descendant CSS rules
# pick it up. The wrapper is rendered fresh on every response shape but in
# practice only the initial response (and any first-call-done) actually puts
# this wrapper into the DOM — subsequent polls only swap the inner, leaving
# the original wrapper element (and its possibly-toggled data-show-* attrs)
# untouched.
# Polling badge, one per live `.treebar-poller` wrapper: hairline strip plus
# panel (pause/play button, label, status word, determinate bar, elapsed)
# above the live tree. Expanded by default; `chrome=:quiet` collapses it to
# the strip (hover/focus re-expands). The badge lives on the never-swapped
# wrapper, so the pause control keeps focus and state across polls;
# `syncBadge` (htmx_treebar_script) mirrors the fresh inner into it after
# every swap and tick. Without the page assets there is no collapse and no
# mirror: the badge renders statically above the fully visible tree, and the
# pause button still toggles `data-paused` (but nothing cancels the poll
# requests — the documented asset-less degradation).
#
# The pause onclick toggles `data-paused` on the closest `.treebar-poller` —
# the persistent wrapper, so the paused state survives polls exactly like the
# data-show-* pills. The htmx:beforeRequest listener reads that attr to cancel
# this poller's poll requests, and the duration ticker freezes on it. Keyed on
# closest('.treebar-poller') so nested pollers each pause independently.
# The onclick is INERT once its poller stops polling: it no-ops unless the
# wrapper still holds a direct-child polling inner (`.treebar-poller-inner`
# with `hx-trigger`). A terminal swap replaces that inner with
# `.treebar-terminal-content` (or a bare error article), so a badge left in the
# DOM — a page without `htmx_treebar_script` never runs the afterSwap
# finalizer that removes it — stops responding instead of flipping its glyph
# on a finished poller. A paused poller keeps its inner (and its `hx-trigger`),
# so resume still passes the guard. (Same guard as sibling snag
# treebars-pause-l-19b2227a: this badge subsumes that fix's onclick hunk.)
_pause_button(t::TreebarTexts) = h.button(class="treebar-pause", type="button",
    aria_label=t.pause,
    title=t.pause_title,
    onclick="var p=this.closest('.treebar-poller'); if(!p) return; if(!p.querySelector(':scope > .treebar-poller-inner[hx-trigger]')) return; var v=p.dataset.paused==='1'?'0':'1'; p.dataset.paused=v; var play=v==='1'; this.textContent=play?'▶':'❚❚'; this.setAttribute('aria-label',play?$(_js_string(t.resume)):$(_js_string(t.pause))); if(window.__tbSyncBadge) window.__tbSyncBadge(p);")("❚❚")

# First-paint badge content. The status word and elapsed are server-rendered
# once; the client mirror owns them afterwards. The bar starts indeterminate
# (no value/max) and the mirror sets the determinate fraction from the first
# `.treebar-progress` in the inner — the bar's shape is a client derivation,
# not a second server render rule. The label never changes across polls, so
# the server owns it outright and the mirror never touches it.
_badge_elapsed(::Nothing, t::TreebarTexts) = t.badge_starting
_badge_elapsed(node::ProgressNode, t::TreebarTexts) =
    node.impl isa StateProgress ? _initial_duration_text(_render_state(node), t) : ""

function _poll_badge(label, status, t::TreebarTexts; pause::Bool=true)
    h.span(class="treebar-badge")(
        h.span(class="treebar-badge-strip", aria_hidden="true")(),
        h.span(class="treebar-badge-panel")(
            # `pause=false`: no control at all (a visitor-facing page; see
            # `_pause`). The mirror tolerates its absence.
            pause ? _pause_button(t) : "",
            # No badge label when there is none to show, or when it would
            # restate the root header one line below (dedup, see above).
            (isnothing(label) || _label_restates_root(label, status)) ? "" :
                h.span(class="treebar-badge-label")(string(label)),
            h.span(class="treebar-badge-status")(t.polling),
            _freshness_span(),
            h.progress(class="treebar-badge-bar")(),
            # No badge elapsed when the root row renders its own duration
            # span (dedup, see above). The client mirror tolerates the
            # absent span — it re-checks `querySelector` every tick.
            _root_renders_duration(status) ? "" :
                h.span(class="treebar-badge-elapsed")(_badge_elapsed(status, t)),
        ),
    )
end

# `chrome` selects the live wrapper's badge presentation: `:auto` (default)
# emits no `data-chrome` attr, so the stylesheet's expanded default applies
# (panel + tree visible — a first-load region shows progress immediately);
# `:quiet` emits `data-chrome="quiet"`, collapsing to the hairline strip
# that expands on hover/focus. A poller diverted into HTMXObjects'
# live-refresh reporter (`.htmxo-live-reporter`) is quiet by stylesheet
# rule regardless of the attr — settled content is already on screen, so
# the poller is background progress. Terminal wrappers carry no badge and
# take no attr. Validated at the public `polling_fetchindex` boundary.
_polling_wrap(inner; pausable=false, terminal=false, badge="", chrome=:auto, texts::TreebarTexts=_EN_TEXTS) =
    terminal ?
        h.div(class="treebar-terminal")(inner) :
        h.div(; class="treebar-poller",
            data_chrome=(chrome === :quiet ? "quiet" : nothing),
            data_paused="0",
            _PILL_DEFAULTS...,
            data_treebar_texts=_client_texts_attr(texts))(pausable ? badge : "", inner)

# The polling element. Self-swaps via outerHTML on each `every Xs` trigger.
# `hx-select` strips the wrapper out of the response on each poll (the server
# always emits wrapper > content — initial calls need the wrapper, polls don't —
# and selecting just the running inner or terminal content keeps the live
# wrapper untouched until the afterSwap finalizer changes its state). The last
# branch matches
# HTMXObjects' bare error article (`article[aria-invalid="true"]`) so a
# `keep_progress=false` propagated failure — a 200 carrying just that article —
# still lands in the wrapper, replaces this polling element (no `hx-trigger` →
# polling stops), and shows.
#
# `hx-select` is TOP-LEVEL-ONLY: every branch excludes matches nested inside
# another match. htmx inserts EVERY querySelectorAll match, so without the
# exclusions a response whose selected region CONTAINS a nested poller (an
# explicit `polling_fetchindex` under an `:auto` root, or a finished nested
# poller's terminal fragment inside a still-running outer poll) matches twice
# and the nested region is duplicated into a live sibling on every outer poll
# — linear DOM growth, each duplicate polling. The six `:not()` clauses leave
# exactly the outermost region selected; nested content rides along inside it.
# (The article branch's second clause is sibling snag treebars-pause-l-19b2227a's
# case — a keep_progress failure response whose terminal content contains the
# opaque `safely` article — folded into the same rule; this selector subsumes
# that fix's hx-select hunk.)
#
# Deliberately NO `hx-params` isolation here: poll requests inherit ancestor
# `hx-vals`/form values, and that inheritance is load-bearing. HTMXObjects
# heals a drifted/unknown-token poll by re-executing with the CURRENT request
# args (current-args-wins), which only works because the current args reach
# the server. Stripping them client-side would starve that heal path.
# The trigger filter `[!document.hidden]` stops a backgrounded document (a
# hidden tab or minimized window) from issuing poll requests for nobody and
# resumes on visibility — a returning tab is at most one interval stale. The
# `every` timer keeps rescheduling while filtered, so resume needs no
# re-arming (same shape as the KB's own production poll guard). It lives on
# the trigger (not in the beforeRequest pause hook) so it also covers host
# pages that omit `htmx_treebar_script`, and the value still starts with
# `every` (consumers key running-poller detection on that prefix).
_polling_inner_running(poll_url, interval, body) = h.div(class="treebar-poller-inner",
        hx_get=string(poll_url),
        hx_trigger="every $interval [!document.hidden]",
        hx_target="this",
        hx_swap="outerHTML",
        hx_select=".treebar-poller-inner:not(.treebar-poller-inner .treebar-poller-inner):not(.treebar-terminal-content .treebar-poller-inner), .treebar-terminal-content:not(.treebar-poller-inner .treebar-terminal-content):not(.treebar-terminal-content .treebar-terminal-content), article[aria-invalid='true']:not(.treebar-poller-inner article):not(.treebar-terminal-content article)")(body)

_polling_inner_done(body...) = h.div(class="treebar-terminal-content")(body...)

# Convenience: when called with an IndexableProperty (no render_result), default to identity.
polling_fetchindex(ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(identity, ip, keys...; kwargs...)

"""
    polling_fetchindex(ws::WebSocket, render_result, ip, keys...; id="treebar-progress", interval=0.1, force=false, kwargs...)

WebSocket sibling of [`polling_fetchindex`](@ref). Same `fetchindex(ip, keys...) do rv, status`
dispatch — but instead of returning a polling HTMX fragment, streams progress
over `ws` via [`ws_progress`](@ref) and pushes the final rendered result as
one last frame on completion.

Producer task is NOT cancelled on client disconnect — `ws_progress` exits
its send loop on WS error and leaves the compute alone; the in-flight compute
runs to completion and its value lands in the IP cache, so the next visitor
reuses it.

Use inside an `@ws` route body, passing `__ws__` as the first argument:

    @ws fit(; model, method, ...) = polling_fetchindex(__ws__, sc.fit, model, method; force, ...) do rv
        render_fit(rv)
    end

Both progress frames and the final frame are wrapped in `<div id=\$id>…</div>`
so the htmx ws-extension swaps by element id on the client.

- `ws`: the WebSocket handle (from `__ws__`)
- `render_result(rv)`: function rendering the final result Node (supports `do` syntax)
- `ip`: IndexableProperty
- `keys...`: cache key(s)
- `id`: stable wrapper element id for ws-extension swap-by-id (default `"treebar-progress"`)
- `interval`: progress push interval in seconds (default `0.1`)
- `force`: force re-computation (default `false`)
- `texts`: the language of the frames (see [`htmx_render`](@ref)), resolved
  when the route calls this
- `kwargs...`: passed through to `fetchindex`
"""
function polling_fetchindex(ws::WebSocket, render_result, ip, keys...;
        id="treebar-progress", interval=0.1, force=false, phase_overview::Union{Bool,Symbol}=false, texts=nothing, kwargs...)
    # Resolved in the route's task; `ws_progress` renders from its own loop.
    t = _texts(texts)
    progress_render(node) = htmx_ws_render(node; id, phase_overview, texts=t)
    final_html(content)   = node_to_html(h.div(; id)(content))
    fetchindex(ip, keys...; force, kwargs...) do rv, status
        if rv isa Task
            ws_progress(ws, status; render=progress_render, interval)
            istaskfailed(rv) ||
                try; send(ws, final_html(render_result(fetch(rv)))); catch; end
        elseif _is_unresolved_handle(rv)
            ws_progress(ws, status; render=progress_render, interval)
            # Block for the finished value and push the final frame. A failed
            # compute makes `fetch` re-throw (caught here → no final frame sent).
            try; send(ws, final_html(render_result(fetch(rv)))); catch; end
        else
            # A resolved VALUE, or a compatible READY handle from the legal
            # completion race described above. Resolve the handle BEFORE the
            # swallow-catch so its serialization can never reach the client raw.
            val = rv
            if _is_handle(rv)
                val = fetch(rv)
            end
            try; send(ws, final_html(render_result(val))); catch; end
        end
    end
end

# Convenience: WS form with no render_result defaults to identity.
polling_fetchindex(ws::WebSocket, ip::HTMXObjects.DynamicObjects.IndexableProperty, keys...; kwargs...) =
    polling_fetchindex(ws, identity, ip, keys...; kwargs...)
