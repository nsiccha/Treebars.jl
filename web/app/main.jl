using TreebarsWeb

begin
    TreebarsWeb.terminate()
    Threads.nthreads() < 2 && @warn "TreebarsWeb needs at least 2 threads for async progress. Start with: julia -t2 --project ..."
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8098
    # The gordito launcher (deploy/gordito/launch.sh) binds loopback only; a
    # desktop start keeps listening on every interface.
    host = get(ENV, "TREEBARS_WEB_HOST", "0.0.0.0")
    TreebarsWeb.serve(; host, revise=nothing, port, async=true)
end
