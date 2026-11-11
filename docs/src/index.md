# Treebars.jl

Treebars records nested Julia work as a progress tree for text, terminal and web views.

```sh
julia -e 'using Pkg; Pkg.add(url="https://github.com/nsiccha/Treebars.jl")'
```

```@example start
using Treebars
values = [2, 4, 6]
result, tree = with_progress(:state, length(values); description="Squares") do p
    result = map(enumerate(values)) do (i, x)
        value = x^2
        update_progress!(p, i)
        value
    end
    result, p
end
println(result)
println(render_text(tree))
```

The result is the squared input; the finished tree records the completed
counter. `with_progress` returns the callback's value, so this example returns
the node alongside the result. Run the installation command in your shell;
the documentation build uses its checkout instead of installing a release.

## Next steps

| Task | Page |
| --- | --- |
| Add counters and nested work | [Instrumentation](instrumentation.md) |
| Represent skipped work and cached results | [Phases](phases.md) |
| Observe work from another process | [Monitoring](monitoring.md) |
| Run a batch with a phase overview | [Batch processing](batch.md) |
| Look up an API | [Core](api.md), [observation](observation.md), [web](web.md) |
