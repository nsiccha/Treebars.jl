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
using DynamicObjects: ThreadsafeDict, Pending

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

# --- 2. A RESOLVED Pending is RESOLVED before render_result, never rendered raw ---
# This is the crux of snag sync-polling-cal-c9717522: `e6f140f` traded the
# Pending-type dispatch for the not-ready duck-test and deleted the fail-loud
# guard, so a Pending that is ALREADY ready at the done path (a benign completion
# race, or a stale process skewed against DO's fetch contract) flowed to
# `render_result(rv)` RAW and serialized as `Pending(ThreadsafeDict(...),...)` —
# the handle substituted for the figure Bruno's FDA report exported. Asserting
# `_is_unresolved_handle(ready) == false` and STOPPING (the old test) encoded the
# bug as correct: it never checked what `_polling_resolve` DOES with a ready
# handle. It must resolve it — render_result must see the VALUE `[1,2,3]`.
c2 = ThreadsafeDict()
k2 = (("done",), (;))
c2.cache[k2] = [1, 2, 3]
ready = Pending(c2, k2, nothing)
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
    check("ready Pending is resolved before render_result (sync=$sync)", () -> begin
        got = Ref{Any}(:untouched)
        node = ext._polling_resolve(ready, nothing;
            sync, keep_progress=false, label="probe", poll_url="/poll",
            poll_interval="200ms", cancel_url="", ip_ctx="ctx.warmup",
            render_result = value -> (got[] = value; "rendered"))
        got[] isa Pending && error("render_result received the RAW handle, not the value")
        got[] == [1, 2, 3] || error("render_result got $(repr(got[])), expected [1,2,3]")
        html = ext.node_to_html(node)
        occursin("Pending", html) && error("serialized handle leaked into the body: $html")
    end)
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
    occursin("hx-get", html) && error("poll transport survived")
    occursin("hx-trigger", html) && error("poll ticker survived")
end)

println(nfail == 0 ? "\nALL GUARD TESTS PASSED" : "\n$nfail TEST(S) FAILED")
exit(nfail == 0 ? 0 : 1)
