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
mutable struct _Track <: _ProgressTrack
    const mirror::Any       # the ProgressMirror
    const id::Int
    # `nothing` once the node left the mirrored tree: a track still queued for
    # the next frame does not keep a finished node alive.
    @atomic node::Union{Nothing,ProgressNode}
    @atomic dirty::Bool     # queued for the next frame
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
    # Guards the queues. Innermost: never held while taking another lock, so
    # the structure hooks may take it inside a children lock.
    const spin::Threads.SpinLock
    const wake::Base.Event
    @atomic last_ns::UInt64
    @atomic open::Bool
    @atomic pending::Bool             # something is queued for the next frame
    seq::Int                          # `lock`
    next_id::Int                      # `spin`
    ops::Vector{_Op}                  # `spin`
    dirty::Vector{_Track}             # `spin`
    # Plans of nodes that left the tree, with a node to look for their holder
    # from, and the ids of nodes that left holding plans: `spin`.
    left::Vector{Tuple{_PhaseGroup,ProgressNode}}
    left_hosts::Vector{Int}
    # The plans sent so far: `lock`, like the four below.
    next_group::Int
    const group_ids::IdDict{_PhaseGroup,Int}
    const groups::Dict{Int,_PhaseGroup}
    const group_host::Dict{Int,Int}
    const group_sent::Dict{Int,Any}
    const host_groups::Dict{Int,Vector{Int}}
end

const _MIRROR_IDS = Threads.Atomic{Int}(0)
# Tells one mirror's frames from another's. Not `rand`: drawing from the task's
# RNG would change the random numbers the mirrored run draws next.
_mirror_source() = hash((getpid(), time_ns(), Threads.atomic_add!(_MIRROR_IDS, 1)))

# ── tracking ─────────────────────────────────────────────────────────────────

_track_owner(t::_Track) = t.mirror
_track_for(node::ProgressNode, m) = _find_track(node, m, _Track)

# `x` was added to the children of `c`'s node; called inside that children
# lock. Holding `x`'s own children lock while deciding makes one id per node
# and mirror even when two threads attach `x` at once, and keeps a concurrent
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
        t = _Track(m, (m.next_id += 1), node, true, 1)
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

# `x` was removed from the children of `c`'s node; called inside that lock.
function _mirror_remove!(m::ProgressMirror, c::_Track, x::ProgressNode)
    (@atomic m.open) || return nothing
    t = _track_for(x, m)
    isnothing(t) && return nothing
    gone = @lock m.spin begin
        push!(m.ops, (_REMOVE, c.id, t.id))
        _unref!(m, t, x)
    end
    gone && _release!(m, t, x)
    _pending!(m)
end
_mirror_remove!(::ProgressMirror, ::_Track, ::Any) = nothing

# One mirrored children set less holds `node`; `m.spin` is held. When none
# holds it any more it has left the mirrored tree: its id is forgotten, and
# its plan, a transient item's that finished, still moved counts on the node
# that keeps them (found from its parent).
function _unref!(m::ProgressMirror, t::_Track, node::ProgressNode)
    t.refs -= 1
    t.refs == 0 || return false
    push!(m.ops, (_FORGET, 0, t.id))
    sp = node.impl
    if sp isa StateProgress
        member = sp.phase_member
        isnothing(member) || push!(m.left, (member.group, something(node.parent, node)))
        isnothing(sp.phase_groups) || push!(m.left_hosts, t.id)
    end
    true
end

# Stop following `node`, which left the mirrored tree, and every node below it
# that no other mirrored node holds. The track lets go of the node, so a
# finished transient item is not kept alive by a frame still to be sent. A
# child added concurrently is either seen here (it was tracked before the
# children's track went) or never reported (after it).
function _release!(m::ProgressMirror, t::_Track, node::ProgressNode)
    @atomic t.node = nothing
    node.impl isa StateProgress && _remove_track!(node.impl, t)
    node.children isa ThreadsafeSet || return nothing
    _remove_track!(node.children, t)
    for child in _mirrored_children(node)
        child isa ProgressNode || continue
        ct = _track_for(child, m)
        isnothing(ct) && continue
        gone = @lock m.spin _unref!(m, ct, child)
        gone && _release!(m, ct, child)
    end
    nothing
end

# The children-set hooks (src/threadsafe.jl), inside the set's lock.
_tracked_append(t::_Track, x) = _mirror_append!(t.mirror::ProgressMirror, t, x)
_tracked_remove(t::_Track, x) = _mirror_remove!(t.mirror::ProgressMirror, t, x)

@inline function _track_changed(t::_Track)
    _track_changed(t, time_ns())
end
@inline function _track_changed(t::_Track, tick::UInt64)
    m = t.mirror::ProgressMirror
    (@atomic :acquire t.dirty) || _mark_dirty!(m, t)
    # Like a snapshot: the changing thread sends once the last frame is
    # `interval` old, so a run whose threads are all busy still sends.
    tick >= (@atomic m.last_ns) + m.interval_ns && _send_due(m)
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

# Every node the mirror follows, depth first from the root, each once.
function _foreach_track(f, m::ProgressMirror)
    root = _track_for(m.root, m)
    isnothing(root) && return nothing
    seen = Set{Int}()
    stack = Tuple{_Track,ProgressNode}[(root, m.root)]
    while !isempty(stack)
        t, node = pop!(stack)
        t.id in seen && continue
        push!(seen, t.id)
        f(t, node)
        for child in Iterators.reverse(_mirrored_children(node))
            child isa ProgressNode || continue
            ct = _track_for(child, m)
            isnothing(ct) || push!(stack, (ct, child))
        end
    end
end

# ── frames ───────────────────────────────────────────────────────────────────

function _node_state(m::ProgressMirror, t::_Track, node::ProgressNode)
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
    ops, dirty, left, left_hosts = @lock m.spin begin
        @atomic m.pending = false
        queued = (m.ops, m.dirty, m.left, m.left_hosts)
        m.ops = _Op[]
        m.dirty = _Track[]
        m.left = Tuple{_PhaseGroup,ProgressNode}[]
        m.left_hosts = Int[]
        queued
    end
    # Cleared before the state is read: a change after this point queues the
    # node again, so it is never lost between two frames.
    for t in dirty
        @atomic t.dirty = false
    end
    m.seq += 1
    plans = Tuple{_PhaseGroup,ProgressNode}[]
    for (group, from) in left
        _plan_chain!(plans, group, from)
    end
    if full
        frame = _full_frame(m, final, plans)
    else
        nodes = _NodeState[]
        for t in dirty
            node = @atomic t.node
            isnothing(node) && continue        # left the tree since
            push!(nodes, _node_state(m, t, node))
            _member_plans!(plans, t, node)
            _hosted_plans!(plans, node)
        end
        groups, order = _group_states(m, plans, false)
        frame = ProgressFrame(m.source, m.seq, false, final, nodes, ops, Pair{Int,Vector{Int}}[], groups, order)
    end
    # The plans of nodes that left are not sent again: forget them, so a long
    # run's tables stay the size of its tree.
    foreach(host -> _forget_host_groups!(m, host), left_hosts)
    frame
end

# A phase node's state counts in its plan and in the plan's surviving-owner
# records. The mirrored root's own plan belongs to the tree around it, which
# the replica does not mirror.
function _member_plans!(plans, t::_Track, node::ProgressNode)
    t.id == 1 && return plans
    sp = node.impl
    sp isa StateProgress || return plans
    member = sp.phase_member
    isnothing(member) && return plans
    _plan_chain!(plans, member.group, node)
end

# A plan and the records that keep its counts for surviving owners.
function _plan_chain!(plans, group, from::ProgressNode)
    while !isnothing(group)
        push!(plans, (group, from))
        group = group.ancestor
    end
    plans
end

function _hosted_plans!(plans, node::ProgressNode)
    for group in _phase_group_records(node)
        _plan_chain!(plans, group, node)
    end
    plans
end

function _full_frame(m::ProgressMirror, final::Bool, plans)
    nodes = _NodeState[]
    children = Pair{Int,Vector{Int}}[]
    _foreach_track(m) do t, node
        push!(nodes, _node_state(m, t, node))
        _hosted_plans!(plans, node)
        ids = Int[]
        for child in _mirrored_children(node)
            child isa ProgressNode || continue
            ct = _track_for(child, m)
            isnothing(ct) || push!(ids, ct.id)
        end
        push!(children, t.id => ids)
    end
    groups, order = _group_states(m, plans, true)
    ProgressFrame(m.source, m.seq, true, final, nodes, _Op[], children, groups, order)
end

# The node that holds `group` and its id: the first node at or above `from`
# whose plans include it. A plan held above the mirrored root goes to the root;
# one held by a node that has left the mirrored tree (a finished transient
# item) is gone with it: id 0.
function _group_host(m::ProgressMirror, group::_PhaseGroup, from::ProgressNode)
    node = from
    inside = true
    while node isa ProgressNode
        if _holds_group(node, group)
            t = _track_for(node, m)
            isnothing(t) || return (t.id, node)
            return inside ? (0, node) : (1, m.root)
        end
        node === m.root && (inside = false)
        node = node.parent
    end
    (0, from)
end

_holds_group(::ProgressNode, ::_PhaseGroup) = false
function _holds_group(node::ProgressNode{<:StateProgress}, group::_PhaseGroup)
    sp = node.impl
    lock(sp.lock) do
        !isnothing(sp.phase_groups) && get(sp.phase_groups, group.key, nothing) === group
    end
end

# The plans among `plans` that are new or changed since they were last sent
# (all of them for a full frame), and the plan order of every node that holds
# a new one.
function _group_states(m::ProgressMirror, plans, full::Bool)
    hosts = Dict{Int,ProgressNode}()
    live = Tuple{_PhaseGroup,Int}[]
    seen = Base.IdSet{_PhaseGroup}()
    for (group, from) in plans
        group in seen && continue
        push!(seen, group)
        id = get(m.group_ids, group, 0)
        if id == 0 || full
            host, host_node = _group_host(m, group, from)
            host == 0 && continue
            if id == 0
                id = m.group_ids[group] = (m.next_group += 1)
                m.groups[id] = group
                m.group_host[id] = host
                push!(get!(Vector{Int}, m.host_groups, host), id)
            end
            hosts[host] = host_node
        end
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
    order = Pair{Int,Vector{Int}}[host => _host_order(m, host, hosts[host]) for host in sort!(collect(keys(hosts)))]
    groups, order
end

# The plans a mirrored node holds, in the order it holds them; plans held
# above the root come after the root's own.
function _host_order(m::ProgressMirror, host::Int, node::ProgressNode)
    ids = get(m.host_groups, host, Int[])
    own = Int[]
    for group in _phase_group_records(node)
        id = get(m.group_ids, group, 0)
        id != 0 && get(m.group_host, id, 0) == host && push!(own, id)
    end
    present = Set(own)
    append!(own, (id for id in ids if !(id in present)))
end

function _forget_host_groups!(m::ProgressMirror, host::Int)
    ids = pop!(m.host_groups, host, nothing)
    isnothing(ids) && return nothing
    for id in ids
        delete!(m.group_ids, pop!(m.groups, id))
        delete!(m.group_host, id)
        delete!(m.group_sent, id)
    end
    nothing
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
    followed = Tuple{_Track,ProgressNode}[]
    _foreach_track((t, node) -> push!(followed, (t, node)), m)
    for (t, node) in followed
        @atomic t.node = nothing
        node.impl isa StateProgress && _remove_track!(node.impl, t)
        node.children isa ThreadsafeSet && _remove_track!(node.children, t)
    end
    @lock m.spin begin
        empty!(m.ops)
        empty!(m.dirty)
        empty!(m.left)
        empty!(m.left_hosts)
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

Send [`ProgressFrame`](@ref) values to a caller-supplied transport. Apply them
in the receiving process with [`progress_replica`](@ref) and
[`apply_frame!`](@ref). The first and closing frames hold the full tree;
intermediate frames contain changed node states and ordered structure changes.
Notes, timestamps and prepared-phase counts are preserved.

A background task and node changes trigger sends, at most once per `interval`
seconds. `interval=0` sends each change; `flush(handle)` sends pending changes.
`close(handle)` sends the final frame and stops observation. The do-block
calls `f()` and closes on every exit. Close after the work's owning wrapper
finishes if the final frame must carry that root's terminal state.

`send` runs without tree locks and is serialized per mirror. Failure on its
first call propagates; a later failure is logged and stops the mirror while
work continues. Use `request_interrupt!(mirror, id)` to forward a replica's
interrupt request. With a disabled node, the handle is `nothing` and the
do-block still calls its callback.
"""
function mirror_progress(send, node::ProgressNode; interval::Real=0.05)
    interval >= 0 || throw(ArgumentError("mirror_progress interval must not be negative, got $interval"))
    m = ProgressMirror(node, send, Float64(interval), round(UInt64, interval * 1e9), _mirror_source(),
        ReentrantLock(), Threads.SpinLock(), Base.Event(true), UInt64(0), true, false, 0, 0,
        _Op[], _Track[], Tuple{_PhaseGroup,ProgressNode}[], Int[], 0, IdDict{_PhaseGroup,Int}(),
        Dict{Int,_PhaseGroup}(), Dict{Int,Int}(), Dict{Int,Any}(), Dict{Int,Vector{Int}}())
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
the tree, are ignored. The node is looked up in the tree: a viewer's Stop can
afford that, and it spares every node of the run an index entry.
"""
function request_interrupt!(m::ProgressMirror, id::Integer)
    found = Ref{Union{Nothing,ProgressNode}}(nothing)
    _foreach_track((t, node) -> t.id == id && (found[] = node), m)
    isnothing(found[]) || request_interrupt!(found[])
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
    const group_ids::IdDict{_PhaseGroup,Int}
    const host_groups::Dict{Int,Vector{Int}}   # node id => the plans it holds
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
        Dict{Int,ProgressNode}(1 => target), IdDict{ProgressNode,Int}(target => 1), Dict{Int,_PhaseGroup}(),
        IdDict{_PhaseGroup,Int}(), Dict{Int,Vector{Int}}())
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
            x == 1 || _forget_replica_node!(r, x)
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
    for id in collect(keys(r.nodes))
        id == 1 || id in present || _forget_replica_node!(r, id)
    end
end

# A node that left the source tree: drop it and the plans it held, so a long
# run's replica stays the size of its tree.
function _forget_replica_node!(r::ProgressReplica, id::Int)
    node = pop!(r.nodes, id, nothing)
    isnothing(node) || delete!(r.ids, node)
    for gid in pop!(r.host_groups, id, Int[])
        delete!(r.group_ids, pop!(r.groups, gid))
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
            r.group_ids[group] = g.id
            push!(get!(Vector{Int}, r.host_groups, g.host), g.id)
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
    sp = host.impl::StateProgress
    lock(sp.lock) do
        plans = sp.phase_groups
        isnothing(plans) && return nothing
        ordered = OrderedDict{Any,_PhaseGroup}()
        for (key, group) in plans
            haskey(r.group_ids, group) || (ordered[key] = group)
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
