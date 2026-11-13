using PrecompileTools: @compile_workload

@compile_workload begin
    node = Treebars._precompile_tree()
    node_to_html(htmx_render(node))
    node_to_html(htmx_render_children(node))
    for texts in (Treebars.treebar_texts(:en), Treebars.treebar_texts(:de))
        node_to_html(htmx_render(node; texts, phase_overview=true))
    end
    finalize_progress!(node)
    node_to_html(htmx_render(node))
end
