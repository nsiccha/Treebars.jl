module TreebarsWeb

using HTMXObjects
using Treebars
import HTTP.WebSockets: send
using TestModules
using Random

include("test/runtests.jl")

node_to_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# Shared simulation helper. Used by async / nested / docstring / websockets
# features. Kept at module level because the real compute is ambient-independent
# (no AppData coupling) and four separate features invoke it — a shared
# module-level function stays DRY without forcing each XData to re-host it.
function fake_sampling(progress; n_steps=200, sleep_per_step=0.02)
    child = initialize_progress!(progress, n_steps; description="MCMC", propagates=true)
    result = Float64[]
    x = 0.0
    for i in 1:n_steps
        x += randn() * 0.1
        push!(result, x)
        update_progress!(child, i;
            current_value = short_string(x),
            acceptance_rate = short_string(Fraction(min(1.0, 0.5 + i / n_steps / 2))),
        )
        sleep(sleep_per_step)
    end
    finalize_progress!(child)
    result
end

# Shared render helpers — every result panel across async / nested / docstring /
# phases / websockets is "h.article(h.header(title), [summary p's...], [rerun])".
# Keep the structure in one place; pass `rerun_url=nothing` to skip the button
# (used by the WS-final article since the form replays the same key).

"`Rerun` button that re-fires `rerun_url` with `?force=true` (plus optional extra query params) and replaces the closest article."
rerun_button(rerun_url; extra_query...) = h.button("Rerun";
    hx_get = string(query_url(rerun_url; force=true, extra_query...)),
    hx_target = "closest article",
    hx_swap = "outerHTML",
)

"Sample-summary `<p>` for a Float64 trace produced by `fake_sampling`."
sample_summary(rv) = h.p("Computed $(length(rv)) values. Final: $(short_string(rv[end]))")

"Min/max `<p>` for a Float64 trace produced by `fake_sampling`."
sample_minmax(rv) = h.p("Min: $(short_string(minimum(rv))), Max: $(short_string(maximum(rv)))")

"Standard result article: header + body children + (optional) rerun button. Pass `rerun_url=nothing` to omit the button."
result_article(title, body...; rerun_url=nothing) = h.article(
    h.header(title), body...,
    rerun_url === nothing ? "" : rerun_button(rerun_url),
)

# Demo-index input form helpers. The index page wires ~7 single-key/param input
# fieldsets, each with the same shape: <fieldset role=group> with <input> + <button>,
# where the button's hx-get points at `url_prefix/<input value>` and a hyperscript
# `_=` hook rewrites @hx-get on click using the current input value(s). Pulled
# out so the index reads as a list of inputs, not as repeated boilerplate.

"Single-key input + run button. Wires `_=` so the button rebuilds `url_prefix/<value>` on click before HTMX fires."
key_input_form(button_text, url_prefix, key_id, key_value, target_id) = h.fieldset(; role="group")(
    h.input(; type="text", id=key_id, value=key_value, placeholder="Key"),
    h.button(button_text;
        hx_get = "$url_prefix/$key_value",
        hx_target = "#$target_id",
        hx_swap = "innerHTML",
        _ = "on click set my @hx-get to '$url_prefix/' + #$key_id.value",
    ),
)

"Two-number-param input + run button. Wires `_=` so the button rebuilds `url_prefix/<steps>/<sleep>` on click."
param_input_form(button_text, url_prefix, steps_id, sleep_id, target_id;
                 steps_default=100, sleep_default=20) = h.fieldset(; role="group")(
    h.input(; type="number", id=steps_id, value=string(steps_default), placeholder="Steps", class="tb-input-narrow"),
    h.input(; type="number", id=sleep_id, value=string(sleep_default), placeholder="ms", class="tb-input-narrow"),
    h.button(button_text;
        hx_get = "$url_prefix/$steps_default/$sleep_default",
        hx_target = "#$target_id",
        hx_swap = "innerHTML",
        _ = "on click set my @hx-get to '$url_prefix/' + #$steps_id.value + '/' + #$sleep_id.value",
    ),
)

include("async.jl")
include("nested.jl")
include("phases.jl")
include("docstring.jl")
include("autocleanup.jl")
include("pills.jl")
include("websockets.jl")

@dynamicstruct struct AppData
    async       = AsyncComputationsData()
    nested      = NestedData()
    phases      = PhasesData()
    docstring   = DocstringData()
    autocleanup = AutocleanupData()
    pills       = PillDemosData()
    websockets  = WebSocketsData()
end

const APPDATA = AppData()

@htmx struct AppRoutes
    __appdata__ = APPDATA

    # Adopts the proposed `HTMXObjects.pico_page` helper (see
    # proposals/by-app/dynamicobjects/pico-page-helper.md). Treebars is a consumer
    # because its only customization is `extra_head`, which the helper supports.
    __page__(content) = HTMXObjects.pico_page(content;
        extra_head = (
            h.title("Treebars Demo"),
            h.script(; src="https://unpkg.com/htmx-ext-ws@2.0.2/ws.js"),
            htmx_treebar_styles(),
            htmx_treebar_script(),
        ),
    )

    @include tests = TestRoutes(; __req__, test_module=@__MODULE__)
    @include async       = AsyncComputationsRoutes()
    @include nested      = NestedRoutes()
    @include phases      = PhasesRoutes()
    @include dsdemo      = DocstringRoutes()
    @include autocleanup = AutocleanupRoutes()
    @include pills       = PillDemosRoutes()
    @include websockets  = WebSocketsRoutes()

    @get index = h.div(
        h.h1("Treebars Web Demo"),
        h.p(h.a(href="/tests")("Tests"), " | ",
            h.a(href="/pills")("Pill demos"), " | ",
            h.a(href="/autocleanup")("Auto-cleanup demo"),
            " | HTTP polling, WebSockets, inline child substatus, phase markers."),

        h.hr(),
        h.h3("0. @progress phase markers + pending state"),
        h.p("All phases (Load / Preprocess / Fit / Evaluate / Save) are pre-enumerated as ",
            h.em("pending"), " children — they appear greyed-out from the outset and transition pending → running → done as execution reaches each marker.";
            class="u-text-sm u-text-muted"),
        h.div(key_input_form("Run pipeline", "/phases/demo", "macro-key", "macro-demo", "macro-result")),
        h.div(; id="macro-result"),

        h.hr(),
        h.h3("0b. Dynamic phases (with_prepared_phases + with_prepared_progress)"),
        h.p("Runtime-computed NamedTuple chain using the data-driven phase primitives. ",
            "Toggle fail-at to watch the outer handler fail any still-pending phases instead of orphaning them.";
            class="u-text-sm u-text-muted"),
        h.div(
            h.fieldset(; role="group")(
                h.select(; id="dyn-preset")(
                    h.option("short"; value="short"),
                    h.option("medium"; value="medium", selected=""),
                    h.option("long"; value="long"),
                ),
                h.select(; id="dyn-fail")(
                    h.option("no failure"; value=""),
                    h.option("fail at :train"; value="train"),
                    h.option("fail at :analyze"; value="analyze"),
                    h.option("fail at :process"; value="process"),
                ),
                h.button("Run dynamic"; hx_get="/phases/dynamic/medium",
                    hx_target="#dynamic-result", hx_swap="innerHTML",
                    _="on click set my @hx-get to '/phases/dynamic/' + #dyn-preset.value + '?fail_at=' + #dyn-fail.value"),
            ),
        ),
        h.div(; id="dynamic-result"),

        h.hr(),
        h.h3("1. HTTP polling"),
        h.p("Client polls every 200ms via hx-get + hx-trigger."; class="u-text-sm u-text-muted"),
        h.div(key_input_form("Run (polling)", "/async/compute", "poll-key", "poll-demo", "poll-result")),
        h.div(; id="poll-result"),

        h.hr(),
        h.h3("2. WebSocket (server push)"),
        h.p("Server pushes HTML updates over a persistent connection."; class="u-text-sm u-text-muted"),
        h.div(; hx_ext="ws", ws_connect="/websockets/ws")(
            h.form(; ws_send="true")(
                h.fieldset(; role="group")(
                    h.input(; type="text", name="key", value="ws-demo", placeholder="Key"),
                    h.button("Run (websocket)"; type="submit"),
                ),
            ),
        ),
        h.div(; id="ws-result"),

        h.hr(),
        h.h3("3. Inline child substatus"),
        h.p("Inline Sub struct gets its own ProgressNode under the parent's status. No manual __substatus__ needed."; class="u-text-sm u-text-muted"),
        h.div(key_input_form("Run (nested)", "/nested/compute", "nested-key", "nested-demo", "nested-result")),
        h.div(; id="nested-result"),

        h.hr(),
        h.h3("4. Docstring descriptions"),
        h.p("Left: auto description (\"results[key]\"). Right: docstring description (\"Sampling chain\")."; class="u-text-sm u-text-muted"),
        h.div(; class="u-grid-2")(
            h.div(
                h.h5("Without docstring"),
                key_input_form("Run", "/async/compute", "doc-cmp-key", "compare", "doc-cmp-left"),
                h.div(; id="doc-cmp-left"),
            ),
            h.div(
                h.h5("With docstring"),
                key_input_form("Run", "/dsdemo/compute", "doc-cmp-key2", "compare", "doc-cmp-right"),
                h.div(; id="doc-cmp-right"),
            ),
        ),
        h.p("Interpolated: auto shows \"parameterized[100,0.02]\", docstring shows \"Sampling 100 steps at 0.02s intervals\"."; class="u-text-sm u-text-muted u-mt-2"),
        h.div(; class="u-grid-2")(
            h.div(
                h.h5("Without docstring"),
                param_input_form("Run", "/async/param", "doc-steps-l", "doc-sleep-l", "doc-param-left"),
                h.div(; id="doc-param-left"),
            ),
            h.div(
                h.h5("With docstring"),
                param_input_form("Run", "/dsdemo/param", "doc-steps-r", "doc-sleep-r", "doc-param-right"),
                h.div(; id="doc-param-right"),
            ),
        ),

        h.hr(),
        h.h3("5. WebSocket with kwargs"),
        h.p("Kwargs from query string."; class="u-text-sm u-text-muted"),
        h.form(; _="on submit halt the event then set key to #param-key.value then set steps to #param-steps.value then set spd to #param-speed.value then set url to '/websockets/run?key=' + key + '&n_steps=' + steps + '&speed=' + spd then set #param-ws-container @ws-connect to url then js(htmx) htmx.process(document.getElementById('param-ws-container'))")(
            h.fieldset(; role="group")(
                h.input(; type="text", id="param-key", value="param-demo", placeholder="Key"),
                h.input(; type="number", id="param-steps", value="100", placeholder="Steps", class="tb-input-narrow"),
                h.input(; type="number", id="param-speed", value="20", placeholder="Speed (ms)", class="tb-input-narrow-7"),
                h.button("Run"; type="submit"),
            ),
        ),
        h.div(; id="param-ws-container", hx_ext="ws"),
        h.div(; id="ws-param-result"),
    )
end

function __init__()
    route!(AppRoutes())
end

end # module TreebarsWeb
