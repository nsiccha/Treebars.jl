# ──────────────────────────────────────────────────────────────────────────────
# Progress mirrors — the live tree of another process
#
# Heavy work can run in a worker process while a web page in the UI process
# shows its progress. `mirror_progress` follows a tree in the worker and hands
# its changes, as plain-data frames, to a function the caller supplies (which
# writes them to a socket, a Malt channel, a `Channel`, …).
# `progress_replica` + `apply_frame!` turn those frames back into an ordinary
# `ProgressNode{StateProgress}` tree in the UI process, so every renderer,
# poller and Stop button works on it unchanged.
#
# The producer never walks the tree to find out what changed. A followed node
# carries a `_Track` on its `StateProgress` (state changes) and on its children
# set (structure changes, reported from inside the set's lock, so in the order
# they happened); a change marks the node dirty or queues a structure op, and a
# frame carries exactly the dirty nodes and the queued ops. A frame therefore
# costs what changed, not the size of the tree. With no mirror open, the hooks
# are one atomic load each.
#
# Each changed node is sent as its whole state (not as "one more step"), so
# applying a frame twice changes nothing. The first frame and the closing frame
# carry the whole tree, so a replica ends exactly where the source ended even if
# a frame in between was lost.
# ──────────────────────────────────────────────────────────────────────────────

# Structure ops, `(kind, container, child)` by mirror ids.
const _APPEND = Int8(1)   # `child` was added to `container`'s children
const _REMOVE = Int8(2)   # `child` was removed from `container`'s children
const _FORGET = Int8(3)   # `child` left the mirrored tree; its id is not used again

const _Op = Tuple{Int8,Int,Int}

# One node's membership in one mirror.
mutable struct _Track
    const mirror::Any       # the ProgressMirror
    const id::Int
    const node::ProgressNode
    @atomic dirty::Bool     # queued for the next frame
    @atomic gone::Bool      # left the mirrored tree
    refs::Int               # mirrored children sets that hold the node (1 for the root); guarded by the mirror's `spin`
end

# A node's state in a frame: everything `render_text`, `htmx_render` and the
# lifecycle predicates read, the message as written (a `TreebarNote` stays a
# note, so each page draws it in its own language), both times exactly.
struct _NodeState
    id::Int
    parent::Int                       # the creating parent's id, 0 when it is not mirrored
    state::Bool                       # false: not a StateProgress node (mirrored as a transparent level)
    displayed::Union{Nothing,Bool}
    annotation::Bool
    description::String
    N::Union{Int,Nothing}
    i::Int
    message::Union{String,TreebarNote}
    started_at::Union{DateTime,Nothing}
    finalized_at::Union{DateTime,Nothing}
    failed::Bool
    reused::Bool
    interrupt::Bool
end

# A prepared-phase plan's counts (src/phase_overview.jl), so the replica's
# `phase_overview` counts what the source counts, including transient items
# that already left the tree.
struct _GroupState
    id::Int
    host::Int                         # the node that holds the plan
    ancestor::Int                     # the plan's surviving-owner record, 0 when none
    key::Any
    declarer::Any
    host_label::String
    keys::Tuple
    labels::Vector{Union{Nothing,String}}
    counts::Matrix{Int}
    items::Int
end

"""
    ProgressFrame

One update of a progress tree mirrored with [`mirror_progress`](@ref), for
[`apply_frame!`](@ref) on the other side. Plain data: pass it on as it is, or
through `Serialization` (both processes load Treebars, same version). Its
fields are not part of the API.
"""
struct ProgressFrame
    source::UInt64                    # which mirror sent it
    seq::Int                          # 1, 2, … in the order they were sent
    full::Bool                        # carries the whole tree
    final::Bool                       # the last frame: the mirror closed
    nodes::Vector{_NodeState}
    ops::Vector{_Op}                  # delta frames: structure changes, in order
    children::Vector{Pair{Int,Vector{Int}}}   # full frames: every node's mirrored children, in order
    groups::Vector{_GroupState}
    group_order::Vector{Pair{Int,Vector{Int}}}  # node id => its plans' ids, in the node's order
end

Base.show(io::IO, f::ProgressFrame) = print(io, "ProgressFrame(#", f.seq,
    f.final ? ", final" : f.full ? ", full" : "", ", ", length(f.nodes), " nodes, ",
    f.full ? "$(length(f.children)) child lists" : "$(length(f.ops)) ops", ", ",
    length(f.groups), " plans)")

"""
    ProgressMirror

A progress tree followed by [`mirror_progress`](@ref). `close` it to send the
final frame and stop following the tree; `isopen` tells whether it is still
sending; `flush` sends pending changes now.
"""
mutable struct ProgressMirror
    const root::ProgressNode
    const send::Any
    const interval::Float64
    const interval_ns::UInt64
    const source::UInt64
    # Held while a frame is built and sent; a changing thread only `trylock`s
    # it, so threads never wait for each other's frames.
    const lock::ReentrantLock
    # Guards the queues and the id table. Innermost: never held while taking
    # another lock, so the structure hooks may take it inside a children lock.
    const spin::Threads.SpinLock
    const wake::Base.Event
    @atomic last_ns::UInt64
    @atomic open::Bool
    @atomic pending::Bool             # something is queued for the next frame
    seq::Int                          # `lock`
    next_id::Int                      # `spin`
    ops::Vector{_Op}                  # `spin`
    dirty::Vector{_Track}             # `spin`
    const tracks::Dict{Int,_Track}    # `spin`
    const group_ids::IdDict{_PhaseGroup,Int}    # `lock`, like the three below
    const group_host::Dict{Int,Int}
    const group_sent::Dict{Int,Any}
    const host_groups::Dict{Int,Vector{Int}}
end

const _MIRROR_IDS = Threads.Atomic{Int}(0)
# Tells one mirror's frames from another's. Not `rand`: drawing from the task's
# RNG would change the random numbers the mirrored run draws next.
_mirror_source() = hash((getpid(), time_ns(), Threads.atomic_add!(_MIRROR_IDS, 1)))

# ── tracking ─────────────────────────────────────────────────────────────────

# A node's tracks (one per mirror following it): `nothing`, one `_Track`, or a
# vector of them, replaced (never mutated) so the hooks read it with one load.
_tracks_with(old, t) = isnothing(old) ? t : old isa _Track ? _Track[old, t] : vcat(old, t)
function _tracks_without(old, t)
    old === t && return nothing
    old isa Vector || return old
    rest = filter(x -> x !== t, old)
    length(rest) == 1 ? only(rest) : rest
end
function _add_track!(holder, t)
    old = @atomic holder.track
    while true
        res = @atomicreplace holder.track old => _tracks_with(old, t)
        res.success && return nothing
        old = res.old
    end
end
function _remove_track!(holder, t)
    old = @atomic holder.track
    while true
        res = @atomicreplace holder.track old => _tracks_without(old, t)
        res.success && return nothing
        old = res.old
    end
end

_node_tracks(node::ProgressNode{<:StateProgress}) = @atomic node.impl.track
_node_tracks(node::ProgressNode) = node.children isa ThreadsafeSet ? (@atomic node.children.track) : nothing

function _track_for(node::ProgressNode, m)
    tracks = _node_tracks(node)
    tracks isa _Track && return tracks.mirror === m ? tracks : nothing
    isnothing(tracks) && return nothing
    for t in tracks
        t.mirror === m && return t
    end
    nothing
end

_children_lock(node) = node.children isa ThreadsafeSet ? node.children.lock : nothing
_lock_children(node) = (l = _children_lock(node); isnothing(l) || lock(l); l)
_unlock_children(l) = isnothing(l) || unlock(l)

# `x` was added to the children of `c.node`; called inside that children lock.
# Holding `x`'s own children lock while deciding makes one id per node and
# mirror even when two threads attach `x` at once, and keeps a concurrent
# change below `x` out until `x` is tracked. Locks are taken parent before
# child only, so this cannot deadlock against another hook.
function _mirror_append!(m::ProgressMirror, c::_Track, x::ProgressNode)
    (@atomic m.open) || return nothing
    held = _lock_children(x)
    try
        t = _track_for(x, m)
        if isnothing(t)
            _adopt!(m, x, c.id)
        else
            @lock m.spin begin
                t.refs += 1
                push!(m.ops, (_APPEND, c.id, t.id))
            end
        end
    finally
        _unlock_children(held)
    end
    _pending!(m)
end
_mirror_append!(::ProgressMirror, ::_Track, ::Any) = nothing

# Start following `node` (its children lock held by the caller, when it has
# one) and everything below it.
function _adopt!(m::ProgressMirror, node::ProgressNode, container::Int)
    t = @lock m.spin begin
        t = _Track(m, (m.next_id += 1), node, true, false, 1)
        m.tracks[t.id] = t
        container == 0 || push!(m.ops, (_APPEND, container, t.id))
        push!(m.dirty, t)
        t
    end
    node.impl isa StateProgress && _add_track!(node.impl, t)
    if node.children isa ThreadsafeSet
        _add_track!(node.children, t)
        for child in node.children.inner
            _mirror_append!(m, t, child)
        end
    end
    t
end

# `x` was removed from the children of `c.node`; called inside that lock.
function _mirror_remove!(m::ProgressMirror, c::_Track, x::ProgressNode)
    (@atomic m.open) || return nothing
    t = _track_for(x, m)
    isnothing(t) && return nothing
    gone = @lock m.spin begin
        push!(m.ops, (_REMOVE, c.id, t.id))
        t.refs -= 1
        t.refs == 0
    end
    gone && _forget!(m, t)
    _pending!(m)
end
_mirror_remove!(::ProgressMirror, ::_Track, ::Any) = nothing

# `t.node` is no longer in the mirrored tree: stop following it, and every node
# below it that no other mirrored node holds.
function _forget!(m::ProgressMirror, t::_Track)
    node = t.node
    held = _lock_children(node)
    try
        @atomic t.gone = true
        node.impl isa StateProgress && _remove_track!(node.impl, t)
        @lock m.spin begin
            delete!(m.tracks, t.id)
            push!(m.ops, (_FORGET, 0, t.id))
        end
        node.children isa ThreadsafeSet || return nothing
        _remove_track!(node.children, t)
        for child in node.children.inner
            child isa ProgressNode || continue
            ct = _track_for(child, m)
            isnothing(ct) && continue
            gone = @lock m.spin (ct.refs -= 1; ct.refs == 0)
            gone && _forget!(m, ct)
        end
    finally
        _unlock_children(held)
    end
    nothing
end

# The children-set hooks (src/threadsafe.jl), inside the set's lock.
_tracked_append(t::_Track, x) = _mirror_append!(t.mirror::ProgressMirror, t, x)
_tracked_append(ts::Vector, x) = foreach(t -> _tracked_append(t, x), ts)
_tracked_remove(t::_Track, x) = _mirror_remove!(t.mirror::ProgressMirror, t, x)
_tracked_remove(ts::Vector, x) = foreach(t -> _tracked_remove(t, x), ts)

# The state hook: runs after every change to a node's state, outside its lock
# (src/implementation.jl). With nothing open it is two atomic loads.
@inline function _progress_changed(sp::StateProgress)
    tracks = @atomic :acquire sp.track
    isnothing(tracks) || _tracks_changed(tracks)
    _snapshot_changed()
end
_progress_changed(::Any) = _snapshot_changed()

_tracks_changed(t::_Track) = _track_changed(t)
_tracks_changed(ts::Vector) = foreach(_track_changed, ts)

@inline function _track_changed(t::_Track)
    m = t.mirror::ProgressMirror
    (@atomic :acquire t.dirty) || _mark_dirty!(m, t)
    # Like a snapshot: the changing thread sends once the last frame is
    # `interval` old, so a run whose threads are all busy still sends.
    time_ns() >= (@atomic m.last_ns) + m.interval_ns && _send_due(m)
    nothing
end

@noinline function _mark_dirty!(m::ProgressMirror, t::_Track)
    (@atomicswap t.dirty = true) && return nothing
    @lock m.spin push!(m.dirty, t)
    _pending!(m)
end

_pending!(m::ProgressMirror) = ((@atomicswap m.pending = true) || notify(m.wake); nothing)

@noinline function _send_due(m::ProgressMirror)
    (@atomic m.open) && (@atomic m.pending) || return nothing
    # Another thread sending right now sends this change too.
    trylock(m.lock) || return nothing
    try
        (@atomic m.open) && (@atomic m.pending) &&
            time_ns() >= (@atomic m.last_ns) + m.interval_ns && _send_or_stop(m)
    finally
        unlock(m.lock)
    end
    nothing
end

# ── frames ───────────────────────────────────────────────────────────────────

function _node_state(m::ProgressMirror, t::_Track)
    node = t.node
    p = node.parent
    pt = t.id == 1 || isnothing(p) ? nothing : _track_for(p, m)
    parent = isnothing(pt) ? 0 : pt.id
    pref = _display_pref(node)
    displayed = pref isa Bool ? pref : nothing
    annotation = get(node.meta, :annotation, false) === true
    interrupt = node.interrupt[]
    sp = node.impl
    sp isa StateProgress || return _NodeState(t.id, parent, false, false, false, "", nothing, 0, "",
        nothing, nothing, false, false, interrupt)
    lock(sp.lock) do
        _NodeState(t.id, parent, true, displayed, annotation, sp.description, sp.N, sp.i, sp.message,
            sp.started_at, sp.finalized_at, sp.failed, sp.reused, interrupt)
    end
end

# Builds the next frame; `m.lock` is held.
function _build_frame(m::ProgressMirror; full::Bool=false, final::Bool=false)
    ops, dirty = @lock m.spin begin
        @atomic m.pending = false
        queued = (m.ops, m.dirty)
        m.ops = _Op[]
        m.dirty = _Track[]
        queued
    end
    # Cleared before the state is read: a change after this point queues the
    # node again, so it is never lost between two frames.
    for t in dirty
        @atomic t.dirty = false
    end
    m.seq += 1
    full && return _full_frame(m, final)
    nodes = _NodeState[]
    plans = Tuple{_PhaseGroup,ProgressNode}[]
    for t in dirty
        # A transient item that finished and left the tree since the last frame
        # still moved its plan's counts on the node that keeps them.
        _member_plans!(plans, t)
        (@atomic t.gone) && continue
        push!(nodes, _node_state(m, t))
        _hosted_plans!(plans, t.node)
    end
    groups, order = _group_states(m, plans, false)
    ProgressFrame(m.source, m.seq, false, final, nodes, ops, Pair{Int,Vector{Int}}[], groups, order)
end

# A phase node's state counts in its plan and in the plan's surviving-owner
# record. The mirrored root's own plan belongs to the tree around it, which the
# replica does not mirror.
function _member_plans!(plans, t::_Track)
    t.id == 1 && return plans
    sp = t.node.impl
    sp isa StateProgress || return plans
    member = sp.phase_member
    isnothing(member) && return plans
    group = member.group
    while !isnothing(group)
        push!(plans, (group, t.node))
        group = group.ancestor
    end
    plans
end

function _hosted_plans!(plans, node::ProgressNode)
    for group in _phase_group_records(node)
        push!(plans, (group, node))
        ancestor = group.ancestor
        while !isnothing(ancestor)
            push!(plans, (ancestor, node))
            ancestor = ancestor.ancestor
        end
    end
    plans
end

function _full_frame(m::ProgressMirror, final::Bool)
    nodes = _NodeState[]
    children = Pair{Int,Vector{Int}}[]
    plans = Tuple{_PhaseGroup,ProgressNode}[]
    root = _track_for(m.root, m)
    seen = Set{Int}()
    isnothing(root) || _collect_full!(nodes, children, plans, seen, m, root)
    groups, order = _group_states(m, plans, true)
    ProgressFrame(m.source, m.seq, true, final, nodes, _Op[], children, groups, order)
end

function _collect_full!(nodes, children, plans, seen, m, t::_Track)
    t.id in seen && return nothing
    push!(seen, t.id)
    push!(nodes, _node_state(m, t))
    node = t.node
    _hosted_plans!(plans, node)
    kids = Tuple{ProgressNode,_Track}[]
    if node.children isa ThreadsafeSet
        for child in collect(node.children)
            child isa ProgressNode || continue
            ct = _track_for(child, m)
            isnothing(ct) || push!(kids, (child, ct))
        end
    end
    push!(children, t.id => Int[ct.id for (_, ct) in kids])
    for (_, ct) in kids
        _collect_full!(nodes, children, plans, seen, m, ct)
    end
end

# The node that holds `group`: the first one at or above `from` whose plans
# include it. A plan held above the mirrored root goes to the root; one held by
# a node that has left the mirrored tree (a finished transient item) is gone
# with it: 0.
function _group_host(m::ProgressMirror, group::_PhaseGroup, from::ProgressNode)
    node = from
    inside = true
    while node isa ProgressNode
        if group in _phase_group_records(node)
            t = _track_for(node, m)
            return isnothing(t) ? (inside ? 0 : 1) : t.id
        end
        node === m.root && (inside = false)
        node = node.parent
    end
    0
end

# The plans among `plans` that are new or changed since they were last sent
# (all of them for a full frame), and the plan order of every node that holds
# a new one.
function _group_states(m::ProgressMirror, plans, full::Bool)
    hosts = Set{Int}()
    live = Tuple{_PhaseGroup,Int}[]
    seen = Base.IdSet{_PhaseGroup}()
    for (group, from) in plans
        group in seen && continue
        push!(seen, group)
        id = get(m.group_ids, group, 0)
        if id == 0
            host = _group_host(m, group, from)
            host == 0 && continue
            id = m.group_ids[group] = length(m.group_ids) + 1
            m.group_host[id] = host
            push!(get!(Vector{Int}, m.host_groups, host), id)
            push!(hosts, host)
        end
        full && push!(hosts, m.group_host[id])
        push!(live, (group, id))
    end
    groups = _GroupState[]
    for (group, id) in live
        state = lock(group.lock) do
            (copy(group.counts), group.items, copy(group.labels))
        end
        !full && get(m.group_sent, id, nothing) == state && continue
        m.group_sent[id] = state
        ancestor = isnothing(group.ancestor) ? 0 : get(m.group_ids, group.ancestor, 0)
        push!(groups, _GroupState(id, m.group_host[id], ancestor, group.key, group.declarer, group.host,
            group.keys, state[3], state[1], state[2]))
    end
    order = Pair{Int,Vector{Int}}[host => _host_order(m, host) for host in sort!(collect(hosts))]
    groups, order
end

# The plans a mirrored node holds, in the order it holds them; plans held
# above the root come after the root's own.
function _host_order(m::ProgressMirror, host::Int)
    ids = get(m.host_groups, host, Int[])
    t = @lock m.spin get(m.tracks, host, nothing)
    isnothing(t) && return copy(ids)
    own = Int[]
    for group in _phase_group_records(t.node)
        id = get(m.group_ids, group, 0)
        id != 0 && id in ids && push!(own, id)
    end
    vcat(own, filter(id -> !(id in own), ids))
end

# ── sending ──────────────────────────────────────────────────────────────────

# `m.lock` is held. After the opening frame a failing `send` stops the mirror
# rather than the run it follows; it is logged once.
function _send_or_stop(m::ProgressMirror)
    frame = _build_frame(m)
    try
        m.send(frame)
        @atomic m.last_ns = time_ns()
    catch err
        _stop!(m)
        @error "Treebars could not send a progress frame; the mirror of $(repr(_description(m.root))) is closed" exception=(err, catch_backtrace())
    end
    nothing
end

_description(node::ProgressNode{<:StateProgress}) = lock(() -> node.impl.description, node.impl.lock)
_description(node::ProgressNode) = string(typeof(node.impl))

function _stop!(m::ProgressMirror)
    @atomic m.open = false
    tracks = @lock m.spin collect(values(m.tracks))
    for t in tracks
        @atomic t.gone = true
        t.node.impl isa StateProgress && _remove_track!(t.node.impl, t)
        t.node.children isa ThreadsafeSet && _remove_track!(t.node.children, t)
    end
    @lock m.spin begin
        empty!(m.tracks)
        empty!(m.ops)
        empty!(m.dirty)
    end
    notify(m.wake)
    nothing
end

function _mirror_loop(m::ProgressMirror)
    while @atomic m.open
        if !(@atomic m.pending)
            wait(m.wake)
            continue
        end
        wait_s = (signed((@atomic m.last_ns) + m.interval_ns) - signed(time_ns())) / 1e9
        if wait_s > 0
            timer = Timer(_ -> notify(m.wake), wait_s)
            try
                wait(m.wake)
            finally
                close(timer)
            end
            continue
        end
        lock(m.lock) do
            (@atomic m.open) && (@atomic m.pending) && _send_or_stop(m)
        end
    end
end

"""
    mirror_progress(send, node; interval=0.05) -> ProgressMirror
    mirror_progress(f, send, node; interval=0.05)

Follow `node`'s progress tree and pass its changes to `send(frame)` as
[`ProgressFrame`](@ref)s, so another process can show the tree live with
[`progress_replica`](@ref) and [`apply_frame!`](@ref). `send` carries a frame
to that process: a write to a socket or a worker channel, or a `put!` into a
`Channel` within one process.

```julia
# in the worker
mirror_progress(frame -> put!(to_ui, frame), node) do
    fit(model; progress = node)
end
# in the UI process
replica = progress_replica(pending_node; on_interrupt = id -> put!(to_worker, id))
for frame in from_worker
    apply_frame!(replica, frame)
end
```

- **What is sent.** The first frame, sent before this returns, holds the whole
  tree: every node, nothing capped. Each later frame holds what changed since
  the one before: the nodes whose state changed (each with its whole state,
  so applying a frame twice changes nothing) and the children added or
  removed, in the order they happened. Notes stay notes, so each page draws
  them in its own language; both timestamps travel exactly; prepared-phase
  plans travel with their counts, so `phase_overview` counts the same on the
  replica.
- **When.** At most one frame per `interval` seconds, while something
  changes: sent by whichever thread changes the tree once the last frame is
  `interval` old, or by a background task. So a worker whose threads are all
  busy computing still sends. `interval=0` sends every change at once.
  `flush(mirror)` sends what is pending now.
- **Closing.** `close(mirror)` sends the final frame, again the whole tree, and
  stops following the tree; the do-block form closes it when `f` returns or
  throws. A replica that missed a frame in between ends exactly at the
  source's final state.
- **Cost.** A frame costs what changed, not the size of the tree. With a mirror
  open, a `@progress for` tick costs about what it costs with a
  [`snapshot_progress`](@ref) file open; with none open, nothing measurable.
- **`send`** is called with no lock of the tree held and never twice at once
  for one mirror. If it throws on the first frame, `mirror_progress` throws;
  later, a failing `send` is logged once as an error and closes the mirror,
  while the run itself carries on.
- **Stop.** A replica's `on_interrupt` hands over the id of the node a viewer
  asked to stop; `request_interrupt!(mirror, id)` passes the request on to
  that node here.

`node === nothing` (progress disabled) mirrors nothing: the handle form returns
`nothing`, and the do-block form just runs `f()`.
"""
function mirror_progress(send, node::ProgressNode; interval::Real=0.05)
    interval >= 0 || throw(ArgumentError("mirror_progress interval must not be negative, got $interval"))
    m = ProgressMirror(node, send, Float64(interval), round(UInt64, interval * 1e9), _mirror_source(),
        ReentrantLock(), Threads.SpinLock(), Base.Event(true), UInt64(0), true, false, 0, 0,
        _Op[], _Track[], Dict{Int,_Track}(), IdDict{_PhaseGroup,Int}(), Dict{Int,Int}(),
        Dict{Int,Any}(), Dict{Int,Vector{Int}}())
    lock(m.lock) do
        held = _lock_children(node)
        try
            _adopt!(m, node, 0)
        finally
            _unlock_children(held)
        end
        try
            m.send(_build_frame(m; full=true))
            @atomic m.last_ns = time_ns()
        catch
            _stop!(m)
            rethrow()
        end
    end
    errormonitor(Threads.@spawn :interactive _mirror_loop(m))
    m
end
mirror_progress(send, ::Nothing; kwargs...) = nothing

function mirror_progress(f, send, node; kwargs...)
    m = mirror_progress(send, node; kwargs...)
    try
        f()
    finally
        isnothing(m) || close(m)
    end
end

function Base.close(m::ProgressMirror)
    lock(m.lock) do
        (@atomic m.open) || return nothing
        frame = _build_frame(m; full=true, final=true)
        _stop!(m)
        try
            m.send(frame)
        catch err
            @error "Treebars could not send the final progress frame of $(repr(_description(m.root)))" exception=(err, catch_backtrace())
        end
    end
    nothing
end
Base.isopen(m::ProgressMirror) = @atomic m.open
function Base.flush(m::ProgressMirror)
    lock(m.lock) do
        (@atomic m.open) && (@atomic m.pending) && _send_or_stop(m)
    end
    nothing
end
Base.show(io::IO, m::ProgressMirror) =
    print(io, "ProgressMirror(", repr(_description(m.root)), isopen(m) ? ", open)" : ", closed)")

"""
    request_interrupt!(mirror::ProgressMirror, id) -> mirror

Request an interrupt on the node of `mirror`'s tree that has `id` in its
frames: the id a replica's `on_interrupt` handed over (see
[`progress_replica`](@ref)). Unknown ids, such as a node that has since left
the tree, are ignored.
"""
function request_interrupt!(m::ProgressMirror, id::Integer)
    t = @lock m.spin get(m.tracks, Int(id), nothing)
    isnothing(t) || request_interrupt!(t.node)
    m
end

# ── replicas ─────────────────────────────────────────────────────────────────

"""
    ProgressReplica

The receiving end of a mirrored progress tree, made by
[`progress_replica`](@ref) and fed with [`apply_frame!`](@ref).
"""
mutable struct ProgressReplica
    const target::ProgressNode
    const on_interrupt::Any
    const lock::ReentrantLock
    source::UInt64
    seq::Int
    final::Bool
    gaps::Int                         # frames that did not follow the one before
    @atomic root_forwarded::Bool
    const nodes::Dict{Int,ProgressNode}
    const ids::IdDict{ProgressNode,Int}
    const groups::Dict{Int,_PhaseGroup}
end

# Replicas with an `on_interrupt`, replaced (never mutated) under `lock`, so
# `request_interrupt!` reads them with one atomic load.
mutable struct _ReplicaRegistry
    @atomic open::Vector{ProgressReplica}
    const lock::ReentrantLock
end
const _REPLICAS = _ReplicaRegistry(ProgressReplica[], ReentrantLock())

_register!(r::ProgressReplica) = lock(_REPLICAS.lock) do
    @atomic _REPLICAS.open = vcat(_REPLICAS.open, r)
end
_unregister!(r::ProgressReplica) = lock(_REPLICAS.lock) do
    @atomic _REPLICAS.open = filter(!=(r), _REPLICAS.open)
end

"""
    progress_replica(target; on_interrupt=nothing) -> ProgressReplica

Make `target`, an existing `ProgressNode{StateProgress}`, the mirror of a tree
another process follows with [`mirror_progress`](@ref). Pass each frame from
there to [`apply_frame!`](@ref): `target` takes on the source root's state
(label, counter, note, times) and its children are created and updated as the
source's are, as ordinary nodes. Everything that draws or polls a tree
(`htmx_render`, `polling_fetchindex`, `render_text`, `phase_overview`, …) works
on it unchanged, so attaching `target` where the work is read shows the
worker's tree inside the page's own.

`on_interrupt(id)` is called when a viewer asks to stop: on
[`request_interrupt!`](@ref) of a node of the replica (`id` is that node's id
in the frames), or of `target` or one of its ancestors (`id` is the source
root's). Pass `id` to the other process, which calls
`request_interrupt!(mirror, id)`: children the source creates later are then
interrupted too. If an interrupt was already requested on `target` or above,
`on_interrupt` is called at once. Errors it throws are logged.

The replica follows one mirror: frames from another one are ignored, as are
frames older than one already applied and every frame after the final one.
Frames passing a lost one are applied as far as they can be, and the final
frame restores the exact final state. `close(replica)` stops `on_interrupt`
calls (the final frame does so too). Children of `target` that do not come
from the mirror are left alone.
"""
function progress_replica(target::ProgressNode{<:StateProgress}; on_interrupt=nothing)
    r = ProgressReplica(target, on_interrupt, ReentrantLock(), UInt64(0), 0, false, 0, false,
        Dict{Int,ProgressNode}(1 => target), IdDict{ProgressNode,Int}(target => 1), Dict{Int,_PhaseGroup}())
    if !isnothing(on_interrupt)
        _register!(r)
        interrupt_requested(target) && _forward_root!(r)
    end
    r
end

Base.close(r::ProgressReplica) = (_unregister!(r); nothing)
Base.show(io::IO, r::ProgressReplica) = print(io, "ProgressReplica(", repr(_description(r.target)),
    ", frame ", r.seq, r.final ? ", final)" : ")")

# A request on `node` (src/implementation.jl): replicas holding it, or below
# it, pass it on.
function _forward_interrupt(node::ProgressNode)
    replicas = @atomic _REPLICAS.open
    isempty(replicas) && return nothing
    for r in replicas
        id = lock(() -> get(r.ids, node, 0), r.lock)
        if id == 1 || (id == 0 && interrupt_requested(r.target))
            _forward_root!(r)
        elseif id != 0
            _call_on_interrupt(r, id)
        end
    end
    nothing
end

function _forward_root!(r::ProgressReplica)
    (@atomicswap r.root_forwarded = true) && return nothing
    _call_on_interrupt(r, 1)
end

function _call_on_interrupt(r::ProgressReplica, id)
    try
        r.on_interrupt(id)
    catch err
        @error "Treebars: the on_interrupt of the replica $(repr(_description(r.target))) failed" exception=(err, catch_backtrace())
    end
    nothing
end

"""
    apply_frame!(replica, frame) -> Bool

Apply a [`ProgressFrame`](@ref) from [`mirror_progress`](@ref) to the replica
made by [`progress_replica`](@ref). Returns `false` for a frame that was
ignored (from another mirror, older than one already applied, or after the
final frame), `true` otherwise. Safe to call from any thread; frames of one
replica are applied one at a time.
"""
function apply_frame!(r::ProgressReplica, f::ProgressFrame)
    applied = lock(r.lock) do
        r.final && return false
        r.source == 0 && (r.source = f.source)
        f.source == r.source || return false
        f.seq > r.seq || return false
        f.seq == r.seq + 1 || (r.gaps += 1)
        r.seq = f.seq
        _apply_nodes!(r, f.nodes)
        f.full ? _apply_children!(r, f) : _apply_ops!(r, f.ops)
        _apply_groups!(r, f.groups, f.group_order)
        f.final && (r.final = true)
        true
    end
    applied && f.final && close(r)
    applied
end

function _apply_nodes!(r::ProgressReplica, records)
    for rec in records
        node = get(r.nodes, rec.id, nothing)
        if isnothing(node)
            parent = rec.parent == 0 ? nothing : get(r.nodes, rec.parent, nothing)
            # A node of another backend is shown as what it is to the tree: a
            # level whose children are hoisted into its parent's.
            meta = (; propagates=false, transient=false, displayed=rec.state ? rec.displayed : false,
                annotation=rec.annotation)
            node = ProgressNode(StateProgress(; description=rec.description, N=rec.N, pending=true), meta;
                parent, _attach=false)
            r.nodes[rec.id] = node
            r.ids[node] = rec.id
        end
        # Before the state, whose change hook lets a snapshot of this process
        # show the marker.
        rec.interrupt && (node.interrupt[] = true)
        rec.state && _apply_state!(node, rec)
    end
end

function _apply_state!(node::ProgressNode, rec::_NodeState)
    sp = node.impl::StateProgress
    lock(sp.lock) do
        previous = isnothing(sp.phase_member) ? 0 : _phase_state_index(sp)
        sp.description = rec.description
        sp.N = rec.N
        sp.i = rec.i
        sp.message = rec.message
        sp.started_at = rec.started_at
        sp.finalized_at = rec.finalized_at
        sp.failed = rec.failed
        sp.reused = rec.reused
        sp.running = !isnothing(rec.started_at) && isnothing(rec.finalized_at)
        # `target` may be a phase of a plan in this process.
        _record_phase_transition!(sp, previous)
    end
    _progress_changed(sp)
end

function _apply_ops!(r::ProgressReplica, ops)
    for (kind, c, x) in ops
        if kind == _FORGET
            node = pop!(r.nodes, x, nothing)
            isnothing(node) || x == 1 || delete!(r.ids, node)
            continue
        end
        container = get(r.nodes, c, nothing)
        child = get(r.nodes, x, nothing)
        (isnothing(container) || isnothing(child)) && continue
        kind == _APPEND ? push!(container.children, child) : pop!(container.children, child, nothing)
    end
end

# A full frame lists every node and every node's children: the replica becomes
# exactly that, whatever frames it missed.
function _apply_children!(r::ProgressReplica, f::ProgressFrame)
    for (c, ids) in f.children
        container = get(r.nodes, c, nothing)
        isnothing(container) && continue
        want = ProgressNode[r.nodes[id] for id in ids if haskey(r.nodes, id)]
        have = ProgressNode[x for x in collect(container.children) if x isa ProgressNode && haskey(r.ids, x)]
        have == want && continue
        for x in have
            pop!(container.children, x, nothing)
        end
        for x in want
            push!(container.children, x)
        end
    end
    present = Set(rec.id for rec in f.nodes)
    for (id, node) in collect(r.nodes)
        id == 1 || id in present || (delete!(r.nodes, id); delete!(r.ids, node))
    end
end

function _apply_groups!(r::ProgressReplica, groups, order)
    for g in groups
        group = get(r.groups, g.id, nothing)
        if isnothing(group)
            host = get(r.nodes, g.host, nothing)
            isnothing(host) && continue
            group = _PhaseGroup(ReentrantLock(), nothing, g.key, g.declarer, g.host_label, g.keys,
                copy(g.labels), copy(g.counts), g.items)
            r.groups[g.id] = group
            sp = host.impl::StateProgress
            lock(sp.lock) do
                plans = sp.phase_groups
                isnothing(plans) && (plans = sp.phase_groups = OrderedDict{Any,_PhaseGroup}())
                # Never displace a plan of this process's own.
                haskey(plans, g.key) || (plans[g.key] = group)
            end
        else
            lock(group.lock) do
                group.counts .= g.counts
                group.items = g.items
                group.labels .= g.labels
            end
        end
    end
    for g in groups
        g.ancestor == 0 && continue
        group = get(r.groups, g.id, nothing)
        ancestor = get(r.groups, g.ancestor, nothing)
        isnothing(group) || isnothing(ancestor) || (group.ancestor = ancestor)
    end
    for (host_id, ids) in order
        host = get(r.nodes, host_id, nothing)
        isnothing(host) || _order_groups!(r, host, ids)
    end
end

# The host's plans of this process first, then the mirrored ones in the
# source's order.
function _order_groups!(r::ProgressReplica, host::ProgressNode, ids)
    mirrored = Base.IdSet{_PhaseGroup}(values(r.groups))
    sp = host.impl::StateProgress
    lock(sp.lock) do
        plans = sp.phase_groups
        isnothing(plans) && return nothing
        ordered = OrderedDict{Any,_PhaseGroup}()
        for (key, group) in plans
            group in mirrored || (ordered[key] = group)
        end
        for id in ids
            group = get(r.groups, id, nothing)
            isnothing(group) || get(plans, group.key, nothing) !== group || (ordered[group.key] = group)
        end
        for (key, group) in plans
            haskey(ordered, key) || (ordered[key] = group)
        end
        sp.phase_groups = ordered
    end
    nothing
end
