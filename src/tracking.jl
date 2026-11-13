# Node-local observer storage, shared by mirrors and snapshot files. Replaced
# atomically so a counter with no observers needs only one atomic load.
abstract type _ProgressTrack end

# A node's tracks (one per observer following it): `nothing`, one `_ProgressTrack`, or a
# vector of them, replaced (never mutated) so the hooks read it with one load.
_tracks_with(old, t) = isnothing(old) ? t : old isa _ProgressTrack ? [old, t] : vcat(old, t)
function _tracks_without(old, t)
    old === t && return nothing
    old isa Vector || return old
    rest = filter(x -> x !== t, old)
    isempty(rest) && return nothing
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

function _find_track(node::ProgressNode, owner, ::Type{T}) where {T<:_ProgressTrack}
    tracks = _node_tracks(node)
    tracks isa T && return _track_owner(tracks) === owner ? tracks : nothing
    tracks isa Vector || return nothing
    for t in tracks
        t isa T && _track_owner(t) === owner && return t
    end
    nothing
end

_children_lock(node) = node.children isa ThreadsafeSet ? node.children.lock : nothing
_lock_children(node) = (l = _children_lock(node); isnothing(l) || lock(l); l)
_unlock_children(l) = isnothing(l) || unlock(l)
# A snapshot of `node`'s children; no allocation for a leaf, the common case
# when a finished item leaves the tree.
function _mirrored_children(node)
    kids = node.children
    kids isa ThreadsafeSet || return ProgressNode[]
    @lock kids.lock isempty(kids.inner) ? _NO_CHILDREN : collect(kids.inner)
end
const _NO_CHILDREN = ProgressNode[]

# Structural hooks run inside the children lock; they only update tracking.
_tracked_append(ts::Vector, x) = foreach(t -> _tracked_append(t, x), ts)
_tracked_remove(ts::Vector, x) = foreach(t -> _tracked_remove(t, x), ts)

# State hooks run outside node/children locks, so a due observer may render.
@inline function _progress_changed(sp::StateProgress)
    tracks = @atomic :acquire sp.track
    isnothing(tracks) || _tracks_changed(tracks)
    nothing
end
_progress_changed(::Any) = nothing
_tracks_changed(t::_ProgressTrack) = _track_changed(t)
function _tracks_changed(ts::Vector)
    # Sample the clock once even when many observers follow this node. Keep
    # homogeneous vectors concrete so their tight loop needs no dispatch.
    tick = time_ns()
    for t in ts
        _track_changed(t, tick)
    end
    nothing
end
