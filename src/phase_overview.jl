# The lifecycle representation remains authoritative. Group counters are a
# projection updated under the phase's lock, then the group's lock. Snapshot
# readers never acquire a phase lock while holding a group lock.
_phase_state_index(sp::StateProgress) =
    is_pending(sp) ? 1 : is_running(sp) ? 2 : is_failed(sp) ? 4 : is_skipped(sp) ? 5 : 3

function _record_phase_transition!(sp::StateProgress, previous)
    member = sp.phase_member
    isnothing(member) && return nothing
    current = _phase_state_index(sp)
    previous == current && return nothing
    group = member.group
    lock(group.lock) do
        group.counts[member.index, previous] -= 1
        group.counts[member.index, current] += 1
    end
    nothing
end

_prepare_phase_group(parent, identity, keys, labels) = nothing
function _prepare_phase_group(parent::ProgressNode{<:StateProgress}, identity, keys, labels)
    isempty(keys) && return nothing
    # A transient iteration wrapper disappears when its iteration ends. Keep
    # its bounded counters on the first ancestor that survives that removal.
    owner = parent
    while istransient(owner) && owner.parent isa ProgressNode{<:StateProgress}
        owner = owner.parent
    end
    group = lock(owner.impl.lock) do
        groups = owner.impl.phase_groups
        if isnothing(groups)
            groups = OrderedDict{Any,_PhaseGroup}()
            owner.impl.phase_groups = groups
        end
        get!(groups, identity) do
            _PhaseGroup(ReentrantLock(), keys,
                Union{Nothing,String}[string(label) for label in labels],
                zeros(Int, length(keys), 5), 0)
        end
    end
    lock(group.lock) do
        group.items += 1
        for i in eachindex(keys)
            group.counts[i, 1] += 1
            # An item-specific label does not redefine the phase's identity.
            group.labels[i] == string(labels[i]) || (group.labels[i] = nothing)
        end
    end
    group
end

_phase_membership(::Nothing, i) = nothing
_phase_membership(group::_PhaseGroup, i) = _PhaseMembership(group, i)

_prepare_planned_phase(parent, ::Nothing, i; kwargs...) = prepare_progress!(parent; kwargs...)
_prepare_planned_phase(parent, group::_PhaseGroup, i; kwargs...) =
    prepare_progress!(parent; _phase_member=_phase_membership(group, i), kwargs...)

function _prepare_phase_nodes(parent, identity, keys, labels; kwargs...)
    group = _prepare_phase_group(parent, identity, keys, labels)
    [_prepare_planned_phase(parent, group, i; description=labels[i], kwargs...)
        for i in eachindex(labels)]
end

function _phase_group_records(node::ProgressNode{<:StateProgress})
    lock(node.impl.lock) do
        groups = node.impl.phase_groups
        isnothing(groups) ? Pair{Any,_PhaseGroup}[] : collect(groups)
    end
end
_phase_group_records(::ProgressNode) = Pair{Any,_PhaseGroup}[]

function _collect_phase_groups!(output, seen_nodes, seen_groups, node::ProgressNode)
    _first_seen!(seen_nodes, node) || return
    for (identity, group) in _phase_group_records(node)
        group in seen_groups && continue
        push!(seen_groups, group)
        lock(group.lock) do
            if haskey(output, identity)
                record = output[identity]
                record.counts .+= group.counts
                record.items[] += group.items
                for i in eachindex(record.labels)
                    record.labels[i] == group.labels[i] || (record.labels[i] = nothing)
                end
            else
                output[identity] = (; keys=group.keys, labels=copy(group.labels),
                    counts=copy(group.counts), items=Ref(group.items))
            end
        end
    end
    for child in node.children
        _collect_phase_groups!(output, seen_nodes, seen_groups, child)
    end
end
_collect_phase_groups!(output, seen_nodes, seen_groups, ::Nothing) = nothing

_phase_fallback_label(key::Symbol) = string(key)
_phase_fallback_label(key::Integer) = "Phase $key"

"""
    phase_overview(node) -> Tuple

Snapshot counts for repeated, pre-enumerated phase plans below `node`.
Each record has `items` and a tuple of `phases`; each phase has `key`, `label`,
and `pending`, `running`, `finished`, `failed`, `skipped` counts.

`@progress` phase markers, `@phases`, and `with_prepared_phases` retain their
plan automatically. Different macro phase blocks stay separate. NamedTuple
plans match by their complete ordered key sequence; iterable plans match by
their complete declared label sequence. Arbitrary progress descriptions do
not participate. Item-specific labels fall back to the phase key/position.

Counts include completed transient phases even after those nodes detach.
Only instantiated plans are counted: items which have not yet prepared their
phases are not invented. Snapshots deduplicate shared trees and are immutable;
each plan is read under its lock, rather than freezing the whole workload.
The `:state` backend records all five lifecycle states; disabled/other backends
produce an empty tuple. A collection of nodes can be passed for a job board.
"""
function phase_overview(nodes)
    output = OrderedDict{Any,Any}()
    seen_nodes = Base.IdSet{ProgressNode}()
    seen_groups = Base.IdSet{_PhaseGroup}()
    for node in _overview_roots(nodes)
        _collect_phase_groups!(output, seen_nodes, seen_groups, node)
    end
    Tuple((; items=record.items[], phases=Tuple(
        (; key=record.keys[i],
           label=something(record.labels[i], _phase_fallback_label(record.keys[i])),
           pending=record.counts[i, 1], running=record.counts[i, 2],
           finished=record.counts[i, 3], failed=record.counts[i, 4],
           skipped=record.counts[i, 5])
        for i in eachindex(record.keys))) for record in values(output))
end
_overview_roots(node::ProgressNode) = (node,)
_overview_roots(::Nothing) = ()
_overview_roots(nodes) = nodes
