module TreebarsTests
using Test, Treebars, Random, TestModules
include("TreebarsTests.jl")
end

using TestModules
runtests!(TreebarsTests)
