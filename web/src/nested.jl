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
        h.article(
            h.header("Nested result for '$key'"),
            h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))"),
            h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))"),
            h.button("Rerun"; hx_get=string(query_url(__self__/"compute/$key"; force=true)),
                hx_target="closest article", hx_swap="outerHTML"),
        )
    end
end
