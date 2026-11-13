using PrecompileTools: @compile_workload

# Small, in-memory workloads only: no terminal, timers, files, network or
# process-global BACKEND changes. The HTML extension reuses the same tree.
function _precompile_tree()
    node = initialize_progress!(:state; description="Work")
    @progress node "Items" for i in 1:2
        @progress "Load"
        update_progress!(__progress__, "loading")
        @progress "Compute"
    end
    counter = initialize_progress!(node; description="Counter", N=4)
    update_progress!(counter, 1)
    update_progress!(node; result=2)
    prepare_progress!(node; description="Pending")
    skip_progress!(prepare_progress!(node; description="Skipped"))
    reuse_progress!(prepare_progress!(node; description="Reused"))
    failed = initialize_progress!(node; description="Failed")
    fail_progress!(failed)
    node
end

@compile_workload begin
    node = _precompile_tree()
    render_text(node)
    render_text(node; phase_overview=true)
    finalize_progress!(node)
    render_text(node)
    sprint(show, MIME"text/plain"(), node)
    with_progress(_ -> nothing, nothing)
end
