# Resolve the public, unregistered docs dependencies together on Julia 1.10.
using Pkg, TOML
Pkg.activate(@__DIR__)
dependencies = TOML.parsefile(joinpath(@__DIR__, "dependencies.toml"))
cache = joinpath(@__DIR__, ".deps")
mkpath(cache)
packages = [PackageSpec(path=dirname(@__DIR__))]
for (name, spec) in sort!(collect(dependencies); by=first)
    path = joinpath(cache, name * "-" * spec["rev"])
    if !isdir(path)
        mktempdir(cache) do temporary
            run(`git -C $temporary init --quiet`)
            run(`git -C $temporary fetch --quiet --depth=1 $(spec["url"]) $(spec["rev"])`)
            run(`git -C $temporary checkout --quiet --detach FETCH_HEAD`)
            mv(temporary, path)
        end
    end
    actual = readchomp(`git -C $path rev-parse HEAD`)
    actual == spec["rev"] || error("Docs dependency $name: expected $(spec["rev"]), found $actual")
    push!(packages, PackageSpec(path=path))
end
project = joinpath(@__DIR__, "Project.toml")
original = read(project, String)
try
    Pkg.develop(packages)
    Pkg.instantiate()
finally
    # Transitive source paths belong in the generated Manifest, not in deps.
    write(project, original)
end
