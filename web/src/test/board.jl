using Treebars
import HTTP, Sockets

# Keyed board (`htmx_render_board`): the server-side HTML contract the client
# reconciler relies on, the WebSocket push loop, the job-ledger hook in
# `polling_fetchindex`, and (opt-in, headless Chrome) the reconciler itself.

_board_html(node) = sprint(io -> show(io, MIME"text/html"(), node))

# The fragment of `html` that belongs to the board item with `key`, up to the
# next item (items are siblings, so this never bleeds into another item).
function _board_item_html(html, key)
    start = findfirst("data-treebar-key=\"$key\"", html)
    start === nothing && return nothing
    rest = html[first(start):end]
    stop = findnext("class=\"treebar-board-item\"", rest, 2)
    stop === nothing ? rest : rest[1:first(stop)-1]
end

const _BOARD_GATE = Ref(Base.Event())

@dynamicstruct struct _BoardTrackTest
    __status__ = initialize_progress!(:state; description="BoardTrack")
    "Gated board work"
    gated(key) = (wait(_BOARD_GATE[]); key)
end

@testset "htmx_render_board render shape" begin
    root = initialize_progress!(:state; description="Fit")
    done_child = initialize_progress!(root; description="load")
    finalize_progress!(done_child)
    fit = initialize_progress!(root, 10; description="chains")
    update_progress!(fit, 3)

    entries = [
        (; key="a", label="Fit <model>", state=:running, elapsed_ms=4200, node=root,
           meta=(route="GET /fit/{m}", polls=3, empty="")),
        (; key=2, label="Waiting", state=:queued, elapsed_ms=50, meta=["position" => 3, "route" => "GET /q"]),
        (; key="c", label="Finished", state=:done, elapsed_ms=65_000, node=root, href="/r?a=1&b=2"),
        (; key="d", label="Broken", state=:failed, elapsed_ms=1500.4, meta=Dict(:reason => "boom")),
        (; key="a", label="duplicate key", state=:failed, elapsed_ms=1),
    ]
    html = _board_html(htmx_render_board(entries; id="jobs"))

    # Stable, keyed item wrappers in server order; first occurrence of a key wins.
    @test count("class=\"treebar-board-item\"", html) == 4
    keys = [m.captures[1] for m in eachmatch(r"data-treebar-key=\"([^\"]*)\"", html)]
    @test keys == ["a", "2", "c", "d"]
    @test !occursin("duplicate key", html)
    states = [m.captures[1] for m in eachmatch(r"data-treebar-state=\"([^\"]*)\"", html)]
    @test states == ["running", "queued", "done", "failed"]

    # UI state lives on the wrapper, like `.treebar-poller`: pill toggles and
    # the tree's expansion. The content the client swaps is a separate child.
    a = _board_item_html(html, "a")
    @test occursin("<div class=\"treebar-board-item\" data-treebar-key=\"a\" data-treebar-state=\"running\" data-open=\"0\" data-show-finished=\"0\" data-show-pending=\"1\" data-show-failed=\"1\" data-show-skipped=\"0\"><div class=\"treebar-board-item-content\">", html)
    @test count("treebar-board-item-content", html) == 4
    # The tree renders unscoped (the wrapper governs the pills) in a collapsed
    # <details> under the header.
    @test occursin("<details class=\"treebar-board-tree\"><summary>Progress</summary>", a)
    @test occursin("treebar-children", a) && !occursin("data-show-finished=\"0\"><div class=\"treebar-pills\"", a)
    @test occursin("1 finished", a)
    @test occursin("chains:", a)
    # The pill toggles the nearest wrapper, poller or board item.
    @test occursin("closest(&#39;.treebar-poller, .treebar-board-item&#39;)", a)
    # Label is escaped; the header ticks through the ordinary duration contract.
    @test occursin("<strong class=\"treebar-board-label\">Fit &lt;model&gt;</strong>", a)
    @test occursin("class=\"treebar-duration treebar-board-duration\" data-treebar-status=\"running\" data-elapsed-ms=\"4200\"> — 4.2s so far", a)
    # Meta pairs; blank values are dropped.
    @test occursin("<span class=\"treebar-board-meta-key\">route</span> GET /fit/{m}", a)
    @test occursin("<span class=\"treebar-board-meta-key\">polls</span> 3", a)
    @test !occursin(">empty<", a)

    # `node === nothing`: header only, no tree.
    q = _board_item_html(html, "2")
    @test !occursin("<details", q)
    # Queued reads like a pending node — no clock, just the queue position,
    # which is not repeated as a meta item.
    @test occursin("data-treebar-status=\"pending\"> — queued · #3</span>", q)
    @test !occursin("data-elapsed-ms", q)
    @test !occursin(">position<", q)
    @test occursin("<span class=\"treebar-board-meta-key\">route</span> GET /q", q)

    # Terminal items: final state + total time; the kept tree is frozen so a
    # node it still holds as running does not tick.
    c = _board_item_html(html, "c")
    @test occursin("data-treebar-status=\"finished\" data-elapsed-ms=\"65000\"> — done (1m 5s)", c)
    @test occursin("<details class=\"treebar-board-tree treebar-frozen\">", c)
    @test occursin("<a class=\"treebar-board-label\" href=\"/r?a=1&amp;b=2\">Finished</a>", c)
    d = _board_item_html(html, "d")
    @test occursin("data-treebar-status=\"failed\" data-elapsed-ms=\"1500\"> — failed (1.5s)", d)
    @test occursin("<span class=\"treebar-board-meta-key\">reason</span> boom", d)

    # Header count and board attributes; the empty note is present but hidden.
    @test occursin("<span class=\"treebar-board-count\" data-running=\"1\" data-queued=\"1\">1 running · 1 queued</span>", html)
    @test occursin("<div class=\"treebar-board\" id=\"jobs\" data-paused=\"0\" data-treebar-linger-ms=\"3000\">", html)
    @test occursin(r"<p class=\"treebar-board-empty\" hidden[^>]*>No running jobs.</p>", html)

    # Expanded default opens every tree and records it on the wrapper.
    open_html = _board_html(htmx_render_board(entries[1:1]; expanded=true, linger_ms=250))
    @test occursin("data-open=\"1\"", open_html)
    @test occursin("<details class=\"treebar-board-tree\" open", open_html)
    @test occursin("data-treebar-linger-ms=\"250\"", open_html)

    # Empty board: visible empty note, zero count.
    empty_html = _board_html(htmx_render_board([]; empty="Nothing to see."))
    @test occursin("<p class=\"treebar-board-empty\">Nothing to see.</p>", empty_html)
    @test occursin("0 running", empty_html)
    @test !occursin("treebar-board-item", empty_html)

    # Unknown states are a caller bug.
    @test_throws ArgumentError htmx_render_board([(; key=1, label="x", state=:paused, elapsed_ms=0)])

    finalize_progress!(root)
end

@testset "htmx_render_board polling and pause contract" begin
    entries = [(; key=1, label="one", state=:running, elapsed_ms=10)]

    # Polled board: a dedicated poll element (never the board or an item, so
    # its hx-* attributes are not inherited by item content). Its target/select
    # describe the no-script fallback — replace the whole board — which the
    # client script intercepts to reconcile by key instead.
    html = _board_html(htmx_render_board(entries; poll_url="/jobs?state=running&x=1",
                                         poll_interval="2s", id="my-board"))
    @test occursin("<div class=\"treebar-board-poll\" hx-get=\"/jobs?state=running&amp;x=1\" hx-trigger=\"every 2s\" hx-target=\"closest .treebar-board\" hx-swap=\"outerHTML\" hx-select=\"#my-board\"></div>", html)
    @test count("hx-get", html) == 1
    # A live board shows Pause; it toggles data-paused on the board.
    @test occursin("<button class=\"treebar-board-pause\" type=\"button\"", html)
    @test occursin("b.dataset.paused=v", html)

    # Static board: no poll element, no Pause; `live=true` forces Pause (push).
    static = _board_html(htmx_render_board(entries))
    @test !occursin("treebar-board-poll", static)
    @test !occursin("treebar-board-pause", static)
    @test occursin("treebar-board-pause", _board_html(htmx_render_board(entries; live=true)))

    # Pause suppresses board polls: the client cancels a board poll request
    # while its board is data-paused, drops a response that raced the pause,
    # and freezes its clocks — the same mechanism as `.treebar-pause`.
    script = _board_html(htmx_treebar_script())
    before_request = script[findfirst("htmx:beforeRequest", script)[1]:end]
    @test occursin("el.classList.contains(&#39;treebar-board-poll&#39;)", before_request) ||
          occursin("el.classList.contains('treebar-board-poll')", before_request)
    @test occursin("closest('.treebar-board')", script) || occursin("closest(&#39;.treebar-board&#39;)", script)
    @test occursin("evt.preventDefault()", before_request)
    @test occursin("b.dataset.paused === '1'", script) || occursin("b.dataset.paused === &#39;1&#39;", script)

    # The reconciler's entry points: the poll swap hook (requester read from
    # requestConfig — detail.elt is the target), the htmx ws frame hook, and
    # the public function for other transports.
    for marker in ("htmx:beforeSwap", "requestConfig", "d.shouldSwap = false",
                   "htmx:wsBeforeMessage", "window.treebarUpdateBoard",
                   "data-treebar-key", "treebar-board-item-content", "treebarLingerMs")
        @test occursin(marker, replace(script, "&#39;" => "'"))
    end

    # Styles cover the board and route pill state through the item wrapper.
    styles = _board_html(htmx_treebar_styles())
    @test occursin(".treebar-board-item[data-show-finished=\"0\"]", styles)
    @test occursin(".treebar-board-item[data-treebar-state=\"queued\"]", styles)
    @test occursin(".treebar-board-empty[hidden]", styles)
end

@testset "board over WebSocket pushes full snapshots" begin
    frame = htmx_ws_render_board([(; key=7, label="seven", state=:running, elapsed_ms=5)];
                                 id="ws-board", poll_url="/ignored")
    @test frame isa String
    @test occursin("id=\"ws-board\"", frame)
    @test !occursin("treebar-board-poll", frame)   # pushed, never polled
    @test occursin("treebar-board-pause", frame)

    # ws_board: calls `entries()` each round and stops after `until()`.
    rounds = Ref(0)
    entries() = (rounds[] += 1; [(; key=rounds[], label="round $(rounds[])", state=:running, elapsed_ms=0)])
    received = String[]
    socket = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(socket)[2])
    close(socket)
    server = HTTP.WebSockets.listen!("127.0.0.1", port) do ws
        ws_board(ws, entries; interval=0.01, until=() -> rounds[] >= 2, id="ws-board")
    end
    try
        HTTP.WebSockets.open("ws://127.0.0.1:$port") do ws
            for msg in ws
                push!(received, String(msg))
                length(received) == 3 && break
            end
        end
    catch err
        # The server closes after the final frame; the client loop may see it.
        err isa HTTP.WebSockets.WebSocketError || rethrow()
    finally
        close(server)
    end
    @test length(received) == 3
    @test all(f -> occursin("id=\"ws-board\"", f), received)
    @test occursin("data-treebar-key=\"1\"", received[1])
    @test occursin("data-treebar-key=\"3\"", received[3])
end

@testset "polling_fetchindex reports in-flight work to the job ledger" begin
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    @test ext !== nothing

    # Label: the caller's label, else the tree's description, else the IP name
    # — never the cache keys (request data).
    tree = initialize_progress!(:state; description="Tree label")
    @test ext._track_job_label("Given", tree, nothing) == "Given"
    @test ext._track_job_label(nothing, tree, nothing) == "Tree label"
    @test ext._track_job_label(nothing, nothing, :no_ip) == "Job"
    finalize_progress!(tree)

    _BOARD_GATE[] = Base.Event()
    app = _BoardTrackTest()
    ledger = isdefined(HTMXObjects, :track_job!) && isdefined(HTMXObjects, :runtime_jobs)
    tracker = ledger ? HTMXObjects.runtime_tracker() : nothing
    mine(label) = ledger ? filter(j -> j.label == label, HTMXObjects.runtime_jobs(tracker)) : []
    try
        # An unresolved handle emits a poller and — when this HTMXObjects has
        # the ledger — one running job, counted once more per follow-up poll.
        running = _board_html(polling_fetchindex(identity, app.gated, :k1; poll_url="/p", label="Board job"))
        @test occursin("treebar-poller-inner", running)
        if ledger
            job = only(mine("Board job"))
            @test job.state === :running
            @test job.progress !== nothing
            polling_fetchindex(identity, app.gated, :k1; poll_url="/p", label="Board job")
            @test only(mine("Board job")).polls == 1
        end
        # `track_job=false` (HTMXObjects' own transport) records nothing.
        polling_fetchindex(identity, app.gated, :k2; poll_url="/p", label="Untracked job", track_job=false)
        @test isempty(mine("Untracked job"))
        # A ledger that cannot take the handle never breaks the poller.
        @test ext._track_job(:not_a_handle, nothing, app.gated; label="odd") === nothing
    finally
        notify(_BOARD_GATE[])
    end
    ledger && @test timedwait(() -> isempty(mine("Board job")) ||
                              only(mine("Board job")).state !== :running, 10.0) === :ok
    finalize_progress!(app.__status__)
end

# Drives the reconciler in headless Chrome, HTMXObjects-style (opt in with
# TREEBARS_BROWSER_TESTS=1; needs google-chrome or chromium on PATH). No htmx
# and no server: the page applies successive full snapshots through
# `window.treebarUpdateBoard` — the entry point every transport shares — and
# writes what it observed into #result, which `--dump-dom` returns.
@testset "board reconciler keeps wrappers and terminalizes in a browser" begin
    if get(ENV, "TREEBARS_BROWSER_TESTS", "") != "1"
        @test_skip true
    else
        chrome = Sys.which("google-chrome")
        isnothing(chrome) && (chrome = Sys.which("chromium"))
        isnothing(chrome) && error("TREEBARS_BROWSER_TESTS=1 requires google-chrome or chromium")

        root = initialize_progress!(:state; description="A tree")
        finalize_progress!(initialize_progress!(root; description="loaded"))
        initialize_progress!(root, 10; description="fitting")
        run(key; node=nothing) = (; key, label="Job $key", state=:running, elapsed_ms=1000, node)
        fin(key, state) = (; key, label="Job $key", state, elapsed_ms=2000)
        snap(es) = htmx_ws_render_board(es; id="b", linger_ms=300)
        snapshots = [
            snap([run("A"; node=root), run("C"), run("B")]),          # 1: C inserted mid-list
            snap([run("A"; node=root), run("C"), fin("B", :done)]),   # 2: B terminal
            snap([run("A"; node=root)]),                              # 3: C and B leave
            snap([run("A"; node=root), fin("B", :done)]),             # 4: B listed again
            snap([run("A"; node=root), run("D")]),                    # 5: while paused
        ]
        literal(s) = "'" * replace(s, "\\" => "\\\\", "'" => "\\'", "\n" => "\\n", "</" => "<\\/") * "'"
        driver = """
        window.addEventListener('load', function(){
          var S = [$(join(map(literal, snapshots), ","))];
          var r = {};
          var q = function(k){ return document.querySelector('.treebar-board-item[data-treebar-key="' + k + '"]'); };
          var dur = function(k){ return q(k).querySelector('.treebar-board-duration').textContent; };
          var a = q('A');
          a._mark = 1;
          a.querySelector('details').open = true;
          a.querySelector('.treebar-pill-finished').click();
          setTimeout(function(){
            treebarUpdateBoard(S[0]);
            r.order = Array.prototype.map.call(document.querySelectorAll('.treebar-board-item'), function(e){ return e.dataset.treebarKey; }).join('');
            r.same = q('A')._mark === 1 ? 1 : 0;
            r.open = q('A').querySelector('details').open && q('A').dataset.open === '1' ? 1 : 0;
            r.pill = q('A').dataset.showFinished;
            r.t0 = dur('A');
          }, 50);
          setTimeout(function(){
            r.t1 = dur('A');
            treebarUpdateBoard(S[1]);
            r.bdone = q('B').dataset.treebarState + '|' + dur('B');
          }, 500);
          setTimeout(function(){
            r.bstays = q('B') ? 1 : 0;
            treebarUpdateBoard(S[2]);
            r.cended = q('C').dataset.treebarState + '|' + dur('C');
            r.blinger = q('B') ? 1 : 0;
          }, 950);
          setTimeout(function(){
            r.gone = (q('B') ? 'B' : '') + (q('C') ? 'C' : '');
            treebarUpdateBoard(S[3]);
            r.back = q('B') ? 1 : 0;
            r.still = q('A')._mark === 1 && q('A').querySelector('details').open ? 1 : 0;
            document.querySelector('.treebar-board-pause').click();
            r.p0 = dur('A');
            treebarUpdateBoard(S[4]);
            r.paused = q('D') ? 1 : 0;
          }, 1500);
          setTimeout(function(){
            r.p1 = dur('A');
            document.querySelector('.treebar-board-pause').click();
            treebarUpdateBoard(S[4]);
            r.resumed = q('D') ? 1 : 0;
            r.count = document.querySelector('.treebar-board-count').textContent;
            var out = document.createElement('pre');
            out.id = 'result';
            out.textContent = Object.keys(r).map(function(k){ return k + '=' + r[k]; }).join(';');
            document.body.appendChild(out);
          }, 2100);
        });
        """
        page = "<!DOCTYPE html>" * _board_html(h.html(
            h.head(h.meta(charset="utf-8"), htmx_treebar_styles(), htmx_treebar_script()),
            h.body(htmx_render_board([run("A"; node=root), run("B")]; id="b", live=true, linger_ms=300),
                   h.script(Raw(driver)))))
        dir = mktempdir()
        file = joinpath(dir, "board.html")
        write(file, page)
        profile = joinpath(dir, "profile")
        cmd = `$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=5000 --dump-dom --user-data-dir=$profile file://$file`
        dom = read(pipeline(cmd; stderr=devnull), String)
        m = match(r"<pre id=\"result\">([^<]*)</pre>", dom)
        @test m !== nothing
        r = Dict(split(kv, '='; limit=2)[1] => split(kv, '='; limit=2)[2]
                 for kv in split(something(m, (; captures=[""])).captures[1], ';') if occursin('=', kv))
        @test get(r, "order", "") == "ACB"        # server order, C inserted mid-list
        @test get(r, "same", "") == "1"           # A's wrapper survived the update
        @test get(r, "open", "") == "1"           # …with its tree still expanded
        @test get(r, "pill", "") == "1"           # …and its pill toggle intact
        @test get(r, "t0", "") != get(r, "t1", "")  # the header ticks between updates
        @test startswith(get(r, "bdone", ""), "done|")
        @test occursin("done", get(r, "bdone", ""))
        @test startswith(get(r, "cended", ""), "ended|")
        @test occursin("ended", get(r, "cended", ""))
        @test get(r, "bstays", "") == "1"         # a listed done item stays
        @test get(r, "blinger", "") == "1"        # …lingers once it leaves the list
        @test get(r, "gone", "x") == ""           # …then both leave
        @test get(r, "back", "") == "1"           # listed again: the server decides
        @test get(r, "still", "") == "1"
        @test get(r, "p0", "") == get(r, "p1", "a") # paused clocks are frozen
        @test get(r, "paused", "") == "0"         # a paused board drops updates
        @test get(r, "resumed", "") == "1"
        @test get(r, "count", "") == "2 running"
        finalize_progress!(root)
    end
end
