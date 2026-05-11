# HTTP-polling compute demo. Simulates async work via `fake_sampling` through a
# DynamicObjects parallel cache; consumers poll a per-key status and get the
# result when the task completes.

@dynamicstruct struct AsyncComputationsData
    __status__ = initialize_progress!(:state; description="Async")
    results(key) = fake_sampling(__status__)
    parameterized(n_steps, sleep_per_step) = fake_sampling(__status__; n_steps, sleep_per_step)
end

@htmx struct AsyncComputationsRoutes
    (; async) = __appdata__
    (; results, parameterized) = async

    @get compute(key; force::Bool=false) = polling_fetchindex(results, key;
        poll_url = query_url(__self__/"compute/$key"),
        cancel_url = query_url(__self__/"cancel/$key"),
        label = "Computing '$key'", force,
    ) do rv
        result_article("Result for '$key'",
            sample_summary(rv), sample_minmax(rv);
            rerun_url = __self__/"compute/$key",
        )
    end

    @get cancel(key) = begin
        cancel!(results, key)
        result_article("Cancelled '$key'", h.p("Task was cancelled."))
    end

    @get param(n_steps::Int, sleep_ms::Int; force::Bool=false) = begin
        sleep_per_step = sleep_ms / 1000.0
        polling_fetchindex(parameterized, n_steps, sleep_per_step;
            poll_url = query_url(__self__/"param/$n_steps/$sleep_ms"),
            label = "Parameterized", force,
        ) do rv
            result_article("Result ($n_steps steps @ $(sleep_ms)ms)",
                sample_summary(rv);
                rerun_url = __self__/"param/$n_steps/$sleep_ms",
            )
        end
    end
end
