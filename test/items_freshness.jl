using TestItemRunner

# Freshness of live progress regions (`htmx_treebar_script`, "Freshness"): a
# poller, a live board and a WebSocket source each say how old their shown
# state is, and that their connection is lost once updates have failed for a
# sustained stretch — never on one failed poll.

@testitem "Live regions carry a hidden freshness span for the script to fill" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    html(x) = repr(MIME"text/html"(), x)
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    span = "<span class=\"treebar-freshness\" hidden=\"true\"></span>"
    root = initialize_progress!(:state; description="Job", N=10)
    start_progress!(root)

    # A poller says it in its badge panel, beside the status word.
    running = html(ext._polling_running(root; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url=""))
    @test count(span, running) == 1
    @test occursin(">Polling</span>" * span, running)

    # A board says it in its header only while live; a static board has
    # nothing that could go stale.
    entries = [(; key=1, label="one", state=:running, elapsed_ms=10)]
    @test occursin("1 running</span>" * span, html(htmx_render_board(entries; poll_url="/jobs")))
    @test occursin(span, html(htmx_render_board(entries; live=true)))
    @test occursin(span, htmx_ws_render_board(entries))
    @test !occursin("treebar-freshness", html(htmx_render_board(entries)))

    # A WebSocket frame leads with it: when frames stop, the last one says so.
    @test occursin("data-show-reused=\"0\">" * span, htmx_ws_render(root; id="run-progress"))

    styles = html(htmx_treebar_styles())
    @test occursin(".treebar-freshness[hidden] { display: none; }", styles)
    @test occursin(".treebar-poller[data-treebar-freshness=\"lost\"] > .treebar-poller-inner", styles)
    finalize_progress!(root)
    end
end

@testitem "Freshness: stale age, durable connection loss, recovery (browser)" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    # Opt in with TREEBARS_BROWSER_TESTS=1 (needs google-chrome or chromium).
    # No htmx and no server: the page replays the events htmx 2.x and its ws
    # extension fire, with the same detail shapes, on a fixed schedule in
    # Chrome's virtual time (which also drives Date.now), and records what
    # each region shows. In particular, a successful poll REPLACES the
    # poller's inner before htmx fires afterRequest, so htmx re-fires it on
    # the wrapper with `requestConfig.elt` the detached inner; failures fire
    # on the still-attached requester. Verified against real htmx 2.0.8 and
    # htmx-ext-ws over a live HTTP.jl server (502 blip, a killed listener,
    # an abruptly dropped socket, recovery) on 2026-10-07.
    if get(ENV, "TREEBARS_BROWSER_TESTS", "") != "1"
        @test_skip true
    else
        chrome = Sys.which("google-chrome")
        isnothing(chrome) && (chrome = Sys.which("chromium"))
        isnothing(chrome) && error("TREEBARS_BROWSER_TESTS=1 requires google-chrome or chromium")
        html(x) = repr(MIME"text/html"(), x)
        ext = Base.get_extension(Treebars, :HTMXObjectsExt)
        job = initialize_progress!(:state; description="Job", N=10)
        start_progress!(job)
        stream = initialize_progress!(:state; description="Stream", N=10)
        start_progress!(stream)
        ended = initialize_progress!(:state; description="Ended")
        start_progress!(ended)
        finalize_progress!(ended)
        body = h.div(
            ext._polling_running(job; label="Background job", poll_url="/poll",
                poll_interval="200ms", cancel_url=""),
            htmx_render_board([(; key=1, label="one", state=:running, elapsed_ms=10)];
                poll_url="/jobs", poll_interval="1s", id="jobs"),
            htmx_ws_progress("Live"; url="ws://test/feed", id="live", progress=stream),
            htmx_ws_progress("Ended"; url="ws://test/done", id="done", progress=ended),
        )
        driver = raw"""
        var poller = document.querySelector('.treebar-poller');
        var board = document.getElementById('jobs');
        var boardPoll = board.querySelector('.treebar-board-poll');
        var live = document.querySelector('[ws-connect="ws://test/feed"]');
        var done = document.querySelector('[ws-connect="ws://test/done"]');
        function fire(el, name, detail){
            detail.elt = el;
            el.dispatchEvent(new CustomEvent(name, {bubbles: true, detail: detail}));
        }
        function pollOk(){
            var inner = poller.querySelector(':scope > .treebar-poller-inner');
            inner.replaceWith(inner.cloneNode(true));
            fire(poller, 'htmx:afterRequest', {successful: true, failed: false, requestConfig: {elt: inner}});
        }
        function pollFail(status){
            var inner = poller.querySelector(':scope > .treebar-poller-inner');
            if (status){
                fire(inner, 'htmx:responseError', {xhr: {status: status}, requestConfig: {elt: inner}});
                fire(inner, 'htmx:afterRequest', {xhr: {status: status}, successful: false, failed: true, requestConfig: {elt: inner}});
            } else {
                fire(inner, 'htmx:afterRequest', {requestConfig: {elt: inner}});
                fire(inner, 'htmx:sendError', {requestConfig: {elt: inner}});
            }
        }
        function boardOk(){ fire(boardPoll, 'htmx:afterRequest', {successful: true, failed: false, requestConfig: {elt: boardPoll}}); }
        function boardFail(){ fire(boardPoll, 'htmx:responseError', {xhr: {status: 404}, requestConfig: {elt: boardPoll}}); }
        function wsMessage(){ fire(live, 'htmx:wsAfterMessage', {message: ''}); }
        function wsDrop(){ fire(live, 'htmx:wsError', {error: {}}); fire(live, 'htmx:wsClose', {event: {code: 1006}}); }
        function every(from, to, step, fn){ for (var t = from; t < to; t += step) setTimeout(fn, t); }
        function at(t, fn){ setTimeout(fn, t); }
        // Poller (every 200ms): a two-poll 502 blip, then the server dies at
        // 3s (connection refused) and returns at 10s.
        every(0, 1000, 200, pollOk);
        at(1000, function(){ pollFail(502); }); at(1200, function(){ pollFail(502); });
        every(1400, 3000, 200, pollOk);
        every(3000, 10000, 200, function(){ pollFail(0); });
        every(10000, 11000, 200, pollOk);
        // Board (every 1s): its route answers 404 from 3s to 10s; the viewer
        // pauses it from 9s to 9.9s.
        every(0, 3000, 1000, boardOk);
        every(3000, 10000, 1000, boardFail);
        at(9000, function(){ board.dataset.paused = '1'; });
        at(9900, function(){ board.dataset.paused = '0'; });
        every(10000, 11000, 1000, boardOk);
        // WebSocket: frames until 2s, then the socket drops and reconnect
        // attempts fail until a frame arrives again at 9s. The other stream
        // ended normally after its last frame.
        every(0, 2000, 100, wsMessage);
        at(2000, function(){ fire(live, 'htmx:wsClose', {event: {code: 1006}}); });
        at(3000, wsDrop); at(5000, wsDrop);
        at(9000, wsMessage);
        at(1000, function(){ fire(done, 'htmx:wsClose', {event: {code: 1000}}); });
        var rows = [];
        function state(r){ return r.dataset.treebarFreshness || 'live'; }
        function text(sel){ var s = document.querySelector(sel); return s.hidden ? '' : s.textContent; }
        function sample(t){
            setTimeout(function(){
                rows.push([t, state(poller), text('.treebar-poller .treebar-freshness'),
                    state(board), text('#jobs .treebar-freshness'),
                    state(live), text('#live-progress > .treebar-freshness'), state(done),
                    getComputedStyle(poller.querySelector(':scope > .treebar-poller-inner')).opacity,
                    poller.querySelector('.treebar-poller-inner .treebar-duration').textContent,
                    live.querySelector('.treebar-duration').textContent].join('|'));
            }, t);
        }
        [1150, 2500, 6950, 7450, 7950, 8250, 9150, 9550, 10550].forEach(sample);
        setTimeout(function(){
            var out = document.createElement('pre'); out.id = 'result';
            out.textContent = rows.join('\n');
            document.body.appendChild(out);
        }, 11000);
        """
        dir = mktempdir()
        file = joinpath(dir, "freshness.html")
        write(file, "<!DOCTYPE html>" * html(h.html(
            h.head(h.meta(charset="utf-8"), htmx_treebar_styles(), htmx_treebar_script()),
            h.body(body, h.script(Raw(driver))))))
        profile = joinpath(dir, "profile")
        dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=12000 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
        result = match(r"<pre id=\"result\">([^<]*)</pre>", dom)
        @test result !== nothing
        rows = result === nothing ? Dict{Int,Vector{String}}() :
            Dict(parse(Int, first(r)) => r[2:end] for r in split.(split(result.captures[1], '\n'), '|'))
        row(t) = get(rows, t, fill("missing", 10))
        # 1.15s: a two-poll blip shows nothing.
        @test row(1150)[1:7] == ["live", "", "live", "", "live", "", "live"]
        # 2.5s: the socket dropped half a second ago (a blip so far); the
        # stream that ended normally stays settled for good.
        @test row(2500)[[1, 3, 5, 7]] == ["live", "live", "live", "live"]
        # 6.95s: the board's last update is 4.95s old — not yet stale. The
        # socket's last frame is 5.05s old — stale — but it has been failing
        # for only 4.95s, so not yet lost.
        @test row(6950)[3:6] == ["live", "", "stale", "Updated 5s ago"]
        # 7.45s: board stale (no update for 5 polls' worth, floor 5s); the
        # socket lost after 5s of failure; the poller still within both.
        @test row(7450)[1:7] == ["live", "", "stale", "Updated 5s ago",
            "lost", "Connection lost · updated 5s ago · retrying", "live"]
        # 7.95s: the poller's last update (2.8s) is 5.15s old: stale first ...
        @test row(7950)[1:2] == ["stale", "Updated 5s ago"]
        # 8.25s: ... then lost, 5s after its first failure (3s); the board's
        # 404s say what failed. Lost dims the live tree.
        @test row(8250)[1:4] == ["lost", "Connection lost · updated 5s ago · retrying",
            "lost", "Updates failing (HTTP 404) · updated 6s ago · retrying"]
        @test row(8250)[8] == "0.55"
        # Lost freezes running clocks: nothing confirms the work still runs.
        @test row(8250)[9] == row(9150)[9]
        @test row(7450)[10] == row(8250)[10]
        # 9.15s: one frame heals the socket; the poller stays lost (durable
        # until an update succeeds).
        @test row(9150)[[1, 5, 6]] == ["lost", "live", ""]
        # 9.55s: a paused board is not retrying.
        @test row(9550)[3:4] == ["lost", "Updates failing (HTTP 404) · updated 7s ago"]
        # 10.55s: the first successful update clears everything.
        @test row(10550)[1:7] == ["live", "", "live", "", "live", "", "live"]
        @test row(10550)[8] == "1"
        @test row(10550)[9] != row(9150)[9]
        finalize_progress!(job)
        finalize_progress!(stream)
    end
    end
end

@testitem "Pushed pollers: answers, heartbeats, pause hold, loss, terminal (browser)" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    # Opt in with TREEBARS_BROWSER_TESTS=1 (needs google-chrome or chromium,
    # and network for htmx 2.0.8 from jsdelivr — the URL HTMXObjects' page
    # shell loads by default). Real htmx runs the poller's `every 200ms`
    # trigger; the page records every poll the Treebars script let through
    # and then cancels it, so no request leaves the page. A push source is
    # played by calls to treebarUpdatePoller / treebarPollerLost on a fixed
    # schedule in Chrome's virtual time (which also drives Date.now).
    if get(ENV, "TREEBARS_BROWSER_TESTS", "") != "1"
        @test_skip true
    else
        chrome = Sys.which("google-chrome")
        isnothing(chrome) && (chrome = Sys.which("chromium"))
        isnothing(chrome) && error("TREEBARS_BROWSER_TESTS=1 requires google-chrome or chromium")
        html(x) = repr(MIME"text/html"(), x)
        ext = Base.get_extension(Treebars, :HTMXObjectsExt)
        job = initialize_progress!(:state; description="Job", N=10)
        start_progress!(job)
        # A poll answer at each progress step, as the server renders it.
        answer(i) = (update_progress!(job, i); html(ext._polling_running(job; label="Background job",
            poll_url="/poll", poll_interval="200ms", cancel_url="")))
        answers = Dict(i => answer(i) for i in (0, 3, 5, 6, 8, 9))
        done = html(ext._polling_wrap(ext._polling_inner_done(h.p(id="result")("Done: 42")); terminal=true))
        templates = [h.template(id="answer-$i")(Raw(a)) for (i, a) in answers]
        driver = raw"""
        var poller = document.querySelector('.treebar-poller');
        var attempts = 0;
        document.addEventListener('htmx:beforeRequest', function(evt){
            if (!evt.detail.elt.classList.contains('treebar-poller-inner')) return;
            if (!evt.defaultPrevented) attempts += 1;
            evt.preventDefault();
        });
        function answer(i){ return document.getElementById('answer-' + i).innerHTML; }
        var calls = {};
        function push(t, i){ setTimeout(function(){ calls[t] = treebarUpdatePoller(poller, i === undefined ? undefined : answer(i)); }, t); }
        function at(t, fn){ setTimeout(fn, t); }
        // A finished poller nested in this one must not resolve to it.
        at(500, function(){
            var nested = document.createElement('div');
            nested.className = 'treebar-terminal';
            poller.querySelector(':scope > .treebar-poller-inner').appendChild(nested);
            calls.nested = treebarUpdatePoller(nested, answer(9));
            nested.remove();
            calls.outside = treebarUpdatePoller(document.body, answer(9));
        });
        // Pushes from 1s: answers and heartbeats, well past the 5s a poller
        // without polls used to read as stale.
        push(1000, 3); push(2000, 5); push(3000); push(4000); push(5000); push(6000, 6);
        // Paused 7s–11.2s: an answer and a heartbeat arrive and are held.
        at(7000, function(){ poller.dataset.paused = '1'; });
        push(7500, 8); push(10000);
        at(11200, function(){ poller.dataset.paused = '0'; });
        push(12000, 9);
        // The source fails at 12.5s; the resumed polls fail too (cancelled
        // here, never answered) until the source is back at 18s.
        at(12500, function(){ calls.lost = treebarPollerLost(poller, ''); });
        push(18000, 9);
        // The result arrives by push; the finished poller takes no more.
        at(19000, function(){ calls.done = treebarUpdatePoller(poller, document.getElementById('done').innerHTML); });
        at(19200, function(){
            calls.after = treebarUpdatePoller(poller, answer(9));
            calls.afterLost = treebarPollerLost(poller, '');
        });
        var rows = [];
        function sample(t){
            setTimeout(function(){
                var bar = poller.querySelector('.treebar-poller-inner progress.treebar-progress');
                var span = poller.querySelector('.treebar-freshness');
                rows.push([t, attempts, bar ? bar.getAttribute('value') : '',
                    poller.dataset.treebarFreshness || 'live', span && !span.hidden ? span.textContent : '',
                    poller.className].join('|'));
            }, t);
        }
        [950, 1050, 6950, 7600, 11100, 11350, 12450, 13000, 17600, 18100, 18900, 19100].forEach(sample);
        setTimeout(function(){
            var out = document.createElement('pre'); out.id = 'result-rows';
            out.textContent = rows.join('\n') + '\nhtmx|' + htmx.version + '\ncalls|' + JSON.stringify(calls) +
                '\nresult|' + document.getElementById('result').textContent;
            document.body.appendChild(out);
        }, 20000);
        """
        dir = mktempdir()
        file = joinpath(dir, "pushed.html")
        write(file, "<!DOCTYPE html>" * html(h.html(
            h.head(h.meta(charset="utf-8"),
                h.script(src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js")(),
                htmx_treebar_styles(), htmx_treebar_script()),
            h.body(Raw(answers[0]), templates..., h.template(id="done")(Raw(done)), h.script(Raw(driver))))))
        profile = joinpath(dir, "profile")
        dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=21000 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
        result = match(r"<pre id=\"result-rows\">([^<]*)</pre>", dom)
        @test result !== nothing
        lines = result === nothing ? String[] : split(result.captures[1], '\n')
        rows = Dict(parse(Int, first(r)) => r[2:end] for r in split.(lines, '|') if all(isdigit, first(r)))
        extra = Dict(first(r) => join(r[2:end], '|') for r in split.(lines, '|') if !all(isdigit, first(r)))
        row(t) = get(rows, t, fill("missing", 5))
        attempts(t) = parse(Int, row(t)[1])
        @test get(extra, "htmx", "") == "2.0.8"
        # Before any push the poller polls.
        @test attempts(950) >= 3
        # 1.05s: the first push shows its answer and suspends the polls.
        @test row(1050)[2:4] == ["3", "live", ""]
        # 6.95s: pushes and heartbeats keep the poller live, with no poll.
        @test row(6950)[2:4] == ["6", "live", ""]
        @test attempts(6950) == attempts(1050)
        # 7.6s: paused, the pushed answer is held.
        @test row(7600)[2] == "6"
        # 11.1s: the shown answer ages while paused (last shown at 6s).
        @test row(11100)[2:4] == ["6", "stale", "Updated 5s ago"]
        # 11.35s: resumed, the held answer shows at once, confirmed when the
        # source last spoke (10s).
        @test row(11350)[2:4] == ["8", "live", ""]
        @test attempts(12450) == attempts(1050)
        # 13s: the source failed; the poller polls again (a blip so far).
        @test attempts(13000) > attempts(12450)
        @test row(13000)[2:3] == ["9", "live"]
        # 17.6s: the polls have failed too for 5s: lost.
        @test row(17600)[3:4] == ["lost", "Connection lost · updated 5s ago · retrying"]
        # 18.1s: the source is back: live, polls suspended again.
        @test row(18100)[3:4] == ["live", ""]
        @test attempts(18900) == attempts(18100)
        # 19.1s: the pushed result terminalizes the poller.
        @test row(19100)[5] == "treebar-terminal"
        @test get(extra, "result", "") == "Done: 42"
        @test get(extra, "calls", "") == """{"1000":true,"2000":true,"3000":true,"4000":true,"5000":true,"6000":true,"7500":true,"10000":true,"12000":true,"18000":true,"nested":false,"outside":false,"lost":true,"done":true,"after":false,"afterLost":false}"""
        finalize_progress!(job)
    end
    end
end
