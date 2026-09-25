# Selective runner entry: `julia -tauto --project=test test/select.jl --tag=x`
# (or --name/--file/--list, or `--htmxo-test=<file>::<name>`). ARGS flows
# straight into runtests.jl — no Pkg.test sandbox: Pkg.test is unusable on
# Julia 1.10 for this dep shape (unregistered direct+transitive deps; the
# sandbox drops [sources] and trips "expected package X to be registered",
# and a developed test/Manifest collides with "can not merge projects").
# Run after developing the test env once (see test/Project.toml header).
include(joinpath(@__DIR__, "runtests.jl"))
