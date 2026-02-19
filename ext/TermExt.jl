module TermExt
import Term
import Term.Progress: ProgressBar, ProgressJob, AbstractColumn, DescriptionColumn, CompletedColumn, SeparatorColumn, ProgressColumn
import Treebars: initialize_progress!, finalize_progress!, update_progress!, IncrementBy, ProgressNode, propagates_finalization, root

TermProgressNode{I<:Union{ProgressBar,ProgressJob},M,C} = ProgressNode{I,M,C}
# TermProgressNode(args...; kwargs...) = ProgressNode(:term, args...; kwargs...)

function renderloop(pbar, lock)
    # @info "Starting renderloop"
    while pbar.running
        Base.lock(lock) do 
            Term.Progress.render(pbar)
        end
        sleep(pbar.Δt)
    end
    # @info "Exiting renderloop"
end

initialize_progress!(::Val{:term}; width=120, kwargs...) = begin
    bar = ProgressBar(;width, columns=[DescriptionColumn, CompletedColumn, SeparatorColumn, ProgressColumn])
    Term.Progress.start!(bar)
    lock = ReentrantLock()
    thread = Threads.@spawn renderloop(bar, lock)
    ProgressNode(bar, (;lock, thread, propagates=false))
end
initialize_progress!(node::TermProgressNode, N::Int; description="Running...", transient=false, propagates=false) = begin 
    pbar = root(node).impl
    pjob = ProgressJob(rand(Int), N, description, pbar.columns, pbar.width, pbar.columns_kwargs, transient)
    pjob.columns = [DescriptionColumn(pjob), CompletedColumn(pjob), SeparatorColumn(pjob), ProgressColumn(pjob), StringColumn(pjob, "ETA: N/A")]
    pjob.startime = Term.Progress.now()
    push!(pbar.jobs, pjob)
    update_progress!(pjob, 0)
    # Term.Progress.render(pjob, pbar)
    ProgressNode(pjob, (;propagates); parent=node)
end
update_progress!(node::TermProgressNode, args...; transient=false, propagates=false, kwargs...) = begin
    update_progress!(node.impl, args...; kwargs...)
    for pair in pairs(kwargs)
        update_progress!(node, pair; transient, propagates)
    end 
end
update_progress!(node::TermProgressNode, (key, value)::Pair; transient=false, propagates=false, kwargs...) = begin 
    pbar = root(node).impl
    key = isa(key, Symbol) ? replace(string(key), "_"=>" ") : key
    description = "$key:"
    dl = textwidth(description)
    ml = maximum(child->textwidth(child.impl.description), node.children; init=0)
    value = string(value)
    value = lpad(value, 1+max(ml-dl, 0)+textwidth(value))
    job = getfirst(child->child.impl.description == description, node.children)
    if isnothing(job)
        pjob = ProgressJob(rand(Int), nothing, description, pbar.columns, pbar.width, pbar.columns_kwargs, transient)
        pjob.columns = [DescriptionColumn(pjob), StringColumn(pjob, value)]
        if dl > ml
            for child in node.children
                cmsg = child.impl.columns[end].msg
                cmsg[] = lpad(cmsg[], 1 + dl-textwidth(child.impl.description) + textwidth(cmsg[]))
            end
        end 
        Term.Progress.render(pjob, pbar)
        push!(pbar.jobs, pjob)
        ProgressNode(pjob, (;propagates); parent=node)
    else
        job.impl.columns[end].msg[] = value
        job
    end
end
getfirst(f, itr) = begin
    for it in itr
        f(it) && return it
    end 
    return nothing
end

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

update_progress!(pjob::ProgressJob, args...; kwargs...) = nothing
update_progress!(pjob::ProgressJob, msg::AbstractString; kwargs...) = begin 
    pjob.columns[end].msg[] = msg
    Term.Progress.setwidth!(pjob.columns[end-1], pjob.width-length(pjob.columns) - sum(c -> isa(c, Term.Progress.ProgressColumn) ? 0 : c.measure.w, pjob.columns))
    update_progress!(pjob; kwargs...)
end
update_progress!(pjob::ProgressJob, i::Int; kwargs...) = begin
    pjob.i = clamp(i, 0, pjob.N)
    dt = Term.Progress.now() - pjob.startime
    eta = (1 - pjob.i / pjob.N) / ((pjob.i / pjob.N) / (dt).value)
    msg = if eta == 0
        "Took $(Term.Progress.canonicalize(dt))"
    elseif !isfinite(eta)
        "ETA: N/A"
    else
        "ETA: $(Term.Progress.canonicalize(Term.Progress.Millisecond(round(Int, eta))))"
    end
    update_progress!(pjob, msg; kwargs...)
end
update_progress!(pjob::ProgressJob, ::IncrementBy{di}) where {di} = update_progress!(pjob, pjob.i + di)

finalize_progress!(pbar::ProgressBar) = Term.Progress.stop!(pbar)
finalize_progress!(pjob::ProgressJob) = Term.Progress.stop!(pjob)
end