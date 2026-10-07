# The lifecycle representation remains authoritative. Group counters are a
# projection updated under the phase's lock, then the group's lock. Snapshot
# readers never acquire a phase lock while holding a group lock.
# Column order is storage only (renderers list states explicitly): 1 pending,
# 2 running, 3 finished, 4 failed, 5 skipped, 6 reused.
_phase_state_index(sp::StateProgress) =
    is_pending(sp) ? 1 : is_running(sp) ? 2 : is_failed(sp) ? 4 :
    is_skipped(sp) ? 5 : is_reused(sp) ? 6 : 3

function _record_phase_transition!(sp::StateProgress, previous)
    member = sp.phase_member
    isnothing(member) && return nothing
    current = _phase_state_index(sp)
    previous == current && return nothing
    group = member.group
    while !isnothing(group)
        lock(group.lock) do
            group.counts[member.index, previous] -= 1
            group.counts[member.index, current] += 1
        end
        group = group.ancestor
    end
    nothing
end

_prepare_phase_group(parent, identity, keys, labels) = nothing
function _prepare_phase_group(parent::ProgressNode{<:StateProgress}, identity, keys, labels)
    isempty(keys) && return nothing
    declarer = _phase_declarer(_enclosing_phase(parent))
    # The same declared plan inside different enclosing phases stays separate,
    # so every overview record can name the phase that declared it.
    key = (identity, isnothing(declarer) ? nothing : (declarer.plan, declarer.index))
    # A transient iteration wrapper disappears when its iteration ends. Keep
    # its bounded counters on the first ancestor that survives that removal.
    owner = parent
    while istransient(owner) && owner.parent isa ProgressNode{<:StateProgress}
        owner = owner.parent
    end
    # Name an outermost plan after that surviving owner, whichever groups a
    # snapshot happens to reach.
    host = lock(() -> owner.impl.description, owner.impl.lock)
    ancestor = owner === parent ? nothing : _get_phase_group!(owner, key, declarer, host, keys, labels)
    group = _get_phase_group!(parent, key, declarer, host, keys, labels; ancestor)
    current = group
    while !isnothing(current)
        lock(current.lock) do
            current.items += 1
            for i in eachindex(keys)
                current.counts[i, 1] += 1
                # An item-specific label does not redefine phase identity.
                current.labels[i] == string(labels[i]) || (current.labels[i] = nothing)
            end
        end
        current = current.ancestor
    end
    group
end

# The nearest prepared phase at or above `node` is the phase that a plan
# declared there belongs to. Membership is fixed when a phase is constructed,
# so the walk reads no lifecycle state.
function _enclosing_phase(node)
    while node isa ProgressNode{<:StateProgress}
        member = node.impl.phase_member
        isnothing(member) || return member
        node = node.parent
    end
    nothing
end

_phase_declarer(::Nothing) = nothing
function _phase_declarer(member::_PhaseMembership)
    group = member.group
    label = lock(() -> group.labels[member.index], group.lock)
    (; plan=group.key, index=member.index, phase=group.keys[member.index], label)
end

function _get_phase_group!(node, key, declarer, host, keys, labels; ancestor=nothing)
    lock(node.impl.lock) do
        groups = node.impl.phase_groups
        if isnothing(groups)
            groups = OrderedDict{Any,_PhaseGroup}()
            node.impl.phase_groups = groups
        end
        get!(groups, key) do
            _PhaseGroup(ReentrantLock(), ancestor, key, declarer, host, keys,
                Union{Nothing,String}[string(label) for label in Tuple(labels)],
                zeros(Int, length(keys), 6), 0)
        end
    end
end

_phase_membership(::Nothing, i) = nothing
_phase_membership(group::_PhaseGroup, i) = _PhaseMembership(group, i)

_prepare_planned_phase(parent, ::Nothing, i; kwargs...) = prepare_progress!(parent; kwargs...)
_prepare_planned_phase(parent, group::_PhaseGroup, i; kwargs...) =
    prepare_progress!(parent; _phase_member=_phase_membership(group, i), kwargs...)

function _prepare_phase_nodes(parent, identity, keys, labels; kwargs...)
    group = _prepare_phase_group(parent, identity, keys, labels)
    index = Ref(0)
    map(labels) do label
        index[] += 1
        _prepare_planned_phase(parent, group, index[]; description=label, kwargs...)
    end
end

function _phase_group_records(node::ProgressNode{<:StateProgress})
    lock(node.impl.lock) do
        groups = node.impl.phase_groups
        isnothing(groups) ? _PhaseGroup[] : collect(values(groups))
    end
end
_phase_group_records(::ProgressNode) = _PhaseGroup[]

function _collect_phase_groups!(records, seen_nodes, seen_groups, node::ProgressNode)
    _first_seen!(seen_nodes, node) || return
    for group in _phase_group_records(node)
        group in seen_groups && continue
        push!(seen_groups, group)
        push!(records, group)
    end
    for child in node.children
        _collect_phase_groups!(records, seen_nodes, seen_groups, child)
    end
end
_collect_phase_groups!(records, seen_nodes, seen_groups, ::Nothing) = nothing

function _phase_group_covered(group, seen_groups)
    ancestor = group.ancestor
    while !isnothing(ancestor)
        ancestor in seen_groups && return true
        ancestor = ancestor.ancestor
    end
    false
end

_phase_fallback_label(key::Symbol) = string(key)
_phase_fallback_label(key::Integer) = "Phase $key"

_merged_label(a, b) = a == b ? a : nothing

"""
    phase_overview(node) -> Tuple

Snapshot counts for repeated, pre-enumerated phase plans below `node`.
Each record has `label`, `parent`, `items` and a tuple of `phases`; each phase
has `key`, `label`, and `pending`, `running`, `finished`, `failed`, `skipped`,
`reused` counts.

`@progress` phase markers, `@phases`, and `with_prepared_phases` retain their
plan automatically. Different macro phase blocks stay separate. NamedTuple
plans match by their complete ordered key sequence; iterable plans match by
their complete declared label sequence. Arbitrary progress descriptions do
not participate. Item-specific labels fall back to the phase key/position.

A plan declared inside a prepared phase of another plan (for example, a stage's
own preparations under a stage plan) is nested under that phase: its `parent`
is `(; plan, phase)` — the index of the enclosing record in the returned tuple
and the enclosing phase's key — and its `label` is that phase's label. The same
declaration inside different enclosing phases yields separate records, one per
enclosing phase. Records are ordered depth-first: each plan precedes the plans
nested in it. A plan whose enclosing plan lies outside the snapshot keeps its
`label` and has `parent === nothing`. Any other plan is labeled by the
description of the node that declared it (for a transient node, the first
surviving ancestor that retains its counts) when every declaring node agrees,
and otherwise has `label === nothing`.

Counts include completed transient phases even after those nodes detach.
Only instantiated plans are counted: items which have not yet prepared their
phases are not invented. Snapshots deduplicate shared trees and are immutable;
each plan is read under its lock, rather than freezing the whole workload.
The `:state` backend records all six lifecycle states; disabled/other backends
produce an empty tuple. A collection of nodes can be passed for a job board.
"""
function phase_overview(nodes)
    output = OrderedDict{Any,Any}()
    records = _PhaseGroup[]
    seen_nodes = Base.IdSet{ProgressNode}()
    seen_groups = Base.IdSet{_PhaseGroup}()
    for node in _overview_roots(nodes)
        _collect_phase_groups!(records, seen_nodes, seen_groups, node)
    end
    # A surviving ancestor includes its transient descendants' totals. Discover
    # all reachable groups first, so input/root order cannot double-count them.
    for group in records
        _phase_group_covered(group, seen_groups) && continue
        lock(group.lock) do
            if haskey(output, group.key)
                record = output[group.key]
                record.counts .+= group.counts
                record.items[] += group.items
                for i in eachindex(record.labels)
                    record.labels[i] = _merged_label(record.labels[i], group.labels[i])
                end
                record.host[] = _merged_label(record.host[], group.host)
                isnothing(group.declarer) ||
                    (record.declared[] = _merged_label(record.declared[], group.declarer.label))
            else
                output[group.key] = (; keys=group.keys, labels=copy(group.labels),
                    counts=copy(group.counts), items=Ref(group.items),
                    declarer=group.declarer,
                    host=Ref{Union{Nothing,String}}(group.host),
                    declared=Ref{Union{Nothing,String}}(
                        isnothing(group.declarer) ? nothing : group.declarer.label))
            end
        end
    end
    # Plans nest under the snapshot record of the phase that declared them.
    nested = Dict{Any,Vector{Any}}()
    outermost = Any[]
    for (key, record) in output
        enclosing = isnothing(record.declarer) ? nothing : record.declarer.plan
        if !isnothing(enclosing) && haskey(output, enclosing)
            push!(get!(Vector{Any}, nested, enclosing), key)
        else
            push!(outermost, key)
        end
    end
    plans = Any[]
    for key in outermost
        _push_overview_plan!(plans, output, nested, key, nothing)
    end
    Tuple(plans)
end

function _push_overview_plan!(plans, output, nested, key, parent)
    record = output[key]
    phases = Tuple(
        (; key=record.keys[i],
           label=something(record.labels[i], _phase_fallback_label(record.keys[i])),
           pending=record.counts[i, 1], running=record.counts[i, 2],
           finished=record.counts[i, 3], failed=record.counts[i, 4],
           skipped=record.counts[i, 5], reused=record.counts[i, 6])
        for i in eachindex(record.keys))
    declarer = record.declarer
    label = if !isnothing(parent)
        plans[parent.plan].phases[declarer.index].label
    elseif !isnothing(declarer)
        something(record.declared[], _phase_fallback_label(declarer.phase))
    else
        host = record.host[]
        isnothing(host) || isempty(host) ? nothing : host
    end
    push!(plans, (; label, parent, items=record.items[], phases))
    index = length(plans)
    for child in get(nested, key, ())
        _push_overview_plan!(plans, output, nested, child,
            (; plan=index, phase=output[child].declarer.phase))
    end
end
_overview_roots(node::ProgressNode) = (node,)
_overview_roots(::Nothing) = ()
_overview_roots(nodes) = nodes

# The `phase_overview` rendering keyword shared by the text and HTML renderers:
# `true` shows every plan, `:top` only the outermost plans of the rendered
# roots, and `false` none. Any other value is refused, never treated as false.
_overview_enabled(mode::Bool) = mode
_overview_enabled(mode::Symbol) = (_overview_depth_limit(mode); true)

_overview_depth_limit(::Bool) = typemax(Int)
_overview_depth_limit(mode::Symbol) = mode === :top ? 0 :
    throw(ArgumentError("phase_overview accepts true, false or :top; got :$mode"))

# Rendered overview entries: each plan with its nesting depth and caption.
function _overview_entries(nodes, mode)
    _overview_enabled(mode) || return ()
    limit = _overview_depth_limit(mode)
    depths = Int[]
    entries = Any[]
    for plan in phase_overview(nodes)
        depth = isnothing(plan.parent) ? 0 : depths[plan.parent.plan] + 1
        push!(depths, depth)
        depth <= limit || continue
        name = something(plan.label, "Phase plan $(length(entries) + 1)")
        push!(entries, (; plan, depth, caption="$name · $(plan.items) prepared items"))
    end
    entries
end
