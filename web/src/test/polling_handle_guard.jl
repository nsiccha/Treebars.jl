# Integration check for the unresolved-handle guard in HTMXObjectsExt
# (`_assert_resolved` / `_is_unresolved_handle`) — snag polling-fetchind-dd65fe41.
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
# This test is what caught the `Task`/`isready` gap: precompile was clean while
# the guard silently missed a running Task (Base defines `istaskdone` for Task,
# not `isready`).

using Treebars, HTMXObjects, HTTP
using DynamicObjects: ThreadsafeDict, Pending

ext = Base.get_extension(Treebars, :HTMXObjectsExt)
ext === nothing && error("FAIL: HTMXObjectsExt did NOT load (Base.get_extension returned nothing)")
println("OK  extension loaded: ", ext)

isdefined(ext, :_assert_resolved) || error("FAIL: _assert_resolved not defined in the loaded extension")
println("OK  _assert_resolved present in the LOADED image")

nfail = 0
function check(name, f)
    try
        f(); println("OK  ", name)
    catch e
        global nfail += 1
        println("FAIL ", name, " :: ", sprint(showerror, e))
    end
end

# --- 1. An UNRESOLVED Pending (the exact shape Bruno saw) must be rejected ---
c = ThreadsafeDict()
key = ((("warmup",)), (; n_chains=4, n_draws=1000, seed=1, init_positions=nothing,
                          threads_per_chain=1, checkpoint=false))
pending = Pending(c, key, nothing)
check("unresolved Pending reports isready=false", () -> Base.isready(pending) && error("was ready"))

check("guard REJECTS an unresolved Pending", () -> begin
    try
        ext._assert_resolved(pending, "sc.warmup_hmc(\"m\"; checkpoint=false)")
        error("guard did NOT fire — the handle would have reached render_result")
    catch e
        msg = sprint(showerror, e)
        occursin("UNRESOLVED handle", msg) || error("wrong error: $msg")
        occursin("warmup_hmc", msg)        || error("error does not name the IP/key: $msg")
        occursin("Pending", msg)           || error("error does not name the handle type: $msg")
        println("     message names IP+key+type; first line:")
        println("     ", first(split(msg, '\n')))
    end
end)

# --- 2. A RESOLVED Pending must pass straight through ---
c2 = ThreadsafeDict()
k2 = (("done",), (;))
c2.cache[k2] = [1, 2, 3]
ready = Pending(c2, k2, nothing)
check("resolved Pending passes through", () -> begin
    Base.isready(ready) || error("fixture not ready")
    ext._assert_resolved(ready, "ctx") === ready || error("did not pass through")
end)

# --- 3. Ordinary values must be untouched (no false positives) ---
for v in Any[[1,2,3], (; results=[1,2]), "a string", 42, nothing, Dict(:a=>1)]
    check("ordinary value passes: $(typeof(v))",
          () -> ext._assert_resolved(v, "ctx") === v || error("mutated/rejected"))
end

# --- 4. The OLD handle type (Task) — the mirror-image skew — is also caught ---
t = Task(() -> (sleep(30); 1)); schedule(t)
check("guard REJECTS an unresolved Task (mirror-image skew)", () -> begin
    try
        ext._assert_resolved(t, "sc.warmup_hmc(...)")
        error("guard did NOT fire for a running Task")
    catch e
        occursin("UNRESOLVED handle", sprint(showerror, e)) || rethrow()
    end
end)

# --- 5. _ip_ctx renders a useful context string ---
check("_ip_ctx is best-effort and never throws", () -> begin
    s = ext._ip_ctx(nothing, ("modelA",), (; checkpoint=false))
    occursin("modelA", s) || error("keys missing from: $s")
    occursin("checkpoint", s) || error("kwargs missing from: $s")
    println("     _ip_ctx -> ", s)
end)

println(nfail == 0 ? "\nALL GUARD TESTS PASSED" : "\n$nfail TEST(S) FAILED")
exit(nfail == 0 ? 0 : 1)
