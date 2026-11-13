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
    const spin::Threads.SpinLock
    const wake::Base.Event
    @atomic last_ns::UInt64
    @atomic open::Bool
end

# One reference per observed parent edge (plus the root's reference). Shared
# subgraphs stay observed until their last edge goes away. No node pointer is
# retained here, so detached transient work is not kept alive by observation.
mutable struct _SnapshotTrack <: _ProgressTrack
    const snapshot::ProgressSnapshot
    refs::Int # snapshot.spin; children locks serialize adoption and removal
end
_track_owner(t::_SnapshotTrack) = t.snapshot
_snapshot_track_for(node, s) = _find_track(node, s, _SnapshotTrack)
_snapshot_children(node) = node.children isa ThreadsafeSet ? _mirrored_children(node) : collect(node.children)

function _snapshot_append!(s::ProgressSnapshot, node::ProgressNode)
    held = _lock_children(node)
    try
        (@atomic s.open) || return nothing
        t = _snapshot_track_for(node, s)
        if isnothing(t)
            t = _SnapshotTrack(s, 1)
            node.impl isa StateProgress && _add_track!(node.impl, t)
            node.children isa ThreadsafeSet && _add_track!(node.children, t)
            for child in _snapshot_children(node)
                _snapshot_append!(s, child)
            end
        else
            @lock s.spin t.refs += 1
        end
    finally
        _unlock_children(held)
    end
    nothing
end
_snapshot_append!(::ProgressSnapshot, ::Any) = nothing

function _snapshot_remove!(s::ProgressSnapshot, node::ProgressNode)
    held = _lock_children(node)
    try
        t = _snapshot_track_for(node, s)
        isnothing(t) && return nothing
        gone = @lock s.spin (t.refs -= 1; t.refs == 0)
        gone || return nothing
        node.impl isa StateProgress && _remove_track!(node.impl, t)
        node.children isa ThreadsafeSet && _remove_track!(node.children, t)
        for child in _snapshot_children(node)
            _snapshot_remove!(s, child)
        end
    finally
        _unlock_children(held)
    end
    nothing
end
_snapshot_remove!(::ProgressSnapshot, ::Any) = nothing

_tracked_append(t::_SnapshotTrack, x) = _snapshot_append!(t.snapshot, x)
_tracked_remove(t::_SnapshotTrack, x) = _snapshot_remove!(t.snapshot, x)
@inline function _track_changed(t::_SnapshotTrack)
    _track_changed(t, time_ns())
end
@inline function _track_changed(t::_SnapshotTrack, tick::UInt64)
    s = t.snapshot
    _is_due(s, tick) && _write_due_snapshot(s)
    nothing
end

function _unwatch_snapshot(s::ProgressSnapshot)
    seen = Base.IdSet{ProgressNode}()
    stack = ProgressNode[s.node]
    while !isempty(stack)
        node = pop!(stack)
        _first_seen!(seen, node) || continue
        held = _lock_children(node)
        try
            t = _snapshot_track_for(node, s)
            if !isnothing(t)
                node.impl isa StateProgress && _remove_track!(node.impl, t)
                node.children isa ThreadsafeSet && _remove_track!(node.children, t)
            end
            append!(stack, (c for c in _snapshot_children(node) if c isa ProgressNode))
        finally
            _unlock_children(held)
        end
    end
    nothing
end

# The open snapshots for exit-time cleanup only. Counter changes consult the
# tracks on their own node, never this process-wide registry.
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
    _unwatch_snapshot(s)
    lock(_SNAPSHOTS.lock) do
        @atomic _SNAPSHOTS.open = filter(!=(s), _SNAPSHOTS.open)
    end
    notify(s.wake)
    nothing
end

@noinline function _write_due_snapshot(s::ProgressSnapshot)
    # Another thread writing this snapshot right now writes this change too.
    trylock(s.lock) || return nothing
    try
        (@atomic s.open) && _is_due(s, time_ns()) && _write_or_stop(s, "live")
    finally
        unlock(s.lock)
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

Keep a text snapshot in `path`, replacing it atomically. The header records
writer, UTC write time and live/final status; the body is [`render_text`](@ref).
The first write occurs before returning. A background task and node changes
trigger later writes, at most once per `interval` seconds.

The interval is not a freshness guarantee: when all threads are busy and
nothing changes, writing waits for the next change or scheduling opportunity.
An interactive Julia thread lets the background task run independently.
`close(handle)` writes the final snapshot. Open snapshots close at Julia exit;
a killed process may leave an old live record. After the first write, I/O
errors are logged and stop observation without stopping the work.

The do-block calls `f()` and closes on every exit, returning its result.
A final header means observation closed, not that every node finished.
With `node=nothing`, write no file; the do-block still calls `f()`.
"""
function snapshot_progress(node::ProgressNode, path::AbstractString;
        interval::Real=2, phase_overview::Union{Bool,Symbol}=false)
    interval > 0 || throw(ArgumentError("snapshot_progress interval must be positive, got $interval"))
    path = abspath(path)
    tmp = joinpath(dirname(path), ".$(basename(path)).$(getpid())-$(Threads.atomic_add!(_SNAPSHOT_IDS, 1)).tmp")
    s = ProgressSnapshot(node, path, tmp, Float64(interval), round(UInt64, interval * 1e9),
        phase_overview, ReentrantLock(), Threads.SpinLock(), Base.Event(true), time_ns(), true)
    lock(s.lock) do
        try
            _snapshot_append!(s, node)
            _write_snapshot(s, "live")
            _register!(s)
        catch
            _unregister!(s)
            rethrow()
        end
    end
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
