# Web reference

The HTML APIs require HTMXObjects. WebSocket transport also requires HTTP.
The [monitoring guide](monitoring.md) describes how views relate to the work
that owns a progress tree.

## HTML trees

```@docs
htmx_render
htmx_render_children
htmx_treebar_styles
htmx_treebar_script
```

## Polling and WebSockets

```@docs
polling_fetchindex
ws_progress
htmx_ws_render
htmx_ws_progress
```

## Job boards

```@docs
htmx_render_board
htmx_ws_render_board
ws_board
```

## Language and messages

```@docs
TreebarTexts
treebar_texts
TreebarNotes
TreebarNote
treebar_notes
treebar_note
```

A package can declare messages independently of their display language.
Text output uses English; HTML selects its language at render time.

```@example notes
using Treebars
notes = treebar_notes(
    en=(loaded="Loaded {size}",),
    de=(loaded="{size} geladen",),
)
tree = with_progress(:state; description="Input") do p
    update_progress!(p, notes(:loaded; size=ByteSize(4096)))
    p
end
println(render_text(tree))
```
