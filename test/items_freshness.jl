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

@testitem "Pushed pollers: a poll in flight at the first push ends without an error (browser)" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    let
    # Opt in with TREEBARS_BROWSER_TESTS=1 (needs google-chrome or chromium,
    # and network for htmx 2.0.8 from jsdelivr). Real htmx runs each poller's
    # `every 200ms` trigger and handles its responses; only XMLHttpRequest is
    # replaced, so each poll stays out until the schedule ends it, in Chrome's
    # virtual time. Every console.error is attributed to the poller whose
    # request caused it. The first poll of each poller leaves around 200ms.
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
        answer(name, i) = (update_progress!(job, i); html(ext._polling_running(job;
            label="Background job", poll_url="/poll/$name", poll_interval="200ms", cancel_url="")))
        names = ("plain", "paused", "heartbeat", "failed", "unpushed", "back", "backlate", "nested")
        templates = [h.template(id="answer-$name-$i")(Raw(answer(name, i))) for name in names for i in (3, 5, 9)]
        done = html(ext._polling_wrap(ext._polling_inner_done(h.p(id="result")("Done: 42")); terminal=true))
        body = h.div(
            [h.div(id="slot-$name")(Raw(answer(name, 0))) for name in names]...,
            h.div(id="oob")("untouched"))
        driver = raw"""
        var errors = {}, sent = {}, out = {}, aborted = 0, current = 'page', reached = 0;
        var ce = console.error;
        console.error = function(msg){
            (errors[current] = errors[current] || []).push(String(msg));
            return ce.apply(console, arguments);
        };
        function run(name, fn){ var was = current; current = name; try { fn(); } finally { current = was; } }
        function pollerOf(url){ var m = /\/poll\/(\w+)/.exec(url || ''); return m ? m[1] : url; }
        function FakeXhr(){ this.upload = {addEventListener: function(){}}; this.heads = ''; this.status = 0; this.response = ''; }
        FakeXhr.prototype = {
            overrideMimeType: function(){}, setRequestHeader: function(){}, addEventListener: function(){},
            getAllResponseHeaders: function(){ return this.heads; },
            getResponseHeader: function(){ return null; },
            open: function(verb, url){ this.url = url; this.name = pollerOf(url); },
            send: function(){
                sent[this.name] = (sent[this.name] || 0) + 1;
                out[this.name] = this;
                // A poller nobody pushes to, against a server that is down.
                if (this.name === 'unpushed'){ var x = this; setTimeout(function(){ fail('unpushed', x); }, 0); }
            },
            abort: function(){ aborted += 1; var x = this; run(this.name, function(){ x.onabort(); }); }
        };
        window.XMLHttpRequest = FakeXhr;
        function respond(name, status, text, heads){
            var x = out[name]; out[name] = null;
            x.status = status; x.response = text; x.heads = heads || '';
            run(name, function(){ x.onload(); });
        }
        function fail(name, x){ x = x || out[name]; out[name] = null; run(name, function(){ x.onerror(); }); }
        function tpl(name, i){ return document.getElementById('answer-' + name + '-' + i).innerHTML; }
        function poller(name){ return document.querySelector('#slot-' + name + ' > .treebar-poller'); }
        function innerOf(name){ return poller(name).querySelector(':scope > .treebar-poller-inner'); }
        function bar(name){ var b = poller(name).querySelector('.treebar-poller-inner progress.treebar-progress'); return b ? b.getAttribute('value') : ''; }
        function push(name, i){ return treebarUpdatePoller(poller(name), i === undefined ? undefined : tpl(name, i)); }
        function at(t, fn){ setTimeout(fn, t); }
        var kept = {}, rows = {};
        function row(key, value){ rows[key] = value; }
        // What a page's own listener sees of a poll answer.
        document.addEventListener('htmx:beforeOnLoad', function(evt){
            var d = evt.detail || {};
            if (d.xhr && d.xhr.status === 286) reached += 1;
        });

        // plain: the push replaces the polling element, so the late answer
        // has nowhere to go. Left to htmx it would still be parsed, and its
        // out-of-band content would log htmx:oobErrorNoTarget.
        at(1000, function(){ push('plain', 3); row('plainShown', bar('plain')); });
        at(1500, function(){ respond('plain', 200, tpl('plain', 9) + '<div id="oob" hx-swap-oob="true">late</div>'); });
        at(1700, function(){ row('plainAfter', bar('plain')); row('oob', document.getElementById('oob').textContent); });

        // paused: the first pushed answer is held, so the polling element
        // stays on the page and the late answer would replace it.
        at(500, function(){ poller('paused').dataset.paused = '1'; kept.paused = innerOf('paused'); });
        at(1000, function(){ push('paused', 3); });
        at(1500, function(){ respond('paused', 200, tpl('paused', 9)); });
        at(1700, function(){ row('pausedKept', kept.paused.isConnected); row('pausedAfter', bar('paused')); poller('paused').dataset.paused = '0'; });
        at(1900, function(){ row('pausedResumed', bar('paused')); });

        // heartbeat: a first call with no html leaves the polling element on
        // the page too. The late answer is the operation's last (status 286):
        // the page's listeners must not take the operation for finished, and
        // htmx must not stop the element's polls, so the poller still gets
        // that answer when it is handed back.
        at(1000, function(){ kept.heartbeat = innerOf('heartbeat'); push('heartbeat'); });
        at(1500, function(){ respond('heartbeat', 286, document.getElementById('done').innerHTML); });
        at(1700, function(){ row('heartbeatKept', kept.heartbeat.isConnected); row('heartbeatAfter', bar('heartbeat')); row('reached', reached); row('heartbeatSent', sent.heartbeat); });
        at(2000, function(){ treebarPollerLost(poller('heartbeat'), ''); });
        at(2500, function(){ row('heartbeatResumedPolls', sent.heartbeat); respond('heartbeat', 200, tpl('heartbeat', 5)); });
        at(2700, function(){ row('heartbeatPolled', bar('heartbeat')); });

        // failed: the late poll fails while the push source is alive and the
        // viewer has paused. That is real, so htmx reports it, but it says
        // nothing about the source: the poller reads stale, never lost.
        at(500, function(){ poller('failed').dataset.paused = '1'; });
        at(1000, function(){ push('failed', 3); });
        at(1500, function(){ fail('failed'); });

        // back: handed back while the abandoned poll is still out. The push
        // replaced the polling element, so its late answer is dropped and
        // the new element polls by itself.
        at(1000, function(){ push('back', 3); });
        at(1200, function(){ treebarPollerLost(poller('back'), ''); });
        at(1500, function(){ row('backSent', sent.back); respond_old('back', 9); });
        at(1700, function(){ row('backAfter', bar('back')); });
        at(1900, function(){ respond('back', 200, tpl('back', 5)); });
        at(2100, function(){ row('backPolled', bar('back')); });
        var abandoned = {};
        at(990, function(){ abandoned.back = out.back; });
        function respond_old(name, i){
            var x = abandoned[name];
            x.status = 200; x.response = tpl(name, i);
            run(name, function(){ x.onload(); });
        }

        // backlate: handed back with the polling element still on the page.
        // The answer that then arrives is an ordinary poll answer.
        at(1000, function(){ push('backlate'); });
        at(1200, function(){ treebarPollerLost(poller('backlate'), ''); });
        at(1500, function(){ respond('backlate', 200, tpl('backlate', 5)); });
        at(1700, function(){ row('backlateAfter', bar('backlate')); });
        at(2100, function(){ row('backlateSent', sent.backlate); });

        // nested: a request of an element inside the inner of a pushed poller
        // is not that poller's poll.
        at(900, function(){
            var n = document.createElement('div');
            n.id = 'nested-el'; n.setAttribute('hx-get', '/nested'); n.setAttribute('hx-trigger', 'load');
            // The inner's hx-select, hx-swap and hx-target would be inherited.
            n.setAttribute('hx-select', 'unset'); n.setAttribute('hx-swap', 'innerHTML'); n.setAttribute('hx-target', 'this');
            innerOf('nested').appendChild(n);
            htmx.process(n);
        });
        at(1000, function(){ push('nested'); });
        at(1400, function(){ respond('/nested', 200, 'nested answer'); });
        at(1600, function(){ row('nestedAnswer', document.getElementById('nested-el').textContent); });

        // 7s: the failed poller's late failure is 5.5s old; a poller against
        // a dead server reads lost by now.
        at(7000, function(){
            row('failedState', poller('failed').dataset.treebarFreshness || 'live');
            row('unpushedState', poller('unpushed').dataset.treebarFreshness || 'live');
        });
        at(7200, function(){
            var el = document.createElement('pre'); el.id = 'late-result';
            el.textContent = JSON.stringify({htmx: htmx.version, aborted: aborted, errors: errors, rows: rows});
            document.body.appendChild(el);
        });
        """
        dir = mktempdir()
        file = joinpath(dir, "late.html")
        write(file, "<!DOCTYPE html>" * html(h.html(
            h.head(h.meta(charset="utf-8"),
                h.script(src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js")(),
                htmx_treebar_styles(), htmx_treebar_script()),
            h.body(body, templates..., h.template(id="done")(Raw(done)), h.script(Raw(driver))))))
        profile = joinpath(dir, "profile")
        dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=8000 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
        found = match(r"<pre id=\"late-result\">([^<]*)</pre>", dom)
        @test found !== nothing
        text = found === nothing ? "" : found.captures[1]
        # A flat reading of the report: no JSON package in the test env.
        field(key) = (m = match(Regex("\"$key\":(\"[^\"]*\"|[^,}]+)"), text); m === nothing ? "missing" : strip(m[1], '"'))
        errors_of(name) = (m = match(Regex("\"$name\":\\[([^\\]]*)\\]"), text); m === nothing ? String[] : String.(strip.(split(m[1], ','), '"')))
        @test field("htmx") == "2.0.8"
        # The in-flight poll is never aborted, and ending it reports nothing.
        @test field("aborted") == "0"
        for name in ("plain", "paused", "heartbeat", "back", "backlate", "nested")
            @test errors_of(name) == String[]
        end
        # The fragment lands and the late answer changes nothing, out-of-band
        # content included.
        @test field("plainShown") == "3"
        @test field("plainAfter") == "3"
        @test field("oob") == "untouched"
        # Paused: the late answer leaves the element; resume shows the held one.
        @test field("pausedKept") == "true"
        @test field("pausedAfter") == "0"
        @test field("pausedResumed") == "3"
        # Heartbeat: the late last answer stays dropped for the page as well,
        # and handing the poller back makes it poll on from the same element.
        @test field("heartbeatKept") == "true"
        @test field("heartbeatAfter") == "0"
        @test field("reached") == "0"
        @test parse(Int, field("heartbeatResumedPolls")) > parse(Int, field("heartbeatSent"))
        @test field("heartbeatPolled") == "5"
        # Genuine failures stay visible: a failed poll is still reported, and
        # a poller whose polls all fail reads lost. The abandoned poll's own
        # failure does not make a pushed poller read lost.
        @test errors_of("failed") == ["htmx:afterRequest", "htmx:sendError"]
        @test field("failedState") == "stale"
        @test field("unpushedState") == "lost"
        @test "htmx:sendError" in errors_of("unpushed")
        # Handed back with the abandoned poll out: its answer is dropped, the
        # new element polled meanwhile, and its answer lands.
        @test parse(Int, field("backSent")) >= 2
        @test field("backAfter") == "3"
        @test field("backPolled") == "5"
        # Handed back with the element on the page: an ordinary answer, and
        # the request lock is free again.
        @test field("backlateAfter") == "5"
        @test parse(Int, field("backlateSent")) >= 2
        # A nested request passes through the pushed poller's drop.
        @test field("nestedAnswer") == "nested answer"
        finalize_progress!(job)
    end
    end
end

@testitem "Pushed pollers: an answer is offered to htmx:beforeSwap as a poll answer is (browser)" setup=[TreebarsTestImports] tags=[:unit, :render] begin
    import JSON
    let
    # Opt in with TREEBARS_BROWSER_TESTS=1 (needs google-chrome or chromium,
    # and network for htmx 2.0.8 from jsdelivr). htmx fires htmx:beforeSwap
    # only for the response to a request and htmx.swap fires none, so a page's
    # swap gate or rewrite never saw a pushed answer. One poller is answered by
    # real htmx (only XMLHttpRequest is replaced), so what a pushed answer
    # offers is compared with what a poll answer offers.
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
        answer(name, i) = (update_progress!(job, i); html(ext._polling_running(job;
            label="Background job", poll_url="/poll/$name", poll_interval="200ms", cancel_url="")))
        names = ("polled", "fields", "rewrite", "unwritten", "shouldswap", "prevent", "vetoed", "quiet",
            "elsewhere", "unset", "title", "heartbeat", "paused", "unguarded")
        templates = [h.template(id="answer-$name-$i")(Raw(answer(name, i))) for name in names for i in (3, 5)]
        # A plot fragment: its script runs at insert, naming the id it was given.
        plot = ext._polling_inner_done(h.div(h.p(id="shared-plot")("plot"),
            h.script(Raw("window.ran.push('shared-plot');"))))
        done = html(ext._polling_wrap(plot; terminal=true))
        body = h.div(
            [h.div(id="slot-$name")(Raw(answer(name, 0))) for name in names]...,
            h.div(id="target-elsewhere")("was "), h.div(id="target-unset")())
        driver = raw"""
        window.ran = [];
        var out = {}, rows = {}, offers = {}, errors = 0;
        window.addEventListener('error', function(){ errors += 1; });
        function pollerOf(url){ var m = /\/poll\/(\w+)/.exec(url || ''); return m ? m[1] : url; }
        function FakeXhr(){ this.upload = {addEventListener: function(){}}; this.status = 0; this.response = ''; }
        FakeXhr.prototype = {
            overrideMimeType: function(){}, setRequestHeader: function(){}, addEventListener: function(){},
            getAllResponseHeaders: function(){ return ''; }, getResponseHeader: function(){ return null; },
            open: function(verb, url){ this.name = pollerOf(url); },
            send: function(){ out[this.name] = this; },
            abort: function(){}
        };
        window.XMLHttpRequest = FakeXhr;
        function tpl(name, i){ return document.getElementById('answer-' + name + '-' + i).innerHTML; }
        function poller(name){ return document.querySelector('#slot-' + name + ' > .treebar-poller'); }
        function bar(name){ var b = poller(name).querySelector('.treebar-poller-inner progress.treebar-progress'); return b ? b.getAttribute('value') : ''; }
        function push(name, html){ return treebarUpdatePoller(poller(name), html); }
        function row(key, value){ rows[key] = value; }
        function at(t, fn){ setTimeout(fn, t); }
        function describe(evt){
            var d = evt.detail, el = evt.target, url = el.getAttribute('hx-get'), c = d.requestConfig || {}, p = d.pathInfo || {};
            return {keys: Object.keys(d).sort(), inner: el.classList.contains('treebar-poller-inner'),
                bubbles: evt.bubbles, cancelable: evt.cancelable, target: d.target === el, elt: d.elt === el,
                requester: c.elt === el, configTarget: c.target === el, verb: c.verb, path: c.path === url,
                requestPath: p.requestPath === url, finalPath: p.finalRequestPath === url,
                shouldSwap: d.shouldSwap, isError: d.isError, responseType: typeof d.serverResponse,
                swapOverride: String(d.swapOverride), selectOverride: String(d.selectOverride),
                boosted: !!d.boosted, etc: typeof d.etc};
        }
        // What a page's listeners do, per poller.
        var gates = {
            rewrite: function(evt, d){ d.serverResponse = d.serverResponse.replace(/shared-plot/g, 'shared-plot--rewrite'); },
            shouldswap: function(evt, d, n){ if (n === 1) d.shouldSwap = false; },
            prevent: function(evt, d, n){ if (n === 1) evt.preventDefault(); },
            vetoed: function(evt, d){ d.shouldSwap = false; },
            elsewhere: function(evt, d){
                d.target = document.getElementById('target-elsewhere');
                // Not innerHTML: htmx falls back to it for a style it does not know.
                d.swapOverride = 'beforeend settle:5ms';
                d.selectOverride = '#part';
            },
            unset: function(evt, d){
                d.target = document.getElementById('target-unset');
                d.swapOverride = 'innerHTML';
                d.selectOverride = 'unset';
            },
            title: function(evt, d, n){ if (n === 1) d.ignoreTitle = true; }
        };
        document.addEventListener('htmx:beforeSwap', function(evt){
            var slot = evt.target.closest('[id^="slot-"]');
            if (!slot) return;
            var name = slot.id.slice(5), seen = offers[name] = offers[name] || [];
            seen.push({describe: describe(evt), pushed: evt.detail.treebarPushed === true,
                xhr: !!evt.detail.xhr, response: evt.detail.serverResponse});
            if (gates[name]) gates[name](evt, evt.detail, seen.length);
        });
        function offered(name){ return (offers[name] || []).length; }

        // A real poll answer, for comparison.
        at(600, function(){
            var x = out.polled; out.polled = null;
            x.status = 200; x.response = tpl('polled', 5);
            x.onload();
        });
        at(800, function(){ row('polledBar', bar('polled')); });

        // Nothing a listener does: the answer lands as it was pushed.
        at(1000, function(){ row('fieldsCall', push('fields', tpl('fields', 3))); row('fieldsBar', bar('fields')); });

        // A rewrite lands, and reaches the fragment's script before it runs.
        at(1000, function(){ row('rewriteCall', push('rewrite', document.getElementById('done').innerHTML)); });
        at(1100, function(){
            row('rewriteRan', window.ran.slice());
            row('rewriteRenamed', !!document.getElementById('shared-plot--rewrite'));
            row('rewriteOriginal', !!document.getElementById('shared-plot'));
            row('rewriteTerminal', document.querySelector('#slot-rewrite > .treebar-terminal') !== null);
        });

        // A veto keeps what is shown; the next answer is offered and lands.
        at(1000, function(){ row('shouldswapCall', push('shouldswap', tpl('shouldswap', 3))); row('shouldswapVetoed', bar('shouldswap')); });
        at(1200, function(){ push('shouldswap', tpl('shouldswap', 5)); row('shouldswapNext', bar('shouldswap')); });
        at(1000, function(){ row('preventCall', push('prevent', tpl('prevent', 3))); row('preventVetoed', bar('prevent')); });
        at(1200, function(){ push('prevent', tpl('prevent', 5)); row('preventNext', bar('prevent')); });

        // A vetoed answer still confirms the poller live, as a skipped poll
        // answer does. `quiet` hears nothing, so it reads stale by then.
        [1000, 3000, 5000, 7000].forEach(function(t){ at(t, function(){ push('vetoed', tpl('vetoed', 3)); }); });
        at(7500, function(){
            row('vetoedState', poller('vetoed').dataset.treebarFreshness || 'live');
            row('vetoedBar', bar('vetoed'));
            row('quietState', poller('quiet').dataset.treebarFreshness || 'live');
        });

        // Where and how it lands: htmx reads these back from the detail.
        at(1000, function(){ push('elsewhere', '<div id="part">kept</div><div id="rest">dropped</div>'); });
        at(1100, function(){
            row('elsewhereHtml', document.getElementById('target-elsewhere').textContent);
            row('elsewhereBar', bar('elsewhere'));
        });
        at(1000, function(){ push('unset', '<div>one</div><div>two</div>'); });
        at(1100, function(){ row('unsetHtml', document.getElementById('target-unset').textContent); });

        // ignoreTitle: the first answer's title is ignored, the next one's shows.
        at(1000, function(){ push('title', '<title>Pushed title</title>' + tpl('title', 3)); });
        at(1100, function(){ row('titleIgnored', document.title); });
        at(1200, function(){ push('title', '<title>Pushed title</title>' + tpl('title', 5)); });
        at(1300, function(){ row('titleShown', document.title); });

        // A heartbeat carries no answer, so there is nothing to offer.
        at(1000, function(){ row('heartbeatCall', push('heartbeat')); row('heartbeatOffers', offered('heartbeat')); });

        // A held answer is offered when it is shown, and only the newest is.
        at(500, function(){ poller('paused').dataset.paused = '1'; });
        at(1000, function(){ push('paused', tpl('paused', 3)); });
        at(1200, function(){ push('paused', tpl('paused', 5)); row('pausedOffers', offered('paused')); poller('paused').dataset.paused = '0'; });
        at(1500, function(){
            row('pausedResumedOffers', offered('paused'));
            row('pausedNewest', offers.paused && offers.paused[0].response === tpl('paused', 5));
            row('pausedBar', bar('paused'));
        });

        // A listener written for requests that reads detail.xhr throws, which
        // the browser reports; the answer lands regardless.
        at(1800, function(){
            document.getElementById('slot-unguarded').addEventListener('htmx:beforeSwap', function(evt){ row('unguardedStatus', evt.detail.xhr.status); });
            row('errorsBefore', errors);
            row('unguardedCall', push('unguarded', tpl('unguarded', 3)));
            row('errorsAfter', errors);
            row('unguardedBar', bar('unguarded'));
        });

        at(7700, function(){
            var described = {};
            Object.keys(offers).forEach(function(name){ described[name] = offers[name].length; });
            var el = document.createElement('pre'); el.id = 'offer-result';
            el.textContent = JSON.stringify({htmx: htmx.version, rows: rows, counts: described,
                polled: (offers.polled || [null])[0], fields: (offers.fields || [null])[0]}, function(key, value){ return key === 'response' ? undefined : value; });
            document.body.appendChild(el);
        });
        """
        dir = mktempdir()
        file = joinpath(dir, "offer.html")
        write(file, "<!DOCTYPE html>" * html(h.html(
            h.head(h.meta(charset="utf-8"), h.title("Page title"),
                h.script(src="https://cdn.jsdelivr.net/npm/htmx.org@2.0.8/dist/htmx.min.js")(),
                htmx_treebar_styles(), htmx_treebar_script()),
            h.body(body, templates..., h.template(id="done")(Raw(done)), h.script(Raw(driver))))))
        profile = joinpath(dir, "profile")
        dom = read(pipeline(`$chrome --headless=new --no-sandbox --disable-gpu --disable-dev-shm-usage --virtual-time-budget=8500 --dump-dom --user-data-dir=$profile file://$file`; stderr=devnull), String)
        found = match(r"<pre id=\"offer-result\">([^<]*)</pre>", dom)
        @test found !== nothing
        report = found === nothing ? Dict{String,Any}("rows" => Dict(), "counts" => Dict()) :
            JSON.parse(replace(found.captures[1], "&amp;" => "&"))
        rows = report["rows"]
        counts = report["counts"]
        @test get(report, "htmx", "") == "2.0.8"
        # A pushed answer's offer reads as a poll answer's does: same event,
        # same fields, apart from the request that did not run.
        none = Dict{String,Any}("describe" => Dict(), "pushed" => "no offer", "xhr" => "no offer")
        polled = something(get(report, "polled", nothing), none)
        pushed = something(get(report, "fields", nothing), none)
        @test get(rows, "polledBar", "") == "5"
        @test polled["pushed"] == false
        @test polled["xhr"] == true
        @test pushed["pushed"] == true
        @test pushed["xhr"] == false
        polled_keys = get(polled["describe"], "keys", String[])
        pushed_keys = get(pushed["describe"], "keys", String[])
        @test !isempty(polled_keys)
        @test setdiff(polled_keys, pushed_keys) == ["xhr"]
        @test setdiff(pushed_keys, polled_keys) == ["treebarPushed"]
        for key in ("inner", "bubbles", "cancelable", "target", "elt", "requester", "configTarget", "verb",
                "path", "requestPath", "finalPath", "shouldSwap", "isError", "responseType",
                "swapOverride", "selectOverride", "boosted", "etc")
            @test get(pushed["describe"], key, "missing") == get(polled["describe"], key, "absent")
        end
        @test get(polled["describe"], "target", false) == true
        @test get(polled["describe"], "shouldSwap", false) == true
        @test get(rows, "fieldsCall", false) == true
        @test get(rows, "fieldsBar", "") == "3"
        # A rewrite reaches the fragment's script before it runs.
        @test get(rows, "rewriteCall", false) == true
        @test get(rows, "rewriteRan", String[]) == ["shared-plot--rewrite"]
        @test get(rows, "rewriteRenamed", false) == true
        @test get(rows, "rewriteOriginal", true) == false
        @test get(rows, "rewriteTerminal", false) == true
        # Either way of vetoing keeps what is shown, and the next answer lands.
        @test get(rows, "shouldswapCall", false) == true
        @test get(rows, "shouldswapVetoed", "") == "0"
        @test get(rows, "shouldswapNext", "") == "5"
        @test get(counts, "shouldswap", 0) == 2
        @test get(rows, "preventCall", false) == true
        @test get(rows, "preventVetoed", "") == "0"
        @test get(rows, "preventNext", "") == "5"
        @test get(counts, "prevent", 0) == 2
        # Vetoed answers confirm the poller live; one that hears nothing is stale.
        @test get(rows, "vetoedState", "") == "live"
        @test get(rows, "vetoedBar", "") == "0"
        @test get(counts, "vetoed", 0) == 4
        @test get(rows, "quietState", "") == "stale"
        # What a listener changes decides where and how the answer lands.
        @test get(rows, "elsewhereHtml", "") == "was kept"
        @test get(rows, "elsewhereBar", "") == "0"
        @test get(rows, "unsetHtml", "") == "onetwo"
        @test get(rows, "titleIgnored", "") == "Page title"
        @test get(rows, "titleShown", "") == "Pushed title"
        # A heartbeat offers nothing; a held answer is offered when shown, and
        # only the newest one.
        @test get(rows, "heartbeatCall", false) == true
        @test get(rows, "heartbeatOffers", -1) == 0
        @test get(rows, "pausedOffers", -1) == 0
        @test get(rows, "pausedResumedOffers", -1) == 1
        @test get(rows, "pausedNewest", false) == true
        @test get(rows, "pausedBar", "") == "5"
        # A listener reading detail.xhr throws, and the answer still lands.
        @test get(rows, "unguardedCall", false) == true
        @test get(rows, "errorsAfter", 0) == get(rows, "errorsBefore", 0) + 1
        @test !haskey(rows, "unguardedStatus")
        @test get(rows, "unguardedBar", "") == "3"
        finalize_progress!(job)
    end
    end
end
