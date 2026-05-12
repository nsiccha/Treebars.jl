# `@progress` phase-marker demos.
#
# Two sibling demos under this feature:
#   - `demo(key)` — static phase markers via @progress "label" begin…end, each
#     phase known at compile time. All marker phases appear as pending siblings
#     up front; transition to running/done as execution reaches each marker.
#   - `dynamic(preset)` — runtime-computed NamedTuple chain; uses
#     with_prepared_phases + with_prepared_progress. Exercises the leak-safe
#     bulk wrapper with an optional fail_at selector.

_dynamic_chain(preset) = preset == "short" ?
        (load=0.3, process=0.5, save=0.2) :
    preset == "long" ?
        (load=0.4, validate=0.3, preprocess=0.5, train=1.0, evaluate=0.6, postprocess=0.4, save=0.3) :
        (load=0.3, validate=0.2, process=0.5, analyze=0.4, save=0.2)   # "medium" default

@dynamicstruct struct PhasesData
    __status__ = initialize_progress!(:state; description="Phases")

    "Pipeline '$key'"
    results(key) = begin
        @progress "Pipeline" begin
            @progress "Load data"
            sleep(0.5 + rand() * 0.5)

            @progress "Preprocess"
            for _ in 1:5
                sleep(0.1)
            end

            @progress "Fit"
            for i in 1:40
                sleep(0.05)
            end

            @progress "Evaluate"
            sleep(0.4 + rand() * 0.4)

            @progress "Save"
            sleep(0.3)
        end
        :done
    end

    "Dynamic pipeline '$preset' (fail_at=$fail_at)"
    dynamic_results(preset, fail_at=nothing) = begin
        chain = _dynamic_chain(preset)
        with_prepared_phases(__status__, chain) do phases
            map(chain, phases) do duration, phase
                with_prepared_progress(phase) do _
                    sleep(duration)
                    phase.impl.description == string(fail_at) && error("simulated failure at $fail_at")
                    duration
                end
            end
        end
    end
end

@htmx struct PhasesRoutes
    (; phases) = __appdata__
    (; results, dynamic_results) = phases

    # Static phase markers — each @progress "label" pre-enumerates a pending child.
    @get demo(key; force::Bool=false) = polling_fetchindex(results, key;
        poll_url = query_url(__self__/"demo/$key"),
        cancel_url = query_url(__self__/"cancel/$key"),
        label = "Pipeline '$key'", force,
    ) do rv
        result_article("Pipeline '$key' — $rv"; rerun_url = __self__/"demo/$key")
    end

    @get cancel(key) = begin
        cancel!(results, key)
        result_article("Cancelled '$key'")
    end

    # Data-driven phase chain — with_prepared_phases + with_prepared_progress.
    @get dynamic(preset; force::Bool=false, fail_at::Symbol=Symbol("")) = begin
        fail_arg = fail_at == Symbol("") ? nothing : fail_at
        polling_fetchindex(dynamic_results, preset, fail_arg;
            poll_url = query_url(__self__/"dynamic/$preset"; fail_at),
            label = "Dynamic '$preset'" * (fail_arg === nothing ? "" : " (fail at :$fail_arg)"),
            force,
        ) do rv
            h.article(
                h.header("Dynamic '$preset' — total $(round(sum(rv); digits=2))s"),
                h.p("Per-phase durations: ", h.code(repr(rv))),
                rerun_button(__self__/"dynamic/$preset"; fail_at),
            )
        end
    end
end
