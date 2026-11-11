"Check the documentation contract before executing a build."
function lint_docs(pages)
    first.(pages) == ["Start", "Guides", "Examples", "Reference"] ||
        error("Navigation must be Start, Guides, Examples, Reference")
    listed = [last(page) for group in pages for page in last(group)]
    length(unique(listed)) == length(listed) || error("A page belongs to more than one group")
    source = joinpath(@__DIR__, "src")
    actual = filter(name -> endswith(name, ".md"), readdir(source))
    sort(listed) == sort(actual) || error("Navigation and source pages differ")
    banned = r"\b(seamless|robust|powerful|leverage|delve|crucial|comprehensive|unlock|simply)\b|it's worth noting"i
    for (group, entries) in pages, (_, file) in entries
        text = read(joinpath(source, file), String)
        # A source word count includes code; rendered counts are measured separately.
        words = length(split(text))
        println("DOCS_LINT page=$file group=$group source_words=$words")
        for fence in eachmatch(r"(?m)^```([^\n]*)", text)
            language = strip(fence.captures[1])
            isempty(language) && continue  # closing fence
            (startswith(language, "@") || language in ("sh", "bash", "shell")) ||
                error("Static runnable fence in $file: $language")
        end
        prose = replace(text, r"(?ms)^```.*?^```\s*$" => "")
        occursin(banned, prose) && error("Banned prose in $file")
        occursin("**", prose) && error("Bold prose in $file")
        if group == "Guides"
            words < 1500 || error("Guide exceeds 1,500 source words: $file")
        elseif group == "Examples"
            800 <= words <= 1500 || error("Example outside 800–1,500 source words: $file ($words)")
            occursin(r"```@(example|repl|eval)\b", text) || error("No executed block: $file")
            occursin("docs_figure(", text) || error("No build-generated figure: $file")
            occursin("<details><summary>Environment and commands</summary>", text) ||
                error("Missing Reproduce footer: $file")
        end
    end
    tracked = split(readchomp(`git -C $(@__DIR__) ls-files`), '\n')
    generated = filter(f -> occursin(r"\.(png|jpe?g|gif|mp4|webm|pdf)$"i, f), tracked)
    isempty(generated) || error("Review committed regenerable docs assets: $(join(generated, ", "))")
    nothing
end
