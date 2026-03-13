using Documenter, DocumenterVitepress, Treebars

makedocs(
    sitename = "Treebars.jl",
    modules  = [Treebars],
    format   = DocumenterVitepress.MarkdownVitepress(
        repo = "github.com/nsiccha/Treebars.jl",
        devurl = "dev",
    ),
    pages = [
        "Home" => "index.md",
        "Usage" => "usage.md",
        "Backends" => "backends.md",
        "API"  => "api.md",
    ],
    checkdocs = :none,
    warnonly = true,
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
