# Inline child-struct substatus inheritance demo. `Sub` is an inline
# @dynamicstruct; it inherits cache_type from the parent and gets a scoped
# ProgressNode as __status__ (wired by DynamicObjects/ext/TreebarsExt.jl).

@dynamicstruct struct NestedData
    __status__ = initialize_progress!(:state; description="Nested")
    struct Sub
        results(key) = fake_sampling(__status__; n_steps=100, sleep_per_step=0.02)
    end
end

@htmx struct NestedRoutes
    (; nested) = __appdata__
    (; Sub) = nested
    (; results) = Sub

    @get compute(key; force::Bool=false) = polling_fetchindex(results, key;
        poll_url = query_url(__self__/"compute/$key"),
        label = "Nested '$key'", force,
    ) do rv
        result_article("Nested result for '$key'",
            sample_summary(rv), sample_minmax(rv);
            rerun_url = __self__/"compute/$key",
        )
    end
end
