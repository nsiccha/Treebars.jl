# Toggle-pill child-display demos at various nesting patterns. Each builder
# constructs a throwaway StateProgress tree on the fly — no persistent state —
# so PillDemosData is empty and every helper lives on PillDemosRoutes.

# Tree-construction primitives for the static demos. `propagates`/`transient`
# are forwarded to `initialize_progress!`; remaining kwargs become label
# sub-nodes via `update_progress!`. Demos pre-state trees once at module load
# and render them with `htmx_render_children` — no live update path.

"Add a child to `parent`, advance to `n`, and finalize it. `propagates`/`transient` go to `initialize_progress!`; remaining kwargs become label sub-nodes."
_pill_done(parent, n, desc; propagates=false, transient=false, labels...) = begin
    c = initialize_progress!(parent, n; description=desc, propagates, transient)
    update_progress!(c, n; labels...)
    finalize_progress!(c)
    c
end

"Add a child to `parent`, advance to `current`, and mark it failed."
_pill_failed(parent, n, desc, current; propagates=false, transient=false, labels...) = begin
    c = initialize_progress!(parent, n; description=desc, propagates, transient)
    update_progress!(c, current; labels...)
    fail_progress!(c)
    c
end

"Add a child to `parent`, advance to `current`, and leave it running."
_pill_running(parent, n, desc, current; propagates=false, transient=false, labels...) = begin
    c = initialize_progress!(parent, n; description=desc, propagates, transient)
    update_progress!(c, current; labels...)
    c
end

@dynamicstruct struct PillDemosData end

@htmx struct PillDemosRoutes
    # 1. Flat: mixed child states at one level.
    flat = begin
        root = initialize_progress!(:state; description="Pathfinder")
        _pill_done(root, 1000, "Chain 1")
        _pill_failed(root, 1000, "Chain 2", 42)
        _pill_running(root, 1000, "Chain 3", 350; stepsize="0.12", divergences="0")
        _pill_done(root, 1000, "Chain 4")
        htmx_render_children(root)
    end

    # 2. Nested: always-running parents with substatus children accumulating.
    nested = begin
        root = initialize_progress!(:state; description="Sim Dose-Response")
        healthy = initialize_progress!(root; description="Healthy")
        for i in 1:3
            _pill_done(healthy, 500, "auc24s[dose=$i]")
        end
        _pill_running(healthy, 500, "auc24s[dose=4]", 200)
        pd = initialize_progress!(root; description="PD")
        _pill_done(pd, 500, "mcfb_pbmc[dose=1]")
        _pill_failed(pd, 500, "mcfb_csf[dose=1]", 100)
        htmx_render_children(root)
    end

    # 3. Deep: root → groups → chains → labels.
    deep = begin
        root = initialize_progress!(:state; description="Experiment")
        for (gname, n_chains) in [("Group A", 4), ("Group B", 3)]
            group = initialize_progress!(root; description=gname)
            for ci in 1:n_chains
                if ci < n_chains
                    _pill_done(group, 1000, "Chain $ci"; ess="$(rand(100:400))", rhat="$(round2(1.0 + rand()*0.02))")
                elseif gname == "Group A"
                    _pill_running(group, 1000, "Chain $ci", 600; ess="$(rand(50:150))", rhat="$(round2(1.0 + rand()*0.1))")
                else
                    _pill_failed(group, 1000, "Chain $ci", 200)
                end
            end
        end
        htmx_render_children(root)
    end

    all_finished = begin
        root = initialize_progress!(:state; description="Completed run")
        for i in 1:5; _pill_done(root, 200, "Step $i"); end
        htmx_render_children(root)
    end

    all_running = begin
        root = initialize_progress!(:state; description="Active run")
        for i in 1:3; _pill_running(root, 500, "Worker $i", i * 100); end
        htmx_render_children(root)
    end

    docstrings = begin
        # Side-by-side: auto-generated substatus vs custom docstring labels.
        # Each branch is an outer container holding one "MCMC" child (done or running).
        root = initialize_progress!(:state; description="Docstring vs Auto")
        for (desc, done) in [
            ("results[key1]", true),
            ("parameterized[200,0.02]", false),
            ("Sampling chain", true),
            ("Sampling 200 steps at 0.02s intervals", false),
        ]
            outer = initialize_progress!(root; description=desc)
            done ?
                _pill_done(outer, 500, "MCMC"; propagates=true) :
                _pill_running(outer, 500, "MCMC", 300; propagates=true)
        end
        htmx_render_children(root)
    end

    @get index() = h.div(
        h.h3("Pill Demos"),
        h.p("Various tree structures demonstrating pill filtering at different nesting levels.";
            class="u-text-sm u-text-muted"),

        h.h4("1. Flat — mixed child states"), flat,
        h.hr(),

        h.h4("2. Nested — structural parents with substatus children"),
        h.p("Bruno pattern: always-running parents with finished/failed/running grandchildren.";
            class="u-text-sm u-text-muted"),
        nested,
        h.hr(),

        h.h4("3. Deep — three-level tree"),
        h.p("Root → groups → chains → labels. Pills at every level.";
            class="u-text-sm u-text-muted"),
        deep,
        h.hr(),

        h.h4("4. All finished — only pills visible"), all_finished,
        h.hr(),

        h.h4("5. All running — no pills"), all_running,
        h.hr(),

        h.h4("6. Docstring descriptions — auto vs custom"),
        h.p("Top two: auto (\"results[key1]\", \"parameterized[200,0.02]\"). Bottom two: docstrings (\"Sampling chain\", \"Sampling 200 steps at 0.02s intervals\").";
            class="u-text-sm u-text-muted"),
        docstrings,
    )
end
