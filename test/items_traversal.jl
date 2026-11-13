using TestItemRunner

@testitem "display traversal preserves first-seen DAG placement" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    function old_flatten(node)
        out = ProgressNode[]
        for child in node.children
            Treebars._renders_self(child) ? push!(out, child) : append!(out, old_flatten(child))
        end
        out
    end
    function placements(root, reference)
        walk = Treebars._DisplayTraversal()
        push!(walk.seen, root)
        result = []
        function visit(node)
            children = reference ? filter(c -> Treebars._first_seen!(walk.seen, c), old_flatten(node)) :
                first(Treebars._displayed_children(node, walk))
            push!(result, (node, children))
            foreach(visit, children)
        end
        visit(root)
        result
    end
    rng = MersenneTwister(419)
    for _ in 1:100
        nodes = [ProgressNode(StateProgress(description="node $i"), (; displayed=rand(rng, Bool))) for i in 1:20]
        for i in 1:19, j in i+1:20
            rand(rng) < 0.25 && add_child!(nodes[i], nodes[j])
        end
        @test placements(first(nodes), false) == placements(first(nodes), true)
    end

    # A hidden shared leaf is genuinely empty at both parents. It must not be
    # mistaken for a duplicate visible branch and lose the starting indicator.
    root = initialize_progress!(:state; description="root")
    a = initialize_progress!(root; description="a")
    b = initialize_progress!(root; description="b")
    hidden = initialize_progress!(a; description="hidden", displayed=false)
    add_child!(b, hidden)
    html = sprint(show, MIME"text/html"(), htmx_render(root))
    @test count("Starting...", html) == 2
end

@testitem "transparent traversal scales with the unique graph and handles cycles" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    hidden() = ProgressNode(StateProgress(), (; displayed=false))
    root = hidden()
    previous = [root]
    for _ in 1:20
        layer = [hidden(), hidden()]
        for p in previous, child in layer
            add_child!(p, child)
        end
        previous = layer
    end
    leaf = ProgressNode(StateProgress(description="unique leaf"))
    foreach(p -> add_child!(p, leaf), previous)
    @test Treebars._flatten_displayed_children(root) == [leaf]
    # Old expansion allocated a vector for each of over a million paths.
    @test @allocated(Treebars._flatten_displayed_children(root)) < 1_000_000
    @test count("unique leaf", render_text(root)) == 1
    @test count("unique leaf", sprint(show, MIME"text/html"(), htmx_render_children(root))) == 1

    chain = hidden()
    tail = chain
    for _ in 1:10_000
        next = hidden()
        add_child!(tail, next)
        tail = next
    end
    add_child!(tail, leaf)
    add_child!(tail, chain)
    @test Treebars._flatten_displayed_children(chain) == [leaf]
    @test count("unique leaf", render_text(chain)) == 1
    end
end
