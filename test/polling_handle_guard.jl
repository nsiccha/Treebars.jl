# Integration check for protocol-based in-flight handle support in
# HTMXObjectsExt (`_polling_resolve` / `_is_unresolved_handle`) — snags
# polling-fetchind-dd65fe41 and htmxobjects-ext-ac713279.
#
# NOT part of `Pkg.test("Treebars")`: it needs a cross-package environment
# (DynamicObjects + HTMXObjects + HTTP) that Treebars does not carry as a test
# dep, and it must LOAD the extension — `Base.get_extension` resolution is not
# exercised by a plain `Pkg.precompile()`. Run it by hand against a env that
# pairs Treebars with a DO generation that returns `Pending`:
#
#   julia --project=<crosspkg-env> test/polling_handle_guard.jl
#
# Verified 2026-07-20 against DynamicObjects cff88f9 (pre-inference) +
# HTMXObjects 8dfa703 — the pins Bruno's app resolves by `path`.
#
# This test covers both handle generations without requiring Treebars to resolve
# DynamicObjects' concrete `Pending` type while the extension is loading.

using Treebars, HTMXObjects, HTTP
using DynamicObjects: ThreadsafeDict
# `Pending` is exported on older DO generations; on the current
# compute-at-most-once model the handle is a `Task` (no direct construction).
# The guard's Pending-construction tests run only on generations that export it.
const _OLD_PENDING = isdefined(DynamicObjects, :Pending) && DynamicObjects.Pending !== Task
if _OLD_PENDING
    const Pending = DynamicObjects.Pending
end
using Logging, Test

struct ProtocolPending end
Base.isready(::ProtocolPending) = false
Base.fetch(::ProtocolPending) = :resolved_value

ext = Base.get_extension(Treebars, :HTMXObjectsExt)
ext === nothing && error("FAIL: HTMXObjectsExt did NOT load (Base.get_extension returned nothing)")
println("OK  extension loaded: ", ext)

isdefined(ext, :_is_unresolved_handle) || error("FAIL: _is_unresolved_handle not defined in the loaded extension")
println("OK  protocol handle detector present in the LOADED image")

nfail = 0
function check(name, f)
    try
        f(); println("OK  ", name)
    catch e
        global nfail += 1
        println("FAIL ", name, " :: ", sprint(showerror, e))
    end
end

# --- 1. An UNRESOLVED Pending (the exact shape Bruno saw) stays on the poll path ---
if _OLD_PENDING
    c = ThreadsafeDict()
    key = ((("warmup",)), (; n_chains=4, n_draws=1000, seed=1, init_positions=nothing,
                              threads_per_chain=1, checkpoint=false))
    pending = Pending(c, key, nothing)
    check("unresolved Pending reports isready=false", () -> Base.isready(pending) && error("was ready"))

    check("unresolved Pending renders polling HTML without calling render_result", () -> begin
        status = Treebars.initialize_progress!(:state; description="probe")
        rendered = Ref(false)
        node = ext._polling_resolve(pending, status;
            sync=false, keep_progress=true, label="probe", poll_url="/poll",
            poll_interval="200ms", cancel_url="", ip_ctx="ctx",
            render_result = _ -> (rendered[] = true; "done"))
        rendered[] && error("render_result received the unresolved handle")
        occursin("hx-trigger", ext.node_to_html(node)) || error("polling response has no hx-trigger")
    end)
else
    println("SKIP  Pending-construction tests — current DO (compute-at-most-once) does not export a constructible Pending")
end

# --- 2. A Pending that completes at the callback boundary is silently resolved ---
# This is the crux of snag sync-polling-cal-c9717522: `e6f140f` traded the
# Pending-type dispatch for the not-ready duck-test and deleted the fail-loud
# guard, so a Pending that is ALREADY ready at the done path (a benign completion
# race, or a stale process skewed against DO's fetch contract) flowed to
# `render_result(rv)` RAW and serialized as `Pending(ThreadsafeDict(...),...)` —
# the handle substituted for the figure Bruno's FDA report exported. Asserting
if _OLD_PENDING
    # `_is_unresolved_handle(ready) == false` and STOPPING (the old test) encoded the
    # bug as correct: it never checked what `_polling_resolve` DOES with a ready
    # handle. It must resolve it — render_result must see the VALUE `[1,2,3]`.
    c2 = ThreadsafeDict()
    k2 = (("done",), (;))
    ready = Pending(c2, k2, nothing)
    Base.isready(ready) && error("race fixture was already ready at hand-back")
    # Deterministic completion seam: DynamicObjects has selected and handed back the
    # Pending, but the value lands before Treebars performs its readiness check.
    c2.cache[k2] = [1, 2, 3]
    check("resolved Pending is not classified as unresolved", () -> begin
        Base.isready(ready) || error("fixture not ready")
        ext._is_unresolved_handle(ready) && error("ready handle classified as unresolved")
    end)

    check("a ready Pending IS a handle (readiness-agnostic detector)", () -> begin
        ext._is_handle(ready) || error("ready Pending not detected as a handle")
    end)

    # The done path must hand render_result the resolved VALUE, on BOTH the sync
    # loopback (Bruno's `sync=wants_markdown(__req__)` path) and the async path.
    for sync in (true, false)
        check("completion-race Pending renders once without warning (sync=$sync)", () -> begin
            got = Ref{Any}(:untouched)
            renders = Ref(0)
            logger = Test.TestLogger(min_level=Logging.Warn)
            node = Logging.with_logger(logger) do
                ext._polling_resolve(ready, nothing;
                    sync, keep_progress=false, label="probe", poll_url="/poll",
                    poll_interval="200ms", cancel_url="", ip_ctx="ctx.warmup",
                    render_result = value -> (renders[] += 1; got[] = value; "rendered"))
            end
            isempty(logger.logs) || error("legal completion race emitted warning(s): $(logger.logs)")
            renders[] == 1 || error("render_result called $(renders[]) times")
            got[] isa Pending && error("render_result received the RAW handle, not the value")
            got[] == [1, 2, 3] || error("render_result got $(repr(got[])), expected [1,2,3]")
            html = ext.node_to_html(node)
            occursin("Pending", html) && error("serialized handle leaked into the body: $html")
        end)
    end
end

# --- 3. Ordinary values must not be classified as handles (no false positives) ---
for v in Any[[1,2,3], (; results=[1,2]), "a string", 42, nothing, Dict(:a=>1)]
    check("ordinary value passes: $(typeof(v))",
          () -> ext._is_unresolved_handle(v) && error("misclassified"))
end

# --- 4. The OLD handle type (Task) — the mirror-image skew — still polls ---
t = Task(() -> (sleep(30); 1)); schedule(t)
check("unresolved Task renders polling HTML without calling render_result", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    rendered = Ref(false)
    node = ext._polling_resolve(t, status;
        sync=false, keep_progress=true, label="probe", poll_url="/poll",
        poll_interval="200ms", cancel_url="", ip_ctx="ctx",
        render_result = _ -> (rendered[] = true; "done"))
    rendered[] && error("render_result received the unresolved Task")
    occursin("hx-trigger", ext.node_to_html(node)) || error("polling response has no hx-trigger")
end)

# --- 5. A foreign handle needs only the isready/fetch protocol ---
check("duck-typed handle resolves synchronously without a concrete type", () -> begin
    rendered = Ref{Any}(nothing)
    ext._polling_resolve(ProtocolPending(), nothing;
        sync=true, keep_progress=true, label=nothing, poll_url="/poll",
        poll_interval="200ms", cancel_url="", ip_ctx="ctx",
        render_result = value -> (rendered[] = value; "done"))
    rendered[] === :resolved_value || error("rendered $(repr(rendered[]))")
end)

# --- 6. _ip_ctx renders a useful context string ---
check("_ip_ctx is best-effort and never throws", () -> begin
    s = ext._ip_ctx(nothing, ("modelA",), (; checkpoint=false))
    occursin("modelA", s) || error("keys missing from: $s")
    occursin("checkpoint", s) || error("kwargs missing from: $s")
    println("     _ip_ctx -> ", s)
end)

# --- 7. Terminal success has no live-poller identity or transport ---
check("terminal success is visibly complete with an optional frozen record", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    Treebars.finalize_progress!(status)
    node = ext._polling_resolve(:done, status;
        sync=false, keep_progress=true, label="probe", poll_url="/poll",
        poll_interval="200ms", cancel_url="", ip_ctx="ctx",
        render_result = _ -> ext.h.p("done"))
    html = ext.node_to_html(node)
    occursin("class=\"treebar-terminal\"", html) || error("terminal wrapper missing")
    occursin("treebar-terminal-content", html) || error("terminal content marker missing")
    occursin("treebar-frozen", html) || error("frozen progress record missing")
    occursin("class=\"treebar-poller\"", html) && error("live poller wrapper survived")
    occursin("treebar-poller-inner", html) && error("live poller inner survived")
    occursin("treebar-pause", html) && error("Pause control survived")
    occursin("treebar-badge", html) && error("badge chrome survived")
    occursin("hx-get", html) && error("poll transport survived")
    occursin("hx-trigger", html) && error("poll ticker survived")
end)

# --- 8. Running face carries the badge, not a Pause button ---
# Snag poller-badge-qui-2203b4a1: one `.treebar-badge` per live poller —
# hairline strip + pause/play glyph control + label + status + bar + elapsed —
# with the full tree still in the DOM beneath it. Expanded by default since
# snag first-load-polle-9728d9da (§10/§15); `chrome=:quiet` collapses it.
function _badge_running_html()
    status = Treebars.initialize_progress!(:state; description="probe")
    run = Treebars.initialize_progress!(status, 4; description="load")
    Treebars.update_progress!(run, 1)
    node = ext._polling_running(status; label="slow",
        poll_url="/slow", poll_interval="200ms", cancel_url="")
    ext.node_to_html(node)
end

check("running face carries one badge with glyph control, label, status, bar (elapsed lives on the root row)", () -> begin
    html = _badge_running_html()
    count("class=\"treebar-badge\"", html) == 1 || error("badge wrapper missing or duplicated")
    for cls in ("treebar-badge-strip", "treebar-badge-panel", "treebar-badge-label",
                "treebar-badge-status", "treebar-badge-bar")
        occursin("class=\"$cls\"", html) || error("$cls missing from badge")
    end
    # Dedup (snag expanded-first-l-360630fb): the fixture root ("probe") is
    # described, so it renders its own duration span and the badge omits its
    # restating elapsed copy — the tree keeps the single surviving readout.
    occursin("class=\"treebar-badge-elapsed\"", html) && error("badge elapsed restates the root duration")
    occursin("class=\"treebar-duration\"", html) || error("root duration missing from tree")
    occursin(">❚❚</button>", html) || error("pause glyph button missing")
    occursin("aria-label=\"Pause live updates\"", html) || error("pause aria-label missing")
    occursin("title=\"Pause live updates (the work keeps running in the background)\"",
             html) || error("pause title missing")
    occursin(">Polling</span>", html) || error("initial status word missing")
    occursin(">slow</span>", html) || error("badge label missing")
    # The pause control goes inert once its poller stops polling (same guard as
    # sibling snag treebars-pause-l-19b2227a, subsumed by this badge).
    occursin("treebar-poller-inner[hx-trigger]", html) || error("onclick inert-guard missing")
    occursin("__tbSyncBadge", html) || error("onclick badge-sync call missing")
    occursin(">Pause</button>", html) && error("old prominent Pause button survived")
    # The tree itself is untouched beneath the badge: label header + bar source.
    occursin("slow — running...", html) || error("running header missing from inner")
    occursin("class=\"treebar-progress\"", html) || error("determinate bar source missing from inner")
    first(findfirst("class=\"treebar-badge\"", html)) <
        first(findfirst("class=\"treebar-poller-inner\"", html)) ||
        error("badge must precede the inner in document order")
end)

# --- 9. hx-select is top-level-only across all three branches ---
check("hx-select selects only top-level matches (six :not exclusions)", () -> begin
    html = _badge_running_html()
    m = match(r"hx-select=\"([^\"]*)\"", html)
    m === nothing && error("hx-select missing from polling inner")
    sel = m.captures[1]
    expected = ".treebar-poller-inner" *
        ":not(.treebar-poller-inner .treebar-poller-inner)" *
        ":not(.treebar-terminal-content .treebar-poller-inner)" *
        ", .treebar-terminal-content" *
        ":not(.treebar-poller-inner .treebar-terminal-content)" *
        ":not(.treebar-terminal-content .treebar-terminal-content)" *
        ", article[aria-invalid=&#39;true&#39;]" *
        ":not(.treebar-poller-inner article)" *
        ":not(.treebar-terminal-content article)"
    sel == expected || error("hx-select drifted:\n  got: $sel\n  want: $expected")
end)

check("nested pollers nest selected regions (the duplication precondition)", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    nested = ext._polling_running(status; label="inner",
        poll_url="/inner", poll_interval="200ms", cancel_url="")
    outer = ext._polling_wrap(
        ext._polling_inner_running("/outer", "200ms", nested);
        pausable=true, badge=ext._poll_badge("outer", status))
    html = ext.node_to_html(outer)
    # Outer inner CONTAINS a nested poller wrapper + inner: the shape whose
    # double match the top-level-only selector rules out (browser-verified).
    count("class=\"treebar-poller-inner\"", html) == 2 || error("expected outer + nested inner")
    count("class=\"treebar-badge\"", html) == 2 || error("expected outer + nested badge")
end)

# --- 10. Stylesheet: expanded default, quiet opt-in, gated pulse ---
# Snag first-load-polle-9728d9da: the panel and tree render expanded unless
# the poller opts into quiet chrome (`data-chrome="quiet"`) or is diverted
# into HTMXObjects' live-refresh reporter — those two contexts keep the
# collapse + hover/focus expansion, with the inner rules still direct-child
# so an expanded outer poller never auto-expands a nested one.
check("badge stylesheet expands by default, quiets on attr or reporter", () -> begin
    css = ext.node_to_html(Treebars.htmx_treebar_styles())
    occursin(".treebar-poller > .treebar-poller-inner { display: block; }", css) ||
        error("expanded-default inner rule missing")
    # Line-anchored: the reporter-quiet rule legitimately ENDS with the same
    # selector text, so only a line-START match is the old blanket collapse.
    occursin(r"(?m)^\.treebar-poller > \.treebar-poller-inner \{ display: none; \}", css) &&
        error("unconditional inner-collapse rule survived")
    for sel in (".treebar-poller[data-chrome=\"quiet\"] .treebar-badge-panel",
                ".htmxo-live-reporter .treebar-poller .treebar-badge-panel")
        occursin(sel, css) || error("quiet panel-clip selector missing: $sel")
    end
    occursin("max-height: 0", css) || error("panel clip rule missing")
    for sel in (".treebar-poller[data-chrome=\"quiet\"]:hover .treebar-badge-panel",
                ".treebar-poller[data-chrome=\"quiet\"]:focus-within .treebar-badge-panel",
                ".htmxo-live-reporter .treebar-poller:hover .treebar-badge-panel",
                ".htmxo-live-reporter .treebar-poller:focus-within .treebar-badge-panel")
        occursin(sel, css) || error("quiet panel-expansion selector missing: $sel")
    end
    for sel in (".treebar-poller[data-chrome=\"quiet\"] > .treebar-poller-inner",
                ".htmxo-live-reporter .treebar-poller > .treebar-poller-inner")
        occursin(sel, css) || error("quiet inner-collapse selector missing: $sel")
    end
    for sel in (".treebar-poller[data-chrome=\"quiet\"]:hover > .treebar-poller-inner",
                ".treebar-poller[data-chrome=\"quiet\"]:focus-within > .treebar-poller-inner",
                ".htmxo-live-reporter .treebar-poller:hover > .treebar-poller-inner",
                ".htmxo-live-reporter .treebar-poller:focus-within > .treebar-poller-inner")
        occursin(sel, css) || error("quiet inner-reveal selector missing: $sel")
    end
    occursin("height: 2px", css) || error("hairline strip rule missing")
    occursin("prefers-reduced-motion: no-preference", css) ||
        error("reduced-motion gate missing")
    occursin("tb-badge-pulse", css) || error("polling pulse keyframes missing")
    occursin("linear-gradient", css) && error("gradient accent in badge stylesheet")
    occursin("box-shadow", css) && error("glowing shadow in badge stylesheet")
    occursin(":has(> .treebar-poller-inner[hx-trigger]) .treebar-pause", css) &&
        error("old :has pause-reveal rule survived")
end)

# --- 11. Script: badge mirror, badge terminalization, pause transport intact ---
check("badge script mirrors status and terminalizes the badge", () -> begin
    js = ext.node_to_html(Treebars.htmx_treebar_script())
    occursin("__tbSyncBadge", js) || error("badge mirror missing")
    occursin(":scope > .treebar-badge", js) || error("terminalize-badge removal missing")
    occursin(":scope > .treebar-pause", js) && error("old terminalize-pause removal survived")
    occursin("htmx:beforeRequest", js) || error("pause request-cancel listener missing")
    occursin("p.dataset.paused === '1'", js) || error("pause predicate missing")
    occursin("▶", js) && occursin("❚❚", js) || error("pause/play glyphs missing from mirror")
    occursin("'Paused'", js) && occursin("'Polling'", js) || error("status words missing from mirror")
end)

# --- 12. Failure response keeps the error article first inside terminal content ---
# The keep_progress failure shape through `polling_fetchindex`'s catch pieces:
# terminal wrapper > terminal content > (opaque `safely` article + open kept
# tree). The top-level-only selector (§9) leaves exactly the terminal content
# selected, so the article renders first, inside it. (Sibling snag
# treebars-pause-l-19b2227a's hx-select case, subsumed here.)
check("terminal failure keeps the recorded error first with no live chrome", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    Treebars.fail_progress!(status)
    node = ext._polling_wrap(
        ext._polling_inner_done(
            ext._caught_error_ex(ErrorException("boom"), nothing, nothing),
            ext._kept_progress(status; open=true));
        terminal=true)
    html = ext.node_to_html(node)
    occursin("class=\"treebar-terminal\"", html) || error("terminal wrapper missing")
    occursin("treebar-terminal-content", html) || error("terminal content marker missing")
    occursin("aria-invalid", html) || error("recorded error article missing")
    first(findfirst("aria-invalid", html)) < first(findfirst("treebar-frozen", html)) ||
        error("error article is not first inside the terminal content")
    occursin("class=\"treebar-poller\"", html) && error("live poller wrapper survived")
    occursin("treebar-badge", html) && error("badge chrome survived on terminal failure")
    occursin("hx-trigger", html) && error("poll ticker survived")
end)

# --- 13. `parent=` passthrough on polling_fetchindex (snag hang-pdf-embed-c-d79aad34) ---
# The IP's compute substatus must hang under the caller's node while running.
# NOTE (snag make-htmxobjects-7960c091): this section used to sit AFTER the
# file's `exit()`, so it never ran — which hid a second defect, the struct
# defined inside a `let` block (`@dynamicstruct` requires module scope).
# Both fixed here: the struct is top-level and the exit moved to the end.
@dynamicstruct struct _PollSlowIP
    __status__ = Treebars.initialize_progress!(:state; description="ip")
    index(key::String) = begin
        sleep(0.5)
        "computed:$key"
    end
end
const _PollIP = getproperty(_PollSlowIP(), :index)
check("polling_fetchindex parent= hangs the live IP compute under the caller node", () -> begin
    caller = Treebars.initialize_progress!(:state; description="caller")
    t = @async Treebars.polling_fetchindex(_PollIP, "hello"; sync=true, parent=caller) do v
        h.span()("got")
    end
    sleep(0.2)   # inside the 0.5s compute
    length(caller.children) == 1 || error("caller has no live substatus child mid-flight")
    child = first(caller.children)
    child isa Treebars.ProgressNode || error("caller child is not a ProgressNode")
    wait(t)
end)

# --- 14. `parent=:auto` default follows the dispatch caller (snag make-htmxobjects-7960c091) ---
# Resolution order: explicit `parent=` wins; else the request's dispatch node
# (read through the PUBLIC `HTMXObjects.dispatch_parent` accessor); else the
# ambient node `dispatch` bound; else detached. Each leg resolves to the SAME
# node object the explicit path would attach (`===`), so the default changes
# which call sites attach — never the attached tree's shape.
check("default-parent resolution: detached outside dispatch, ambient inside", () -> begin
    caller = Treebars.initialize_progress!(:state; description="auto-caller")
    ext._polling_default_parent(nothing) === nothing ||
        error("resolved a parent with no request and no ambient bind")
    Treebars.with_dispatch_parent(caller) do
        ext._polling_default_parent(nothing) === caller ||
            error("ambient bind did not resolve to the bound node")
    end
    ext._polling_default_parent(nothing) === nothing ||
        error("ambient bind leaked past its extent")
end)
check("default-parent resolution: request leg wins, then ambient", () -> begin
    req_node = Treebars.initialize_progress!(:state; description="req-node")
    ambient_node = Treebars.initialize_progress!(:state; description="ambient-node")
    # Fixture only: arrange the request state `dispatch(parent=...)` stashes.
    # The READ under test goes through the public `dispatch_parent` accessor.
    req = HTTP.Request("GET", "/probe")
    req.context[:htmxo_parent_progress] = req_node
    Treebars.with_dispatch_parent(ambient_node) do
        ext._polling_default_parent(req) === req_node ||
            error("request leg did not win over ambient")
    end
    # A request WITHOUT the key (plain loopback) falls through to ambient.
    plain = HTTP.Request("GET", "/plain")
    Treebars.with_dispatch_parent(ambient_node) do
        ext._polling_default_parent(plain) === ambient_node ||
            error("keyless request did not fall through to ambient")
    end
    ext._polling_default_parent(plain) === nothing ||
        error("keyless request resolved with no ambient bind")
end)
check("polling_fetchindex without parent= hangs compute under the ambient caller", () -> begin
    caller = Treebars.initialize_progress!(:state; description="auto-live")
    # The bind wraps the call on the SAME task, exactly as `dispatch` will:
    # no reliance on task-local-storage inheritance across `@async`.
    t = @async Treebars.with_dispatch_parent(caller) do
        Treebars.polling_fetchindex(_PollIP, "ambient-hello"; sync=true) do v
            h.span()("got")
        end
    end
    sleep(0.2)   # inside the 0.5s compute
    length(caller.children) == 1 || error("caller has no live substatus child mid-flight")
    child = first(caller.children)
    child isa Treebars.ProgressNode || error("caller child is not a ProgressNode")
    wait(t)
end)
check("explicit parent=nothing stays detached under an ambient bind (opt-out)", () -> begin
    caller = Treebars.initialize_progress!(:state; description="optout-live")
    t = @async Treebars.with_dispatch_parent(caller) do
        Treebars.polling_fetchindex(_PollIP, "optout-hello"; sync=true, parent=nothing) do v
            h.span()("got")
        end
    end
    sleep(0.2)   # inside the 0.5s compute
    isempty(caller.children) || error("explicit nothing attached under ambient")
    wait(t)
end)
check("explicit parent=node wins over ambient", () -> begin
    ambient_node = Treebars.initialize_progress!(:state; description="ambient-other")
    explicit_node = Treebars.initialize_progress!(:state; description="explicit-live")
    t = @async Treebars.with_dispatch_parent(ambient_node) do
        Treebars.polling_fetchindex(_PollIP, "explicit-hello"; sync=true, parent=explicit_node) do v
            h.span()("got")
        end
    end
    sleep(0.2)   # inside the 0.5s compute
    length(explicit_node.children) == 1 || error("explicit node has no live substatus child mid-flight")
    isempty(ambient_node.children) || error("ambient node stole the explicitly-parented compute")
    wait(t)
end)

# --- 15. `chrome` kwarg: expanded default, quiet opt-in (snag first-load-polle-9728d9da) ---
# `:auto` (default) emits no `data-chrome` attr — the stylesheet expands the
# panel + tree, so a first-load region shows progress immediately. `:quiet`
# emits `data-chrome="quiet"` on the live wrapper, collapsing to the hairline
# (hover/focus re-expands). Anything else throws `ArgumentError` at the public
# boundary, before any compute runs. Terminal wrappers carry no badge and no attr.
check("default chrome emits no data-chrome attr", () -> begin
    html = _badge_running_html()
    occursin("data-chrome", html) && error("default poller carries a data-chrome attr")
end)
check("chrome=:quiet emits data-chrome=quiet on the live wrapper", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    node = ext._polling_running(status; label="slow",
        poll_url="/slow", poll_interval="200ms", cancel_url="", chrome=:quiet)
    html = ext.node_to_html(node)
    occursin("data-chrome=\"quiet\"", html) || error("quiet attr missing")
    first(findfirst("data-chrome", html)) <
        first(findfirst("class=\"treebar-badge\"", html)) ||
        error("quiet attr is not on the wrapper (must precede the badge)")
end)
check("chrome threads through polling_fetchindex to the running face", () -> begin
    for (chrome, want) in ((:auto, false), (:quiet, true))
        node = Treebars.polling_fetchindex(_PollIP, "chrome-$chrome";
                                           poll_url="/chrome", chrome=chrome) do v
            ext.h.p("done")
        end
        html = ext.node_to_html(node)
        occursin("hx-trigger", html) || error("expected the running face for chrome=$chrome")
        occursin("data-chrome=\"quiet\"", html) == want ||
            error("chrome=$chrome quiet-attr presence is $(!want), want $want")
    end
end)
check("invalid chrome throws ArgumentError before compute", () -> begin
    try
        Treebars.polling_fetchindex(_PollIP, "chrome-bogus";
                                   poll_url="/chrome", chrome=:bogus) do v
            ext.h.p("done")
        end
        error("no throw for chrome=:bogus")
    catch e
        e isa ArgumentError || rethrow()
        occursin("chrome", sprint(showerror, e)) || error("ArgumentError names nothing about chrome")
    end
end)
check("terminal wrappers carry no chrome attr", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    Treebars.finalize_progress!(status)
    node = ext._polling_resolve(:done, status;
        sync=false, keep_progress=true, label="probe", poll_url="/poll",
        poll_interval="200ms", cancel_url="", ip_ctx="ctx", chrome=:quiet,
        render_result = _ -> ext.h.p("done"))
    html = ext.node_to_html(node)
    occursin("class=\"treebar-terminal\"", html) || error("terminal wrapper missing")
    occursin("data-chrome", html) && error("terminal wrapper carries a chrome attr")
end)

# --- 16. Badge label wraps, never clips (snag poller-badge-lab-78301564) ---
# The label rule carried max-width/overflow/ellipsis/nowrap, so a long poller
# label rendered as "For-You master/detail rollup (waiting r…" (scrollWidth
# 496px in a 224px box). Labels are read content: the rule must wrap, the
# panel must flex-wrap so the status siblings drop below on narrow widths,
# and the quiet hover/focus expansion must not cap the panel height.
check("badge label rule wraps instead of clipping", () -> begin
    css = ext.node_to_html(Treebars.htmx_treebar_styles())
    m = match(r"\.treebar-badge-label \{([^}]*)\}", css)
    m === nothing && error("badge label rule missing from stylesheet")
    for banned in ("nowrap", "ellipsis", "overflow", "max-width",
                   "white-space", "text-overflow")
        occursin(banned, m.captures[1]) && error("label rule still clips: $banned")
    end
    m = match(r"\.treebar-badge-panel \{([^}]*)\}", css)
    m === nothing && error("badge panel rule missing from stylesheet")
    occursin("flex-wrap", m.captures[1]) || error("badge panel does not flex-wrap")
    occursin("max-height: 2.5rem", css) &&
        error("quiet panel expansion still caps height at 2.5rem")
end)

# --- 17. Running-face dedup: one label, one elapsed (snag expanded-first-l-360630fb) ---
# Badge and tree are co-visible in the expanded default chrome. When the
# poller label equals the status root's description, the badge label, the
# interim "<label> — running..." header, and the root header rendered one
# string three times — and the badge elapsed always restated the root's
# duration span (2x in BOTH the label and label=nothing paths). The running
# face now omits the redundant copies server-side; the tree keeps the single
# surviving copy of each. Nothing is dropped: every omitted copy renders
# identically one line below.
function _dedup_running_html(label, status; cancel_url="")
    node = ext._polling_running(status; label=label, poll_url="/poll",
        poll_interval="200ms", cancel_url=cancel_url)
    ext.node_to_html(node)
end

check("equal label renders once: no badge label, no interim header, root keeps it", () -> begin
    label = "rollup-dedup-probe"
    status = Treebars.initialize_progress!(:state; description=label)
    Treebars.initialize_progress!(status; description="phase-one")
    html = _dedup_running_html(label, status)
    count(label, html) == 1 || error("label renders $(count(label, html))x, want 1x")
    occursin("class=\"treebar-badge-label\"", html) && error("badge label restates the root header")
    occursin("running...", html) && error("interim running header restates the root header")
    occursin("<header", html) && error("a header element survived the dedup")
    occursin("phase-one", html) || error("phase tree lost under the dedup")
    occursin("<article", html) || error("article wrapper lost under the dedup")
end)

check("equal label with cancel_url keeps the Stop control", () -> begin
    label = "rollup-dedup-probe"
    status = Treebars.initialize_progress!(:state; description=label)
    html = _dedup_running_html(label, status; cancel_url="/stop")
    occursin(">Stop</a>", html) || error("Stop control lost under the dedup")
    occursin("/stop", html) || error("Stop href lost under the dedup")
    occursin("running...", html) && error("interim header restates the label")
    count(label, html) == 1 || error("label renders $(count(label, html))x, want 1x")
end)

check("unequal label keeps badge label and interim header (2x, pinned)", () -> begin
    html = _badge_running_html()  # label "slow", root "probe"
    # ">slow" pins the two rendered copies (badge span + interim header);
    # the "/slow" poll URL must not count.
    count(">slow", html) == 2 || error("label renders $(count(">slow", html))x, want 2x")
    occursin("slow — running...", html) || error("interim header missing for a distinct label")
end)

check("elapsed dedup follows the root shape: omitted iff the root renders its own duration", () -> begin
    # described container / counter / message roots render a duration span —
    # the badge copy goes, the tree copy stays.
    described = Treebars.initialize_progress!(:state; description="op-label")
    counter = Treebars.initialize_progress!(:state; N=4, description="count-root")
    messaged = Treebars.initialize_progress!(:state; description="msg-root")
    Treebars.update_progress!(messaged, "working")
    for (name, st) in (("described", described), ("counter", counter),
                       ("message", messaged))
        html = _dedup_running_html("other-label", st)
        occursin("class=\"treebar-badge-elapsed\"", html) &&
            error("$name root: badge elapsed restates the root duration")
        occursin("class=\"treebar-duration\"", html) ||
            error("$name root: root duration missing from tree")
    end
    # An undescribed container root renders no header of its own — the badge
    # elapsed is the only readout and must stay.
    bare = Treebars.initialize_progress!(:state; description="")
    html = _dedup_running_html("other-label", bare)
    occursin("class=\"treebar-badge-elapsed\"", html) ||
        error("undescribed root: badge elapsed wrongly omitted")
    occursin("class=\"treebar-duration\"", html) &&
        error("undescribed root: unexpected root duration")
end)

check("label=nothing keeps one label and one elapsed on a described root", () -> begin
    status = Treebars.initialize_progress!(:state; description="single-line-op")
    html = _dedup_running_html(nothing, status)
    count("single-line-op", html) == 1 || error("label renders $(count("single-line-op", html))x, want 1x")
    occursin("class=\"treebar-badge-label\"", html) && error("badge label without a label")
    occursin("class=\"treebar-badge-elapsed\"", html) && error("badge elapsed restates the root duration")
    occursin("class=\"treebar-duration\"", html) || error("root duration missing from tree")
end)

check("dedup helpers stay quiet on exotic statuses (nothing kept, never dropped)", () -> begin
    ext._status_root_description(nothing) === nothing || error("nothing has a description")
    ext._root_renders_duration(nothing) && error("nothing renders a duration")
    ext._label_restates_root("x", nothing) && error("nothing restates a label")
    ext._label_restates_root(nothing, nothing) && error("nothing label restates")
    hidden = Treebars.ProgressNode(Treebars.StateProgress(; description="hid"),
        (; propagates=false, displayed=false))
    ext._status_root_description(hidden) === nothing || error("undisplayed root has a description")
    ext._root_renders_duration(hidden) && error("undisplayed root renders a duration")
    annotated = Treebars.ProgressNode(Treebars.StateProgress(; description="k"),
        (; propagates=false, annotation=true))
    Treebars.update_progress!(annotated, "v")
    ext._root_renders_duration(annotated) && error("annotation root renders a duration")
    ext._status_root_description(annotated) == "k" || error("annotation root lost its description")
    ext._label_restates_root("k", annotated) || error("annotation root match missed")
end)

# --- 18. Hidden-document poll guard (snag treebars-pollers-076014bd) ---
# A poller in a hidden document (background tab, minimized window) must not
# keep issuing `every` requests for nobody. The running face carries the
# trigger filter `[!document.hidden]` — the same shape as the KB's own
# production poll guard — so htmx skips the request while hidden and resumes
# on visibility (the `every` timer keeps rescheduling, so resume needs no
# re-arming). The value still starts with `every`: consumers detect a running
# poller with `occursin("hx-trigger=\"every", body)`.
check("running face filters its every trigger on document.hidden", () -> begin
    html = _badge_running_html()  # poll_interval="200ms"
    occursin("hx-trigger=\"every 200ms [!document.hidden]\"", html) ||
        error("hidden-tab filter missing from the running trigger")
end)
check("running trigger still starts with every (consumer running-poller probe)", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    node = ext._polling_running(status; label="slow",
        poll_url="/slow", poll_interval="2s", cancel_url="")
    html = ext.node_to_html(node)
    occursin("hx-trigger=\"every", html) || error("trigger lost its every prefix")
    occursin("hx-trigger=\"every 2s [!document.hidden]\"", html) ||
        error("custom poll_interval did not thread into the filtered trigger")
end)
check("terminal faces carry no trigger to filter", () -> begin
    status = Treebars.initialize_progress!(:state; description="probe")
    Treebars.finalize_progress!(status)
    node = ext._polling_resolve(:done, status;
        sync=false, keep_progress=true, label="probe", poll_url="/poll",
        poll_interval="200ms", cancel_url="", ip_ctx="ctx",
        render_result = _ -> ext.h.p("done"))
    html = ext.node_to_html(node)
    occursin("document.hidden", html) && error("hidden filter leaked into terminal markup")
end)

println(nfail == 0 ? "\nALL GUARD TESTS PASSED" : "\n$nfail TEST(S) FAILED")
exit(nfail == 0 ? 0 : 1)
