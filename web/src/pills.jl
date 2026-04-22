# Toggle-pill child-display demos at various nesting patterns. Each builder
# constructs a throwaway StateProgress tree on the fly — no persistent state —
# so PillDemosData is empty and every helper lives on PillDemosRoutes.

@dynamicstruct struct PillDemosData end

@htmx struct PillDemosRoutes
    # 1. Flat: mixed child states at one level.
    flat = begin
        root = initialize_progress!(:state; description="Pathfinder")
        c1 = initialize_progress!(root, 1000; description="Chain 1")
        update_progress!(c1, 1000); finalize_progress!(c1)
        c2 = initialize_progress!(root, 1000; description="Chain 2")
        update_progress!(c2, 42); fail_progress!(c2)
        c3 = initialize_progress!(root, 1000; description="Chain 3")
        update_progress!(c3, 350; stepsize="0.12", divergences="0")
        c4 = initialize_progress!(root, 1000; description="Chain 4")
        update_progress!(c4, 1000); finalize_progress!(c4)
        htmx_render_children(root)
    end

    # 2. Nested: always-running parents with substatus children accumulating.
    nested = begin
        root = initialize_progress!(:state; description="Sim Dose-Response")
        healthy = initialize_progress!(root; description="Healthy")
        for i in 1:3
            c = initialize_progress!(healthy, 500; description="auc24s[dose=$i]")
            update_progress!(c, 500); finalize_progress!(c)
        end
        c_run = initialize_progress!(healthy, 500; description="auc24s[dose=4]")
        update_progress!(c_run, 200)
        pd = initialize_progress!(root; description="PD")
        c_ok = initialize_progress!(pd, 500; description="mcfb_pbmc[dose=1]")
        update_progress!(c_ok, 500); finalize_progress!(c_ok)
        c_fail = initialize_progress!(pd, 500; description="mcfb_csf[dose=1]")
        update_progress!(c_fail, 100); fail_progress!(c_fail)
        htmx_render_children(root)
    end

    # 3. Deep: root → groups → chains → labels.
    deep = begin
        root = initialize_progress!(:state; description="Experiment")
        for (gname, n_chains) in [("Group A", 4), ("Group B", 3)]
            group = initialize_progress!(root; description=gname)
            for ci in 1:n_chains
                chain = initialize_progress!(group, 1000; description="Chain $ci")
                if ci < n_chains
                    update_progress!(chain, 1000; ess="$(rand(100:400))", rhat="$(round2(1.0 + rand()*0.02))")
                    finalize_progress!(chain)
                elseif gname == "Group A"
                    update_progress!(chain, 600; ess="$(rand(50:150))", rhat="$(round2(1.0 + rand()*0.1))")
                else
                    update_progress!(chain, 200)
                    fail_progress!(chain)
                end
            end
        end
        htmx_render_children(root)
    end

    all_finished = begin
        root = initialize_progress!(:state; description="Completed run")
        for i in 1:5
            c = initialize_progress!(root, 200; description="Step $i")
            update_progress!(c, 200); finalize_progress!(c)
        end
        htmx_render_children(root)
    end

    all_running = begin
        root = initialize_progress!(:state; description="Active run")
        for i in 1:3
            c = initialize_progress!(root, 500; description="Worker $i")
            update_progress!(c, i * 100)
        end
        htmx_render_children(root)
    end

    docstrings = begin
        # Side-by-side: auto-generated substatus vs custom docstring labels.
        root = initialize_progress!(:state; description="Docstring vs Auto")
        auto1 = initialize_progress!(root; description="results[key1]")
        c = initialize_progress!(auto1, 500; description="MCMC", propagates=true)
        update_progress!(c, 500); finalize_progress!(c)
        auto2 = initialize_progress!(root; description="parameterized[200,0.02]")
        c = initialize_progress!(auto2, 500; description="MCMC", propagates=true)
        update_progress!(c, 300)
        doc1 = initialize_progress!(root; description="Sampling chain")
        c = initialize_progress!(doc1, 500; description="MCMC", propagates=true)
        update_progress!(c, 500); finalize_progress!(c)
        doc2 = initialize_progress!(root; description="Sampling 200 steps at 0.02s intervals")
        c = initialize_progress!(doc2, 500; description="MCMC", propagates=true)
        update_progress!(c, 300)
        htmx_render_children(root)
    end

    @get index = h.div(
        h.h3("Pill Demos"),
        h.p("Various tree structures demonstrating pill filtering at different nesting levels.";
            style="font-size:0.9em;color:var(--pico-muted-color)"),

        h.h4("1. Flat — mixed child states"), flat,
        h.hr(),

        h.h4("2. Nested — structural parents with substatus children"),
        h.p("Bruno pattern: always-running parents with finished/failed/running grandchildren.";
            style="font-size:0.85em;color:var(--pico-muted-color)"),
        nested,
        h.hr(),

        h.h4("3. Deep — three-level tree"),
        h.p("Root → groups → chains → labels. Pills at every level.";
            style="font-size:0.85em;color:var(--pico-muted-color)"),
        deep,
        h.hr(),

        h.h4("4. All finished — only pills visible"), all_finished,
        h.hr(),

        h.h4("5. All running — no pills"), all_running,
        h.hr(),

        h.h4("6. Docstring descriptions — auto vs custom"),
        h.p("Top two: auto (\"results[key1]\", \"parameterized[200,0.02]\"). Bottom two: docstrings (\"Sampling chain\", \"Sampling 200 steps at 0.02s intervals\").";
            style="font-size:0.85em;color:var(--pico-muted-color)"),
        docstrings,
    )
end
