using TestModules
include("TreebarsTests.jl")
using .TreebarsTests

runtests!(TreebarsTests)
