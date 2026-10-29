# ──────────────────────────────────────────────────────────────────────────────
# Snapshot files — follow a running tree from another process
#
# A headless run (a script under a compute token, a fit on a fleet host) has no
# browser and often no terminal, so its tree is invisible until the run ends.
# `snapshot_progress` keeps the `render_text` of a tree in a file that any shell
# can read while the run goes on. The file is replaced whole (temp file +
# rename, so a reader never sees a half-written one) and never appended to: its
# size follows the tree, not the length of the run.
#
# Writes come from two places, at most one per `interval` between them:
# - a background task, which keeps the file current while nothing changes;
# - the thread that changes a node (one is created, starts, ends, counts or
#   gets a message) once the last write is `interval` old. A run whose threads
#   are all busy computing never gets to run the background task, and without
#   this its file would stay at the first write until the run ends.
# ──────────────────────────────────────────────────────────────────────────────

"""
    ProgressSnapshot

A live snapshot file opened by [`snapshot_progress`](@ref). `close` it to write
the final snapshot and stop updating the file; `isopen` tells whether it is
still being updated.
"""
mutable struct ProgressSnapshot
    const node::ProgressNode
    const path::String
    const tmp::String
    const interval::Float64
    const interval_ns::UInt64
    const phase_overview::Union{Bool,Symbol}
    # Held while writing; a changing thread only `trylock`s it, so it never
    # waits for another thread's write.
    const lock::ReentrantLock
    const wake::Base.Event
    @atomic last_ns::UInt64
    @atomic open::Bool
end

# The open snapshots, replaced (never mutated) under `lock`, so the change hook
# reads them with one atomic load and no lock.
mutable struct _SnapshotRegistry
    @atomic open::Vector{ProgressSnapshot}
    const lock::ReentrantLock
end
const _SNAPSHOTS = _SnapshotRegistry(ProgressSnapshot[], ReentrantLock())
# Names each snapshot's temp file. A counter, not `rand`: drawing from the
# task's RNG would change the random numbers the run being watched draws next.
const _SNAPSHOT_IDS = Threads.Atomic{Int}(0)

_register!(s::ProgressSnapshot) = lock(_SNAPSHOTS.lock) do
    @atomic _SNAPSHOTS.open = vcat(_SNAPSHOTS.open, s)
end
function _unregister!(s::ProgressSnapshot)
    @atomic s.open = false
    lock(_SNAPSHOTS.lock) do
        @atomic _SNAPSHOTS.open = filter(!=(s), _SNAPSHOTS.open)
    end
    nothing
end

# Called after every change to a tree, outside any node lock: rendering takes
# node locks one at a time, so a caller holding one could deadlock against a
# thread rendering. With no snapshot open this is one atomic load.
@inline function _snapshot_changed()
    open = @atomic _SNAPSHOTS.open
    isempty(open) || _write_due_snapshots(open)
    nothing
end

@noinline function _write_due_snapshots(open)
    t = time_ns()
    for s in open
        _is_due(s, t) || continue
        # Another thread writing this snapshot right now writes this change too.
        trylock(s.lock) || continue
        try
            (@atomic s.open) && _is_due(s, time_ns()) && _write_or_stop(s, "live")
        finally
            unlock(s.lock)
        end
    end
end

# The next write is due once `interval` has passed since the last one. Added,
# not subtracted: another thread may have written after `t` was read.
_is_due(s::ProgressSnapshot, t) = t >= (@atomic s.last_ns) + s.interval_ns

function _snapshot_header(s::ProgressSnapshot, state)
    t = time()
    stamp = Dates.format(Dates.unix2datetime(floor(t)), "yyyy-mm-ddTHH:MM:SS")
    header = "treebars snapshot · $state · pid $(getpid()) on $(gethostname()) · " *
        "written $(stamp)Z (unix $(floor(Int, t)))"
    state == "live" ? header * " · every $(_seconds_text(s.interval))s" : header
end

_seconds_text(x) = isinteger(x) ? string(Int(x)) : string(x)

function _write_snapshot(s::ProgressSnapshot, state)
    text = render_text(s.node; phase_overview=s.phase_overview)
    open(s.tmp, "w") do io
        println(io, _snapshot_header(s, state))
        println(io, text)
    end
    _replace_file(s.tmp, s.path)
    @atomic s.last_ns = time_ns()
    nothing
end

# rename(2) replaces the old file in one step. `Base.Filesystem.rename` would
# fall back to a copy that a reader can catch half-written. On Windows the
# rename fails while a reader has the file open; a reader holds it for
# milliseconds, so a few tries get past it.
function _replace_file(tmp, path)
    tries = Sys.iswindows() ? 5 : 1
    for attempt in 1:tries
        err = ccall(:jl_fs_rename, Int32, (Cstring, Cstring), tmp, path)
        err == 0 && return nothing
        attempt == tries && throw(Base.IOError("could not replace $(repr(path)) with $(repr(tmp))", err))
        sleep(0.02)
    end
end

# After the first write a failure stops the snapshot rather than the run it
# watches: the file only reports on the work, and a full disk should not end a
# fit. It is logged as an error once, naming the file.
function _write_or_stop(s::ProgressSnapshot, state)
    try
        _write_snapshot(s, state)
    catch err
        _unregister!(s)
        rm(s.tmp; force=true)
        @error "Treebars could not write the progress snapshot $(s.path); it is no longer updated" exception=(err, catch_backtrace())
    end
    nothing
end

function _snapshot_loop(s::ProgressSnapshot)
    while @atomic s.open
        wait_s = (signed((@atomic s.last_ns) + s.interval_ns) - signed(time_ns())) / 1e9
        if wait_s > 0
            timer = Timer(_ -> notify(s.wake), wait_s)
            try
                wait(s.wake)
            finally
                close(timer)
            end
            continue
        end
        lock(s.lock) do
            (@atomic s.open) && _is_due(s, time_ns()) && _write_or_stop(s, "live")
        end
    end
end

"""
    snapshot_progress(node, path; interval=2, phase_overview=false) -> ProgressSnapshot
    snapshot_progress(f, node, path; interval=2, phase_overview=false)

Keep a text snapshot of `node`'s progress tree in the file `path` while a run
goes on, so another process can follow it: `cat path` from any shell, or
`treebars watch path` (the `bin/treebars` script in the package). Meant for
headless runs (a script under a compute token, a fit on a remote host) that
have no browser and no terminal to show the tree.

```julia
snapshot_progress(app.__status__, "fit.progress") do
    app.sample()
end
```

```
treebars snapshot · live · pid 4242 on gordito · written 2026-10-29T18:45:02Z (unix 1793299502) · every 2s
▶ Sampling [3m 12s]
├─ ✓ Prepare model [41s]
└─ ▶ Warmup (812/1000) [2m 31s] · ETA ~35s
```

The first line says whether the run is still writing the file (`live`) or has
closed it (`final`), which process wrote it, and when, in UTC. The rest is
exactly what [`render_text`](@ref)`(node; phase_overview)` returns: the whole
current tree, every node included.

- **Bounded.** Each write replaces the whole file (a temp file in the same
  directory, then a rename), so a reader never sees a half-written file and
  the file never grows with the length of the run, only with the tree.
- **When it is written.** Once when the snapshot opens (a path that cannot be
  written throws here, before any work runs), then at most once per `interval`
  seconds while the run goes on: by a background task, and by whichever
  thread changes the tree (a node is created, starts, ends, counts or gets a
  message) once the last write is `interval` old. So a run whose threads are
  all busy still updates the file whenever its tree changes. With every
  thread busy and nothing changing, the file is written again at the next
  change; start Julia with an interactive thread (`julia -t auto,1`) for
  writes every `interval` regardless.
- **Final.** `close(snapshot)` (the do-block form does this when `f` returns
  or throws) writes the final snapshot, marked `final`. Snapshots still open
  when Julia exits are closed then. A run killed outright leaves its last
  `live` snapshot behind, and the file's age tells a reader it stopped.
- **Errors.** After the first write, a write that fails (a full disk, a
  removed directory) is logged as an error and stops the snapshot; the run
  itself carries on.

Each write costs one `render_text` of the tree. Transient nodes that finished
have left the tree, as they have in every view of it; pass
`phase_overview=true` (or `:top`, `:collapsed`) to add the phase counts that
keep them, as [`render_text`](@ref) does.

The do-block form runs `f()` with the snapshot open and returns its value.
`node === nothing` (progress disabled) writes no file: the handle form returns
`nothing` and the do-block form just runs `f()`.
"""
function snapshot_progress(node::ProgressNode, path::AbstractString;
        interval::Real=2, phase_overview::Union{Bool,Symbol}=false)
    interval > 0 || throw(ArgumentError("snapshot_progress interval must be positive, got $interval"))
    path = abspath(path)
    tmp = joinpath(dirname(path), ".$(basename(path)).$(getpid())-$(Threads.atomic_add!(_SNAPSHOT_IDS, 1)).tmp")
    s = ProgressSnapshot(node, path, tmp, Float64(interval), round(UInt64, interval * 1e9),
        phase_overview, ReentrantLock(), Base.Event(true), time_ns(), true)
    _write_snapshot(s, "live")
    _register!(s)
    errormonitor(Threads.@spawn :interactive _snapshot_loop(s))
    s
end
snapshot_progress(::Nothing, path::AbstractString; kwargs...) = nothing

function snapshot_progress(f, node, path::AbstractString; kwargs...)
    s = snapshot_progress(node, path; kwargs...)
    try
        f()
    finally
        isnothing(s) || close(s)
    end
end

function Base.close(s::ProgressSnapshot)
    lock(s.lock) do
        if @atomic s.open
            _unregister!(s)
            _write_or_stop(s, "final")
        end
    end
    notify(s.wake)
    nothing
end
Base.isopen(s::ProgressSnapshot) = @atomic s.open

Base.show(io::IO, s::ProgressSnapshot) =
    print(io, "ProgressSnapshot(", repr(s.path), isopen(s) ? ", live)" : ", closed)")

_close_open_snapshots() = foreach(close, @atomic _SNAPSHOTS.open)
