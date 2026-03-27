struct ThreadsafeSet{T} <: AbstractSet{T}
    lock::ReentrantLock
    inner::OrderedSet{T}
    ThreadsafeSet{T}() where T = new{T}(ReentrantLock(), OrderedSet{T}())
end
ThreadsafeSet() = ThreadsafeSet{Any}()

Base.length(s::ThreadsafeSet) = @lock s.lock length(s.inner)
Base.isempty(s::ThreadsafeSet) = @lock s.lock isempty(s.inner)
Base.in(x, s::ThreadsafeSet) = @lock s.lock x in s.inner
Base.push!(s::ThreadsafeSet, x) = (@lock s.lock push!(s.inner, x); s)
Base.pop!(s::ThreadsafeSet, x) = @lock s.lock pop!(s.inner, x)
Base.pop!(s::ThreadsafeSet, x, default) = @lock s.lock pop!(s.inner, x, default)
Base.delete!(s::ThreadsafeSet, x) = (@lock s.lock delete!(s.inner, x); s)
Base.empty!(s::ThreadsafeSet) = (@lock s.lock empty!(s.inner); s)
Base.iterate(s::ThreadsafeSet) = @lock s.lock iterate(s.inner)
Base.iterate(s::ThreadsafeSet, state) = @lock s.lock iterate(s.inner, state)
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
Base.empty!(d::ThreadsafeDict) = (@lock d.lock empty!(d.inner); s)
Base.iterate(d::ThreadsafeDict) = @lock d.lock iterate(d.inner)
Base.iterate(d::ThreadsafeDict, state) = @lock d.lock iterate(d.inner, state)
Base.keys(d::ThreadsafeDict) = @lock d.lock collect(keys(d.inner))
Base.values(d::ThreadsafeDict) = @lock d.lock collect(values(d.inner))
Base.show(io::IO, d::ThreadsafeDict{K,V}) where {K,V} = @lock d.lock print(io, "ThreadsafeDict{", K, ",", V, "}(", length(d.inner), " entries)")
