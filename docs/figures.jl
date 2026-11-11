# Minimal build adapter until DocsKit supplies the shared Documenter bridge.
# The renderer and its theme behavior are AlgebraOfVega's public runtime.
struct DocsFigure
    src::String
    id::String
    caption::String
end

function docs_figure(spec, id; caption)
    figures = joinpath(pwd(), "public", "figures")
    vendor = joinpath(pwd(), "public", "aov")
    mkpath(figures)
    if !isdir(vendor)
        cp(AlgebraOfVega.vega_vendor_dir(), vendor)
    end
    write(joinpath(figures, id * ".json"), AlgebraOfVega.to_json(spec))
    DocsFigure("figures/$id.json", id, caption)
end

function Base.show(io::IO, ::MIME"text/markdown", figure::DocsFigure)
    escape(s) = replace(s, '&' => "&amp;", '"' => "&quot;", '<' => "&lt;", '>' => "&gt;")
    print(io, "<VegaFigure src=\"", escape(figure.src), "\" plot-id=\"",
        escape(figure.id), "\" caption=\"", escape(figure.caption), "\" />")
end
