# Monitoring

Read a state-backed tree during work, save it for another process, or feed its
updates to a replica. These views observe the existing computation; they do
not start a second run.

## Text

Retain the node explicitly. The first print occurs during work; the second
occurs after the wrapper finalizes it.

```@example monitoring
using Treebars
tree = with_progress(:state, 4; description="Worker") do p
    update_progress!(p, 2)
    println(render_text(p))
    update_progress!(p, 4)
    p
end
println(render_text(tree))
```

The state symbol, counter and duration distinguish the observations. An ETA
appears only for a running determinate node with a rate sample between the
initial and final counter positions. Short documentation runs do not provide
useful performance estimates.

## Snapshot files

`snapshot_progress` replaces a text file atomically. Open it inside the work
and close it after the owning wrapper finishes so its final record also
contains the root's terminal state.

```@example monitoring
snapshot_text = mktempdir() do dir
    path = joinpath(dir, "progress.txt")
    snapshot = Ref{Any}(nothing)
    try
        with_progress(:state, 3; description="Saved run") do p
            snapshot[] = snapshot_progress(p, path)
            for i in 1:3
                update_progress!(p, i)
            end
        end
    finally
        isnothing(snapshot[]) || close(snapshot[])
    end
    read(path, String)
end
lines = split(snapshot_text, '\n')
println("Final snapshot: ", occursin(" · final · ", first(lines)))
println(join(lines[2:end], '\n'))
```

The example prints the final flag and tree, omitting machine identity from
the public output. The header identifies the writer, write time in UTC and whether the snapshot
is live or final. That flag describes the snapshot handle, not necessarily
the lifecycle of every node. This example uses a temporary directory that is
removed afterwards; use a persistent path for an external observer.

These shell commands observe an existing file and are not run by the docs
build. The watcher script is distributed in the repository's `bin/` directory.

```sh
cat progress.txt
./bin/treebars watch progress.txt
```

`interval` is a minimum interval between ordinary writes, not a freshness
guarantee. A background task and tree changes trigger writes. If all Julia
threads are busy and the tree does not change, the next write waits for a
scheduling opportunity or a change. An interactive thread, selected with
`julia -t auto,1`, gives the background task a separate place to run. Closing
writes the final snapshot; a killed process may leave an old live record.

## Replicas

A mirror emits `ProgressFrame` values. A replica applies those frames to a
local node that the text and web renderers can read. This in-process example
transfers a completed tree through exactly that frame API; an application
supplies its own transport for a separate process.

```@example monitoring
target = initialize_progress!(:state; description="Replica")
replica = progress_replica(target)
frames = ProgressFrame[]
mirror = mirror_progress(frame -> push!(frames, frame), tree)
try
    flush(mirror)
finally
    close(mirror)
end
for frame in frames
    apply_frame!(replica, frame)
end
@assert is_finished(target)
@assert render_text(target) == render_text(tree)
println("Replica matches source: ", render_text(target) == render_text(tree))
println(render_text(target))
close(replica)
```

Here the replica owns `target`'s state: the final frame supplies its lifecycle
rather than a work wrapper running on the receiver. The first and closing
frames contain the full tree. Applying an already applied frame does not
repeat increments; frames older than the receiver's current sequence are
ignored. Both processes must load the same Treebars version when using Julia
serialization. See [`progress_replica`](@ref) for forwarding interrupt requests.

## Web views

Load HTMXObjects for HTML renderers and HTTP for WebSocket transport. Include
[`htmx_treebar_styles`](@ref) and [`htmx_treebar_script`](@ref) in the host page;
then render the same state tree with [`htmx_render`](@ref). Rendering a fragment
does not schedule work. [`polling_fetchindex`](@ref) observes an HTMXObjects
indexed property; [`ws_progress`](@ref) has distinct observer and producer
forms. Choose the observer form when the job already exists independently of
the connection. The [web reference](web.md) groups these entry points.

[Batch processing](batch.md) shows the work whose tree these views observe.
