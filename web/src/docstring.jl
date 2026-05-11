# Docstring-as-progress-description demo. Each property's docstring (with $-
# interpolation of its arguments) becomes the substatus description instead of
# the auto-generated "name[args]" form from DynamicObjects.

@dynamicstruct struct DocstringData
    __status__ = initialize_progress!(:state; description="Docstring")

    "Sampling chain"
    results(key) = fake_sampling(__status__)

    "Sampling $(n_steps) steps at $(sleep_per_step)s intervals"
    parameterized(n_steps, sleep_per_step) = fake_sampling(__status__; n_steps, sleep_per_step)

    "Cached sampling for $(key)"
    @cached cached_results(key) = fake_sampling(__status__)
end

@htmx struct DocstringRoutes
    (; docstring) = __appdata__
    (; results, parameterized, cached_results) = docstring

    @get compute(key; force::Bool=false) = polling_fetchindex(results, key;
        poll_url = query_url(__self__/"compute/$key"),
        label = "Docstring '$key'", force,
    ) do rv
        result_article("Result for '$key'",
            sample_summary(rv);
            rerun_url = __self__/"compute/$key",
        )
    end

    @get cached(key; force::Bool=false) = polling_fetchindex(cached_results, key;
        poll_url = query_url(__self__/"cached/$key"),
        label = "Cached '$key'", force,
    ) do rv
        result_article("Cached result for '$key'",
            sample_summary(rv);
            rerun_url = __self__/"cached/$key",
        )
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
