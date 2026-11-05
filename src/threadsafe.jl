# A node's `children`. `track` is set while a progress mirror follows the node
# (src/mirror.jl): every change to the set is then reported to the mirror from
# inside the set's lock, so the mirror records the changes in the order they
# happened — whoever makes them, including packages that `push!`/`pop!` a
# node's children directly. With no mirror it is one atomic load per change.
mutable struct ThreadsafeSet{T} <: AbstractSet{T}
    const lock::ReentrantLock
    const inner::OrderedSet{T}
    @atomic track::Any
    ThreadsafeSet{T}() where T = new{T}(ReentrantLock(), OrderedSet{T}(), nothing)
    ThreadsafeSet{T}(items) where T = new{T}(ReentrantLock(), OrderedSet{T}(items), nothing)
end
ThreadsafeSet() = ThreadsafeSet{Any}()
ThreadsafeSet(items::AbstractVector{T}) where T = ThreadsafeSet{T}(items)

# Marks "not in the set" for `pop!` without a caller's default.
struct _Absent end

Base.length(s::ThreadsafeSet) = @lock s.lock length(s.inner)
Base.isempty(s::ThreadsafeSet) = @lock s.lock isempty(s.inner)
Base.in(x, s::ThreadsafeSet) = @lock s.lock x in s.inner
function Base.push!(s::ThreadsafeSet, x)
    @lock s.lock begin
        n = length(s.inner)
        push!(s.inner, x)
        track = @atomic :acquire s.track
        # Pushing an element already there changes nothing, so reports nothing.
        isnothing(track) || length(s.inner) == n || _tracked_append(track, x)
    end
    s
end
function Base.pop!(s::ThreadsafeSet, x)
    rv = pop!(s, x, _Absent())
    rv isa _Absent && throw(KeyError(x))
    rv
end
function Base.pop!(s::ThreadsafeSet, x, default)
    @lock s.lock begin
        rv = pop!(s.inner, x, _Absent())
        rv isa _Absent && return default
        track = @atomic :acquire s.track
        isnothing(track) || _tracked_remove(track, rv)
        rv
    end
end
Base.delete!(s::ThreadsafeSet, x) = (pop!(s, x, nothing); s)
function Base.empty!(s::ThreadsafeSet)
    @lock s.lock begin
        track = @atomic :acquire s.track
        if !isnothing(track)
            for x in s.inner
                _tracked_remove(track, x)
            end
        end
        empty!(s.inner)
    end
    s
end
Base.iterate(s::ThreadsafeSet, (snap, i)=(collect(s), 1)) = i > length(snap) ? nothing : (snap[i], (snap, i + 1))
Base.collect(s::ThreadsafeSet) = @lock s.lock collect(s.inner)
Base.show(io::IO, s::ThreadsafeSet{T}) where T = @lock s.lock print(io, "ThreadsafeSet{", T, "}(", length(s.inner), " elements)")

struct ThreadsafeDict{K,V} <: AbstractDict{K,V}
    lock::ReentrantLock
    inner::OrderedDict{K,V}
    ThreadsafeDict{K,V}() where {K,V} = new{K,V}(ReentrantLock(), OrderedDict{K,V}())
end
ThreadsafeDict() = ThreadsafeDict{Any,Any}()

Base.length(d::ThreadsafeDict) = @lock d.lock length(d.inner)
Base.isempty(d::ThreadsafeDict) = @lock d.lock isempty(d.inner)
Base.haskey(d::ThreadsafeDict, k) = @lock d.lock haskey(d.inner, k)
Base.getindex(d::ThreadsafeDict, k) = @lock d.lock d.inner[k]
Base.setindex!(d::ThreadsafeDict, v, k) = (@lock d.lock d.inner[k] = v; d)
Base.get(d::ThreadsafeDict, k, default) = @lock d.lock get(d.inner, k, default)
Base.get!(d::ThreadsafeDict, k, default) = @lock d.lock get!(d.inner, k, default)
Base.get!(f::Function, d::ThreadsafeDict, k) = @lock d.lock get!(f, d.inner, k)
Base.pop!(d::ThreadsafeDict, k) = @lock d.lock pop!(d.inner, k)
Base.pop!(d::ThreadsafeDict, k, default) = @lock d.lock pop!(d.inner, k, default)
Base.delete!(d::ThreadsafeDict, k) = (@lock d.lock delete!(d.inner, k); d)
Base.empty!(d::ThreadsafeDict) = (@lock d.lock empty!(d.inner); d)
Base.iterate(d::ThreadsafeDict, (snap, i)=(collect(d), 1)) = i > length(snap) ? nothing : (snap[i], (snap, i + 1))
Base.keys(d::ThreadsafeDict) = @lock d.lock collect(keys(d.inner))
Base.values(d::ThreadsafeDict) = @lock d.lock collect(values(d.inner))
Base.collect(d::ThreadsafeDict) = @lock d.lock collect(d.inner)
Base.show(io::IO, d::ThreadsafeDict{K,V}) where {K,V} = @lock d.lock print(io, "ThreadsafeDict{", K, ",", V, "}(", length(d.inner), " entries)")
