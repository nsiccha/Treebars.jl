using TestItemRunner

@testitem "poller elapsed stays visible when the root has no duration row" setup=[TreebarsTestImports] tags=[:unit, :render, :polling] begin
    let
        ext = Base.get_extension(Treebars, :HTMXObjectsExt)
        bare = initialize_progress!(:state; description="")
        hidden = ProgressNode(StateProgress(; description="hidden"),
            (; propagates=false, displayed=false))
        annotated = ProgressNode(StateProgress(; description="source"),
            (; propagates=false, annotation=true))
        update_progress!(annotated, "cached")

        # These roots intentionally have no elapsed span in their own row.
        # Their poller badge still needs one, in the requested language.
        for root in (bare, hidden, annotated)
            start_progress!(root)
            for (locale, word) in ((:en, "so far"), (:de, "bisher"))
                html = repr(MIME"text/html"(), ext._polling_running(root;
                    label="Job", poll_url="/poll", poll_interval="200ms",
                    cancel_url="", texts=treebar_texts(locale)))
                @test count("class=\"treebar-badge-elapsed\"", html) == 1
                @test !occursin("class=\"treebar-duration\"", html)
                @test occursin(word, html)
            end
            finalize_progress!(root)
        end

        # A described root supplies its own duration; the badge omits the copy.
        described = initialize_progress!(:state; description="Job")
        html = repr(MIME"text/html"(), ext._polling_running(described;
            label="Job", poll_url="/poll", poll_interval="200ms", cancel_url=""))
        @test count("class=\"treebar-duration\"", html) == 1
        @test !occursin("class=\"treebar-badge-elapsed\"", html)
        finalize_progress!(described)
    end
end
