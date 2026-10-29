using TestItemRunner

# A landing that adds public API bumps the patch version and adds its entry
# under a new heading at the top of CHANGELOG.md (the global policy in `dev`
# §7.5), so a dependant can state that version as its [compat] floor. Two
# landings that bump at once then collide on that heading, never on a shared
# number.
@testitem "CHANGELOG.md's newest version is Project.toml's version" tags=[:unit] begin
    import TOML
    root = pkgdir(Treebars)
    version = VersionNumber(TOML.parsefile(joinpath(root, "Project.toml"))["version"])
    # eachline strips "\n" and "\r\n" alike: a Windows checkout writes CRLF.
    matches = (match(r"^## (\d+\.\d+\.\d+)\s*$", line) for line in eachline(joinpath(root, "CHANGELOG.md")))
    headings = [VersionNumber(m[1]) for m in matches if m !== nothing]
    @test !isempty(headings)
    @test first(headings) == version
    @test allunique(headings)
    @test issorted(headings; rev=true)
end
