# Usage

## The `@progress` macro

The simplest way to add progress tracking to `for` loops:

```julia
using Treebars, Term

# Set the global backend
Treebars.BACKEND[] = :term

# Single loop
@progress for i in 1:100
    sleep(0.01)
end

# Nested loops (inner loops get transient progress bars)
@progress for i in 1:5
    for j in 1:20
        sleep(0.01)
    end
end
```

You can also pass a progress node directly instead of using the global backend:

```julia
p = initialize_progress!(:term)
@progress p for i in 1:100
    sleep(0.01)
end
finalize_progress!(p)
```

## `with_progress`

For more control, use `with_progress` which handles initialization and cleanup:

```julia
with_progress(:term, 10; description="My task") do p
    for i in 1:10
        update_progress!(p, i)
        sleep(0.1)
    end
end
```

## Labeled sub-progress

Pass keyword arguments to `update_progress!` to create labeled sub-rows:

```julia
with_progress(:term, 100; description="MCMC") do p
    for i in 1:100
        update_progress!(p, i;
            divergent = "$i out of 100",
            ess = "pending...",
            stepsize = "0.1",
        )
        sleep(0.05)
    end
end
```

Each keyword creates a child label row (e.g. `divergent: 5 out of 100`).
Underscores in keyword names are replaced with spaces.

## Manual lifecycle

For full control over the progress lifecycle:

```julia
# Create root
root = initialize_progress!(:term)

# Create a child with N steps
job = initialize_progress!(root, 50; description="Step 1")

# Update
for i in 1:50
    update_progress!(job, i)
end

# Finalize child, then root
finalize_progress!(job)
finalize_progress!(root)
```

## Update patterns

All patterns used by WarmupHMC are supported:

```julia
update_progress!(p, i)              # Set counter to i
update_progress!(p)                 # Increment by 1
update_progress!(p, i; key=val)     # Counter + labels
update_progress!(p, nothing; k=v)   # Labels only (no counter change)
update_progress!(p, "message")      # String message
```

## Disabled progress

Passing `nothing` as the progress backend is a no-op — all functions silently return `nothing`.
This makes it easy to optionally enable progress:

```julia
function my_computation(; progress=nothing)
    with_progress(progress, 100; description="Computing") do p
        for i in 1:100
            update_progress!(p, i)
            # ...
        end
    end
end

# No progress
my_computation()

# With progress
my_computation(progress=:term)
```
