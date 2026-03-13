# Backends

Treebars is backend-agnostic. The progress interface dispatches to backend-specific implementations via Julia's type system.

## Term.jl (`:term`)

Terminal progress bars using [Term.jl](https://github.com/FedeClaworkers/Term.jl).

```julia
using Treebars, Term

p = initialize_progress!(:term; width=120)
```

Features:
- Background render thread for smooth animation
- ETA calculation
- Colored progress bars with completion percentage
- Labeled sub-rows for metadata

Requires `Term` to be loaded (Julia package extension).

## StateProgress (`:state`)

A thread-safe, inspectable progress backend for web/remote/polling use cases.

```julia
p = initialize_progress!(:state; description="My task")
child = initialize_progress!(p, 100; description="Step 1")
update_progress!(child, 50)

# Inspect state
child.impl.i        # 50
child.impl.N        # 100
child.impl.running  # true
child.impl.message  # ""
```

`StateProgress` stores all state in mutable fields protected by a `ReentrantLock`, making it suitable for:
- Web apps that poll progress via HTTP
- Remote/distributed progress tracking
- Any scenario where progress state needs to be read from a different thread

## HTMXObjects.jl

When `HTMXObjects` is loaded, `StateProgress` nodes can be rendered as HTML:

```julia
using Treebars, HTMXObjects

root = initialize_progress!(:state; description="Fitting")
job = initialize_progress!(root, 100; description="Chain 1")
update_progress!(job, 42)

html = htmx_render(root)  # Returns HTMX Node tree
```

The rendered HTML uses `<progress>` elements and can be served via HTMX polling:

```julia
@htmx struct MyApp
    req = nothing
    progress_root = initialize_progress!(:state; description="Fitting")
    @get progress_view = htmx_render(progress_root)
end
```

## Custom backends

Implement the progress interface for your own types:

```julia
struct MyProgress
    # your state
end

# Required
Treebars.initialize_progress!(::Val{:mybackend}; kwargs...) = ProgressNode(MyProgress(), ...)
Treebars.initialize_progress!(p::MyProgress, N::Integer; kwargs...) = MyProgress(...)
Treebars.update_progress!(p::MyProgress, i::Integer) = ...
Treebars.update_progress!(p::MyProgress, msg::AbstractString) = ...
Treebars.finalize_progress!(p::MyProgress) = ...

# Optional
Treebars.fail_progress!(p::MyProgress, exception) = ...
```
