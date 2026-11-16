using Documenter, DocumenterVitepress, Treebars

include("pages.jl")
include("lint.jl")
lint_docs(pages)

makedocs(
    sitename = "Treebars.jl",
    modules  = [Treebars],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/Treebars.jl",
        devurl = "dev",
        devbranch = "main",
    ),
    pages = pages,
    checkdocs = :exports,
    warnonly = false,
)

# Ensure a root index.html redirect exists for when no stable version is deployed
let redirect = joinpath(@__DIR__, "build", "index.html")
    isfile(redirect) || write(redirect, """
    <!DOCTYPE html>
    <html><head>
    <meta http-equiv="refresh" content="0; url=dev/">
    </head><body>Redirecting to <a href="dev/">dev</a>...</body></html>
    """)
end

DocumenterVitepress.deploydocs(
    repo = "github.com/nsiccha/Treebars.jl",
    devbranch = "main",
    push_preview = true,
)
