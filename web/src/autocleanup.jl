# Auto-cleanup demo: exercises the transient-substatus detach path.
# Each `results[k]` goes through DO's ThreadsafeDict.get! spawn block, which
# calls _finalize_substatus! on success → TreebarsExt override detaches the
# transient substatus from the root tree. Fire N in parallel and watch the
# root children count spike then collapse to 0. Failing tasks stay pinned.

@dynamicstruct struct AutocleanupData
    __status__ = initialize_progress!(:state; description="AutoCleanup")

    "Computing '$key'"
    results(key) = fake_sampling(__status__; n_steps=40, sleep_per_step=0.05)

    "Failing '$key'"
    failing(key) = begin
        child = initialize_progress!(__status__, 20; description="Working", propagates=true)
        for i in 1:10
            update_progress!(child, i); sleep(0.05)
        end
        error("boom on $key")
    end
end

@htmx struct AutocleanupRoutes
    (; autocleanup) = __appdata__
    (; results, failing) = autocleanup
    # Not destructured as `(; __status__) = autocleanup` — `__status__` is a
    # reserved magic property name in HTMXObjects and the destructure collides.
    status_node = autocleanup.__status__

    # HTML helper for the self-polling frame. Route `@get refresh` re-renders it;
    # helper is called from the index + fire handlers to produce the initial /
    # post-action snapshot. Not `view` — that name collides with `@get view`.
    frame(msg="") = h.div(;
        id = "autocleanup-view",
        hx_get = string(query_url(__self__/"refresh")),
        hx_trigger = "every 300ms",
        hx_swap = "outerHTML",
    )(
        h.p("Root children: ", h.strong(string(length(status_node.children))),
            isempty(msg) ? "" : " — $msg"),
        htmx_render(status_node),
    )

    @get index = h.div(
        h.h3("Auto-cleanup demo"),
        h.p("Fires N parallel ", h.code("autocleanup.results[randkey]"),
            " computations. With the transient-substatus detach hook, each substatus detaches from the root tree on success — watch the ",
            h.em("Root children"), " count spike during the run and collapse back to 0. The failing button stays pinned as a red child."),
        h.fieldset(; role="group")(
            h.button("Fire 8"; hx_get=string(__self__/"fire/8"), hx_target="#autocleanup-view", hx_swap="outerHTML"),
            h.button("Fire 16"; hx_get=string(__self__/"fire/16"), hx_target="#autocleanup-view", hx_swap="outerHTML"),
            h.button("Fire failing"; hx_get=string(__self__/"fire_fail"), hx_target="#autocleanup-view", hx_swap="outerHTML"),
        ),
        frame(),
    )

    @get refresh = frame()

    @get fire(n::Int) = begin
        for _ in 1:n
            k = "k$(rand(1:1_000_000))"
            Threads.@spawn try; results[k]; catch; end
        end
        frame("spawned $n tasks")
    end

    @get fire_fail = begin
        k = "boom$(rand(1:1_000_000))"
        Threads.@spawn try; failing[k]; catch; end
        frame("spawned failing '$k' (stays pinned)")
    end
end
