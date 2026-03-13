module TermExt
import Term
import Term.Progress: ProgressBar, ProgressJob, AbstractColumn, DescriptionColumn, CompletedColumn, SeparatorColumn, ProgressColumn
import Treebars
import Treebars: initialize_progress!, finalize_progress!, update_progress!, fail_progress!,
    IncrementBy, ProgressNode, propagates_finalization, root, labels

TermProgressNode{I<:Union{ProgressBar,ProgressJob},M,C} = ProgressNode{I,M,C}

# Custom column for displaying arbitrary strings
struct StringColumn <: AbstractColumn
    parent::Term.Progress.ProgressJob
    msg::Ref{String}
    StringColumn(job::Term.Progress.ProgressJob, msg::AbstractString="             ") = new(job, Ref(msg))
end
Base.getproperty(x::StringColumn, k::Symbol) = if hasfield(typeof(x), k)
    getfield(x, k)
else
    @assert k == :measure
    Term.Progress.Measure(x.msg[])
end
Term.Progress.update!(col::StringColumn, color::String) = Term.Segment(col.msg[], color).text

# Background render loop
function renderloop(pbar, lock)
    while pbar.running
        Base.lock(lock) do
            Term.Progress.render(pbar)
        end
        sleep(pbar.Δt)
    end
end

# Helpers
getfirst(f, itr) = begin
    for it in itr
        f(it) && return it
    end
    return nothing
end

# Initialize root progress bar (:term backend)
initialize_progress!(::Val{:term}; width=120, max_rows=32, kwargs...) = begin
    bar = ProgressBar(; width, columns=[DescriptionColumn, CompletedColumn, SeparatorColumn, ProgressColumn])
    Term.Progress.start!(bar)
    lock = ReentrantLock()
    thread = Threads.@spawn renderloop(bar, lock)
    ProgressNode(bar, (; lock, thread, max_rows, propagates=false, labels=Dict{Symbol,Any}()))
end

# Initialize a child progress job with N steps
initialize_progress!(node::TermProgressNode, N::Integer; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...) = begin
    pbar = root(node).impl
    lock = root(node).meta.lock
    pjob = Base.lock(lock) do
        pjob = ProgressJob(rand(Int), N, description, pbar.columns, pbar.width, pbar.columns_kwargs, transient)
        pjob.columns = [DescriptionColumn(pjob), CompletedColumn(pjob), SeparatorColumn(pjob), ProgressColumn(pjob), StringColumn(pjob, "ETA: N/A")]
        pjob.startime = Term.Progress.now()
        push!(pbar.jobs, pjob)
        _update_job!(pjob, 0)
        pjob
    end
    ProgressNode(pjob, (; propagates, labels=Dict{Symbol,Any}()); parent=node)
end

# Initialize a child label job (no N, displays key:value)
initialize_progress!(node::TermProgressNode; description="Running...", transient=false, propagates=false, key=nothing, value="", kwargs...) = begin
    pbar = root(node).impl
    lock = root(node).meta.lock
    pjob = Base.lock(lock) do
        pjob = ProgressJob(rand(Int), nothing, description, pbar.columns, pbar.width, pbar.columns_kwargs, transient)
        pjob.columns = [DescriptionColumn(pjob), StringColumn(pjob, string(value))]
        push!(pbar.jobs, pjob)
        pjob
    end
    ProgressNode(pjob, (; propagates, labels=Dict{Symbol,Any}()); parent=node)
end

# Update with integer counter + kwargs
update_progress!(node::TermProgressNode, i::Integer; kwargs...) = begin
    _update_job!(node.impl, i)
    Treebars._update_labels!(node; kwargs...)
end

# Update with nothing (metadata only)
update_progress!(node::TermProgressNode, ::Nothing; kwargs...) = Treebars._update_labels!(node; kwargs...)

# Increment by 1
update_progress!(node::TermProgressNode; kwargs...) = begin
    _update_job!(node.impl, IncrementBy(1))
    Treebars._update_labels!(node; kwargs...)
end

# Update with string message
update_progress!(node::TermProgressNode, msg::AbstractString; kwargs...) = begin
    _update_job!(node.impl, msg)
    Treebars._update_labels!(node; kwargs...)
end

# Update with IncrementBy
update_progress!(node::TermProgressNode, inc::IncrementBy; kwargs...) = begin
    _update_job!(node.impl, inc)
    Treebars._update_labels!(node; kwargs...)
end

# Low-level job updates
_update_job!(pjob::ProgressJob, i::Integer) = begin
    pjob.i = isnothing(pjob.N) ? 0 : clamp(i, 0, pjob.N)
    dt = Term.Progress.now() - pjob.startime
    eta = if isnothing(pjob.N) || pjob.i == 0
        Inf
    else
        (1 - pjob.i / pjob.N) / ((pjob.i / pjob.N) / (dt).value)
    end
    msg = if eta == 0
        "Took $(Term.Progress.canonicalize(dt))"
    elseif !isfinite(eta)
        "ETA: N/A"
    else
        "ETA: $(Term.Progress.canonicalize(Term.Progress.Millisecond(round(Int, eta))))"
    end
    _update_job!(pjob, msg)
end
_update_job!(pjob::ProgressJob, ::IncrementBy{di}) where {di} = _update_job!(pjob, pjob.i + di)
_update_job!(pjob::ProgressJob, msg::AbstractString) = begin
    pjob.columns[end].msg[] = msg
    Term.Progress.setwidth!(pjob.columns[end-1], pjob.width - length(pjob.columns) - sum(c -> isa(c, Term.Progress.ProgressColumn) ? 0 : c.measure.w, pjob.columns))
end
_update_job!(::ProgressJob, ::Nothing) = nothing

# Finalize
finalize_progress!(pbar::ProgressBar) = begin
    Term.Progress.render(pbar)
    Term.Progress.stop!(pbar)
end
finalize_progress!(pjob::ProgressJob) = Term.Progress.stop!(pjob)

end
