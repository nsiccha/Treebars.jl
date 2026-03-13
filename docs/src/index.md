# Treebars.jl

Tree-structured, nested progress bars for Julia.

Treebars provides a backend-agnostic progress interface built around a tree of `ProgressNode`s.
Each node wraps a backend-specific implementation (Term.jl for terminal, `StateProgress` for web/remote)
and maintains parent-child relationships for hierarchical progress tracking.

## Features

- **Tree-structured progress**: Nested progress bars with parent-child relationships
- **Backend-agnostic**: Interface dispatches to Term.jl, HTMXObjects.jl, or custom backends
- **Keyword-argument labels**: `update_progress!(p, i; ess="pending...", divergent="0/10")` creates sub-labels automatically
- **`@progress` macro**: Automatic progress wrapping for `for` loops
- **Thread-safe**: `StateProgress` backend uses locks for concurrent access
- **WarmupHMC integration**: Drop-in replacement for WarmupHMC's progress infrastructure

## Quick start

```julia
using Treebars, Term

# Simple for-loop progress
Treebars.BACKEND[] = :term
@progress for i in 1:100
    sleep(0.01)
end

# Manual progress with labels
with_progress(:term, 10; description="MCMC") do p
    for i in 1:10
        update_progress!(p, i; ess="pending...", divergent="$i out of 10")
        sleep(0.1)
    end
end
```
