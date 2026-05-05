using Revise
using TreebarsWeb

begin
    TreebarsWeb.terminate()
    Threads.nthreads() < 2 && @warn "TreebarsWeb needs at least 2 threads for async progress. Start with: julia -t2 --project ..."
    port = length(ARGS) >= 1 ? parse(Int, ARGS[1]) : 8098
    TreebarsWeb.serve(; host="0.0.0.0", revise=:lazy, port, async=true)
end
