# Client-side duration ticker. Anchors each running .treebar-duration on first
# sight (and re-anchors the spans a swap delivered, since their data-elapsed-ms
# comes back fresh from the server) then ticks textContent every 100ms locally —
# so the counter advances smoothly between server polls instead of stuttering.
# Tracking is incremental: two live sets (running spans, poller wrappers)
# seeded once and kept current by a MutationObserver, so ticks and swaps cost
# work proportional to the active nodes / changed fragment, never the document.
# The same script owns poller Pause/terminalization, the keyed board
# reconciler (`htmx_render_board`), carrying viewer choices (overview
# disclosures, WebSocket-frame pill toggles) onto the markup each live update
# swaps in, and each live region's freshness: how old its shown state is, and
# whether its connection is lost.
htmx_treebar_script() = h.script(Raw("""
(function(){
    // Band-based formatter mirroring the server-side short_duration: sub-100ms
    // show whole milliseconds, sub-minute shows one-decimal seconds at 0.1s
    // resolution ("13.9s"; FLOOR, so server-render and ticker never disagree at
    // poll boundaries), and minute-and-up show the two most-significant units.
    // Each band's smallest displayed unit steps by a fixed amount (per-100ms
    // below 1min, per-second up to 1h, per-minute up to 1d, per-hour beyond) so
    // the rendered string changes at most once per step and length stays stable
    // within a band.
    // The words this script writes, in English. A live region (poller
    // wrapper, WebSocket frame, board) or a standalone tree rendered in
    // another language carries its own in `data-treebar-texts` (the server's
    // `treebar_texts`), and the nearest one wins.
    var EN = {running: '{elapsed} so far', eta: 'ETA ~{eta}', polling: 'Polling', paused: 'Paused',
        pause: 'Pause live updates', resume: 'Resume live updates', stale: 'Updated {age} ago',
        updated: 'updated {age} ago', connection_lost: 'Connection lost',
        updates_failing: 'Updates failing ({why})', retrying: 'retrying', ended: 'ended ({elapsed})',
        board_pause: 'Pause', board_resume: 'Resume', unit_ms: 'ms', unit_s: 's', unit_min: 'm',
        unit_h: 'h', unit_d: 'd', unit_space: '', decimal: '.'};
    var parsedTexts = {};
    function textsOf(el){
        var src = el.closest('[data-treebar-texts]') || (el.querySelector && el.querySelector('[data-treebar-texts]'));
        if (!src) return EN;
        var json = src.getAttribute('data-treebar-texts');
        if (!(json in parsedTexts)){
            var t = {};
            try { t = JSON.parse(json); } catch (e) {}
            parsedTexts[json] = Object.assign({}, EN, t);
        }
        return parsedTexts[json];
    }
    function fill(template, values){
        return template.replace(/\\{([A-Za-z_]+)\\}/g, function(m, k){ return k in values ? values[k] : m; });
    }
    function unit(n, u, T){ return n + T.unit_space + u; }
    function fmt(ms, T){
        T = T || EN;
        if (ms < 0) ms = 0;
        if (ms < 100)         return unit(ms, T.unit_ms, T);
        if (ms < 60_000)      return unit(String(Math.floor(ms / 100) / 10).replace('.', T.decimal), T.unit_s, T);
        if (ms < 3_600_000){
            var m = Math.floor(ms / 60_000);
            var s = Math.floor(ms / 1000) % 60;
            return unit(m, T.unit_min, T) + ' ' + unit(s, T.unit_s, T);
        }
        if (ms < 86_400_000){
            var h = Math.floor(ms / 3_600_000);
            var m = Math.floor(ms / 60_000) % 60;
            return unit(h, T.unit_h, T) + ' ' + unit(m, T.unit_min, T);
        }
        var d = Math.floor(ms / 86_400_000);
        var h = Math.floor(ms / 3_600_000) % 24;
        return unit(d, T.unit_d, T) + ' ' + unit(h, T.unit_h, T);
    }
    function anchor(el){
        var ms = parseInt(el.dataset.elapsedMs, 10);
        if (isNaN(ms)) ms = 0;
        el._tbAnchor = Date.now() - ms;
        el._tbAnchoredFrom = el.dataset.elapsedMs;
        el._tbTexts = textsOf(el);
        el._tbLast = undefined;
        // ETA (running determinate nodes only): anchor an ABSOLUTE finish target
        // so the estimate counts down smoothly between polls; each server poll
        // re-anchors with a fresh data-eta-ms as the position advances.
        var eta = el.dataset.etaMs === undefined ? NaN : parseInt(el.dataset.etaMs, 10);
        el._tbEtaTarget = isNaN(eta) ? undefined : Date.now() + eta;
    }
    function tick(el){
        if (el.dataset.treebarStatus !== 'running') return;
        // Never tick inside a kept snapshot (.treebar-frozen, see _kept_progress):
        // a terminal tree may still carry a "running" node, and a post-hoc
        // inspection view must be static, not counting up forever.
        if (el.closest('.treebar-frozen')) return;
        // Freeze the duration while this span's poller is paused, so the
        // inspected snapshot is genuinely still. On resume the ticker
        // catches up to true elapsed (the work kept running — pause is not
        // cancel) and the next server poll re-anchors.
        var p = el.closest('.treebar-poller');
        if (p && p.dataset.paused === '1') return;
        // Same for a paused board (htmx_render_board): pause freezes it whole.
        var b = el.closest('.treebar-board');
        if (b && b.dataset.paused === '1') return;
        // And for a region whose connection is lost (see freshness below):
        // the server can no longer confirm the work is still running, so
        // its clocks hold the last known state until an update arrives.
        if (el.closest('[data-treebar-freshness="lost"]')) return;
        if (el._tbAnchor === undefined) anchor(el);
        var T = el._tbTexts || EN;
        var s = ' — ' + fill(T.running, {elapsed: fmt(Date.now() - el._tbAnchor, T)});
        // A determinate node also counts its ETA down (fmt clamps negatives to
        // 0; the next server poll re-anchors to the new estimate).
        if (el._tbEtaTarget !== undefined){
            s += ' · ' + fill(T.eta, {eta: fmt(el._tbEtaTarget - Date.now(), T)});
        }
        // Only touch the DOM when the rendered string actually changes —
        // below 1min the value steps every 100ms (matching the tick cadence,
        // so each tick updates), while minute-and-up only change once per
        // integer minute/hour, so those ticks are mostly no-ops.
        if (el._tbLast !== s){ el.textContent = s; el._tbLast = s; }
    }
    // True when it turned a live poller into a finished one.
    function terminalizePoller(evt){
        var el = evt && evt.detail && evt.detail.elt;
        if (!el || !el.classList || !el.classList.contains('treebar-terminal-content')) return false;
        var p = el.parentElement;
        if (!p || !p.classList.contains('treebar-poller')) return false;
        p.classList.replace('treebar-poller', 'treebar-terminal');
        ['paused', 'showFinished', 'showPending', 'showFailed', 'showSkipped', 'showReused', 'treebarFreshness'].forEach(function(key){
            delete p.dataset[key];
        });
        var badge = p.querySelector(':scope > .treebar-badge');
        if (badge) badge.remove();
        return true;
    }
    // Mirror the live inner into the wrapper's badge: the badge lives on the
    // never-swapped wrapper (so the pause control keeps focus and state across
    // polls), which means its status line would go stale without this. Reads
    // the same nodes the tree renders — the first determinate bar, the first
    // duration span — so the badge can never disagree with the tree it
    // summarizes. Also re-derives the pause glyph from data-paused, so a
    // hand-edited dataset (DevTools) shows the matching control, exactly as a
    // click would. Exposed as window.__tbSyncBadge so the pause onclick can
    // refresh the badge in the same frame as the toggle.
    function syncBadge(p){
        var badge = p.querySelector(':scope > .treebar-badge');
        if (!badge) return;
        var paused = p.dataset.paused === '1';
        var T = textsOf(p);
        var btn = badge.querySelector('.treebar-pause');
        if (btn){
            btn.textContent = paused ? '▶' : '❚❚';
            btn.setAttribute('aria-label', paused ? T.resume : T.pause);
        }
        var st = badge.querySelector('.treebar-badge-status');
        if (st){
            var s = paused ? T.paused : T.polling;
            if (st._tbLast !== s){ st.textContent = s; st._tbLast = s; }
        }
        var inner = p.querySelector(':scope > .treebar-poller-inner');
        var bar = badge.querySelector('.treebar-badge-bar');
        if (bar){
            var src = inner ? inner.querySelector('progress.treebar-progress') : null;
            if (src && src.hasAttribute('value') && src.hasAttribute('max')){
                bar.setAttribute('value', src.getAttribute('value'));
                bar.setAttribute('max', src.getAttribute('max'));
            } else {
                bar.removeAttribute('value');
                bar.removeAttribute('max');
            }
        }
        var el = badge.querySelector('.treebar-badge-elapsed');
        if (el){
            var d = inner ? inner.querySelector('.treebar-duration') : null;
            var t = d ? d.textContent : '';
            if (el._tbLast !== t){ el.textContent = t; el._tbLast = t; }
        }
        paintFreshness(p, Date.now());
    }
    // Incremental active-progress tracking: the ticker NEVER scans the
    // document. Two live sets — running duration spans and poller wrappers —
    // are seeded once at startup and kept current by a MutationObserver
    // below, so each tick costs work proportional to the active progress
    // nodes and each swap costs work proportional to the changed fragment;
    // settled hidden trees cost nothing. (Was: document-wide
    // querySelectorAll on every 100ms tick and every swap — ~0.3 CPU-s per
    // 30s on a 16k-node page. Snag browser-progress-573fb052.)
    var liveRunning = new Set();
    var livePollers = new Set();
    // Boards and WebSocket sources whose freshness is shown (a poller's is
    // shown by its badge sync, so pollers stay in livePollers).
    var liveRegions = new Set();
    var RUNNING_SEL = '.treebar-duration[data-treebar-status="running"]';
    var POLLER_SEL = '.treebar-poller';
    // A live board renders a freshness span in its header; a WebSocket
    // source is the [ws-connect] element its frames arrive in.
    var BOARD_FRESH_SEL = '.treebar-board-header > .treebar-freshness';
    var FRAME_SEL = '.treebar-ws-frame';
    var SOCKET_SEL = '[ws-connect], [data-ws-connect]';
    var TRACK_SEL = [RUNNING_SEL, POLLER_SEL, BOARD_FRESH_SEL, FRAME_SEL].join(', ');
    function trackRunning(el){
        if (el._tbAnchor === undefined) anchor(el);
        liveRunning.add(el);
    }
    function track(el){
        if (el.matches(RUNNING_SEL)) trackRunning(el);
        else if (el.matches(POLLER_SEL)) livePollers.add(el);
        else {
            var r = el.closest(el.matches(FRAME_SEL) ? SOCKET_SEL : '.treebar-board');
            if (r) liveRegions.add(r);
        }
    }
    // One selector pass per inserted fragment, whatever it holds.
    function collect(root){
        if (root.nodeType === 1 && root.matches(TRACK_SEL)) track(root);
        if (root.nodeType !== 1 && root.nodeType !== 9) return;
        var q = root.querySelectorAll(TRACK_SEL);
        for (var i = 0; i < q.length; i++) track(q[i]);
    }
    // --- Freshness ----------------------------------------------------------
    // A live region shows the server's state as of its last update, so it
    // says how old that state is. Each region keeps, on the client clock,
    // when the server last confirmed it (_tbOkAt; first sight counts, as the
    // server just rendered it) and since when its updates have been failing
    // (_tbFailSince). Every tick turns those into data-treebar-freshness on
    // the region and the text of the hidden .treebar-freshness span the
    // server renders in its chrome:
    //   absent  live: confirmed recently; the span stays hidden.
    //   stale   nothing confirmed for STALE_MS or five poll intervals,
    //           whichever is longer: a backgrounded tab that stopped
    //           polling, a slow or hung server. "Updated 1m 4s ago".
    //   lost    every attempt has failed for LOST_MS straight: a dead
    //           server, a gateway 5xx, a dropped socket. "Connection lost ·
    //           updated 1m 4s ago · retrying". A failure the next update
    //           recovers from is a blip and shows nothing; once lost, a
    //           region stays lost until an update succeeds.
    // Failure never stops a region: htmx keeps its `every` timer, and the ws
    // extension reconnects after an abnormal close, so the region heals by
    // itself when the server returns. Regions: a .treebar-poller (the
    // requests of its own .treebar-poller-inner, or the answers a push
    // source hands to treebarUpdatePoller), a live .treebar-board (its
    // .treebar-board-poll requests, or the boards a WebSocket pushes), and a
    // WebSocket source carrying .treebar-ws-frame frames.
    var STALE_MS = 5000, LOST_MS = 5000;
    // `at` is when the server confirmed the region, if not just now.
    function markOk(r, at){
        r._tbOkAt = at === undefined ? Date.now() : at;
        r._tbFailSince = 0;
        r._tbSettled = false;
    }
    // `why` is empty when the server is unreachable (no response, or a
    // gateway that cannot reach it) and names the status otherwise.
    function markFail(r, why, retrying){
        if (!r._tbFailSince) r._tbFailSince = Date.now();
        r._tbFailWhy = why;
        r._tbRetrying = retrying;
        r._tbSettled = false;
    }
    // Five missed polls before an old state counts as stale; never sooner
    // than STALE_MS. Same interval grammar as htmx's `every`.
    function staleAfter(r){
        if (r._tbStaleMs === undefined){
            var el = r.querySelector(':scope > .treebar-poller-inner, :scope > .treebar-board-poll');
            var m = el && /every\\s+(\\d+(?:\\.\\d+)?)(ms|s|m)?/.exec(el.getAttribute('hx-trigger') || '');
            var ms = m ? parseFloat(m[1]) * (m[2] === 's' ? 1000 : m[2] === 'm' ? 60000 : 1) : 0;
            r._tbStaleMs = Math.max(STALE_MS, 5 * ms);
        }
        return r._tbStaleMs;
    }
    function freshness(r, now){
        if (r._tbOkAt === undefined) r._tbOkAt = now;
        if (r._tbFailSince && now - r._tbFailSince >= LOST_MS) return 'lost';
        if (r._tbSettled) return '';
        return now - r._tbOkAt >= staleAfter(r) ? 'stale' : '';
    }
    function freshnessText(r, state, now){
        if (!state) return '';
        var T = textsOf(r);
        var ms = now - r._tbOkAt;
        var age = ms < 60_000 ? unit(Math.floor(ms / 1000), T.unit_s, T) : fmt(ms, T);
        if (state === 'stale') return fill(T.stale, {age: age});
        return (r._tbFailWhy ? fill(T.updates_failing, {why: r._tbFailWhy}) : T.connection_lost) +
            ' · ' + fill(T.updated, {age: age}) +
            (r._tbRetrying && r.dataset.paused !== '1' ? ' · ' + T.retrying : '');
    }
    function freshnessSpans(r){
        if (r.classList.contains('treebar-poller')) return r.querySelectorAll(':scope > .treebar-badge .treebar-freshness');
        if (r.classList.contains('treebar-board')) return r.querySelectorAll(':scope > .treebar-board-header > .treebar-freshness');
        return r.querySelectorAll('.treebar-ws-frame > .treebar-freshness');
    }
    function paintFreshness(r, now){
        var state = freshness(r, now);
        if ((r.dataset.treebarFreshness || '') !== state){
            if (state) r.dataset.treebarFreshness = state; else delete r.dataset.treebarFreshness;
        }
        // Repaint only when the text changes (at most once a second while
        // stale or lost, never while live). A frame or snapshot arriving
        // later brings its own hidden span and confirms the region live, so
        // no span can miss a change.
        var text = freshnessText(r, state, now);
        if (r._tbFreshText === text) return;
        r._tbFreshText = text;
        var spans = freshnessSpans(r);
        for (var i = 0; i < spans.length; i++){ spans[i].textContent = text; spans[i].hidden = !text; }
    }
    function paintRegions(){
        var now = Date.now();
        liveRegions.forEach(function(r){
            if (!r.isConnected){ liveRegions.delete(r); return; }
            paintFreshness(r, now);
        });
    }
    // The region a poll request belongs to. A poller's inner replaces itself
    // before htmx fires afterRequest, so htmx re-fires the event on the
    // nearest element still in the document — the poller wrapper.
    function pollRegion(el){
        if (!el || !el.classList) return null;
        if (el.classList.contains('treebar-board-poll')) return el.closest('.treebar-board');
        if (!el.classList.contains('treebar-poller-inner')) return null;
        var p = el.parentElement;
        return p && p.classList.contains('treebar-poller') ? p : null;
    }
    function requestRegion(d){
        var req = d.requestConfig && d.requestConfig.elt;
        var r = pollRegion(req);
        if (r) return r;
        return req && req.classList && req.classList.contains('treebar-poller-inner') &&
            d.elt && d.elt.classList && d.elt.classList.contains('treebar-poller') ? d.elt : null;
    }
    // Failures arrive as their own events; an aborted request or a dropped
    // poll answer (see "Pushed pollers") is neither.
    document.addEventListener('htmx:afterRequest', function(evt){
        var d = evt.detail || {};
        if (d.successful !== true) return;
        var r = requestRegion(d);
        if (r) markOk(r);
    });
    function pollFailed(evt){
        var d = evt.detail || {};
        var r = requestRegion(d);
        // While pushed, only a poll left running at the first push can fail,
        // and that says nothing about the push source.
        if (!r || r._tbPushed) return;
        var s = evt.type === 'htmx:responseError' && d.xhr ? d.xhr.status : 0;
        markFail(r, s === 0 || s === 502 || s === 503 || s === 504 ? '' : 'HTTP ' + s, true);
    }
    ['htmx:sendError', 'htmx:timeout', 'htmx:responseError'].forEach(function(name){
        document.addEventListener(name, pollFailed);
    });
    // WebSocket sources (htmx ws extension). A frame message confirms its
    // source; board messages are confirmed by the reconciler (they never
    // reach wsAfterMessage). A close or error fails the source and every
    // live board on it, except the server ending a stream normally after
    // its last update: when nothing shown is still running there is nothing
    // left to go stale.
    function socketRegions(s){
        var out = [];
        if (s.querySelector(FRAME_SEL)){ liveRegions.add(s); out.push(s); }
        var boards = s.querySelectorAll('.treebar-board');
        for (var i = 0; i < boards.length; i++) if (liveRegions.has(boards[i])) out.push(boards[i]);
        return out;
    }
    document.addEventListener('htmx:wsAfterMessage', function(evt){
        if (evt.target.querySelector && evt.target.querySelector(FRAME_SEL)){
            liveRegions.add(evt.target);
            markOk(evt.target);
        }
    });
    document.addEventListener('htmx:wsClose', function(evt){
        var e = evt.detail && evt.detail.event, code = e ? e.code : 0;
        // The codes the ws extension reconnects after.
        var retrying = [1006, 1011, 1012, 1013].indexOf(code) >= 0;
        socketRegions(evt.target).forEach(function(r){
            if ((code === 1000 || code === 1005) && !r.querySelector(RUNNING_SEL)){ markOk(r); r._tbSettled = true; }
            else markFail(r, '', retrying);
        });
    });
    document.addEventListener('htmx:wsError', function(evt){
        socketRegions(evt.target).forEach(function(r){ markFail(r, '', true); });
    });
    // --- Pushed pollers -----------------------------------------------------
    // A push source (a server-sent-events stream, a custom socket) can feed
    // a poller in place of its own polls. window.treebarUpdatePoller(el,
    // html) applies one pushed answer, the response a poll would have
    // received, exactly as htmx applies a poll answer (so a page's
    // htmx:beforeSwap gate or rewrite, terminalization and every
    // htmx:afterSwap listener run unchanged), and confirms the poller live,
    // also when a listener skips the answer, as a skipped poll answer does.
    // Called without html it only confirms that the shown
    // answer is still current: a heartbeat. The first call puts the poller
    // in push mode: its own polls are suspended (see the pause hook below)
    // and the answer of a poll already in flight is dropped, so a late poll
    // answer cannot replace a newer pushed one. That poll is left to finish:
    // htmx reports every aborted request as an error (console.error and
    // htmx:error), however deliberate the abort, and has no setting for it.
    // While the viewer has paused the poller, the newest pushed answer is
    // held and shown on resume; meanwhile the shown state ages as a paused
    // polled one does.
    // window.treebarPollerLost(el, why) ends push mode: the poller falls
    // back to its own polls, which retry by themselves, and reads
    // "Connection lost" (empty `why`) or "Updates failing (why)" once those
    // have failed for 5s too. `el` is the poller wrapper or any element in
    // it. Both return false once it is no longer a live poller (finished,
    // failed or removed), which tells the source to stop pushing to it.
    var heldPollers = new Set();
    // The polling inner of the live poller `el` is in, or null. A finished
    // poller nested in a live one must not resolve to the outer one.
    function pushTarget(el){
        var p = el.closest('.treebar-poller, .treebar-terminal');
        if (!p || !p.isConnected || !p.classList.contains('treebar-poller')) return null;
        return p.querySelector(':scope > .treebar-poller-inner[hx-trigger]');
    }
    // htmx fires htmx:beforeSwap only for the response to a request, and
    // htmx.swap fires none, so this offers a pushed answer the way htmx offers
    // a poll answer. The detail has a poll answer's fields, without xhr since
    // no request ran, plus treebarPushed. What a listener changes is read back
    // as htmx reads it, except that isError does nothing (no request to fail)
    // and only swapOverride's style counts (htmx has no public way to parse
    // its modifiers).
    function swapPushed(inner, html){
        var url = inner.getAttribute('hx-get');
        var d = {shouldSwap: true, serverResponse: html, isError: false,
            ignoreTitle: htmx.config.ignoreTitle, selectOverride: undefined, swapOverride: undefined,
            target: inner, boosted: false, select: undefined, etc: {},
            requestConfig: {elt: inner, target: inner, verb: 'get', path: url},
            pathInfo: {requestPath: url, finalRequestPath: url},
            treebarPushed: true};
        if (!htmx.trigger(inner, 'htmx:beforeSwap', d) || !d.shouldSwap) return;
        // The settle delay htmx gives the inner's own hx-swap="outerHTML".
        htmx.swap(d.target, d.serverResponse,
            {swapStyle: d.swapOverride ? String(d.swapOverride).trim().split(/\\s+/)[0] : 'outerHTML',
             settleDelay: htmx.config.defaultSettleDelay, ignoreTitle: d.ignoreTitle},
            {select: d.selectOverride === 'unset' ? null : d.selectOverride || inner.getAttribute('hx-select'),
             contextElement: inner});
    }
    function applyPushed(inner, html, at){
        var p = inner.parentElement;
        if (html != null) swapPushed(inner, html);
        markOk(p, at);
    }
    // Registered on the polling element, not the document: a pushed answer
    // replaces that element, and a detached element's events never reach the
    // document. htmx returns before parsing an answer dropped here, so its
    // out-of-band content and response headers do nothing, and it still ends
    // the request, so the element can poll again if it is handed back. The
    // answer stops here too: to the page's own listeners (HTMXObjects marks
    // an operation finished on seeing its last answer) this poll was never
    // answered, and a poller handed back asks again. A request of an element
    // inside the inner passes through; a handed-back poller's answer is an
    // ordinary poll answer.
    function dropLatePoll(evt){
        if (evt.target !== this) return;
        if (this.isConnected && !this.parentElement._tbPushed) return;
        evt.preventDefault();
        evt.stopPropagation();
    }
    window.treebarUpdatePoller = function(el, html){
        var inner = pushTarget(el);
        if (!inner) return false;
        var p = inner.parentElement, at = Date.now();
        if (!p._tbPushed){
            p._tbPushed = true;
            inner.addEventListener('htmx:beforeOnLoad', dropLatePoll);
        }
        if (p.dataset.paused === '1'){
            p._tbHeld = {html: html != null ? html : p._tbHeld && p._tbHeld.html, at: at};
            heldPollers.add(p);
        } else applyPushed(inner, html, at);
        return true;
    };
    window.treebarPollerLost = function(el, why){
        var inner = pushTarget(el);
        if (!inner) return false;
        var p = inner.parentElement;
        if (p._tbPushed){
            p._tbPushed = false;
            // The resumed polls bring the next answer.
            p._tbHeld = undefined;
            heldPollers.delete(p);
            markFail(p, why || '', true);
        }
        return true;
    };
    // Run by the ticker: show what was held for a poller the viewer resumed.
    function flushHeld(){
        heldPollers.forEach(function(p){
            if (p.isConnected && p.dataset.paused === '1') return;
            heldPollers.delete(p);
            var held = p._tbHeld, inner = pushTarget(p);
            p._tbHeld = undefined;
            if (inner) applyPushed(inner, held.html, held.at);
        });
    }
    // Lazy prune: removals and terminalizations drop out on the next tick.
    function runningAlive(el){
        if (!el.isConnected || el.dataset.treebarStatus !== 'running'){ liveRunning.delete(el); return false; }
        return true;
    }
    function syncBadgeLive(p){
        if (!p.isConnected || !p.classList.contains('treebar-poller')){ livePollers.delete(p); return; }
        syncBadge(p);
    }
    function syncAllBadges(){
        livePollers.forEach(syncBadgeLive);
    }
    window.__tbSyncBadge = syncBadge;
    // Re-anchor only spans whose server value changed (or that are new). A swap
    // replaces the spans it delivers, so fresh ones anchor from their own
    // data-elapsed-ms; a span the swap did NOT touch keeps its anchor. Blindly
    // re-reading every span on every swap would reset an untouched span (a
    // board item between its 1s polls, a sibling poller) back to the
    // server value it was rendered with, so it would jump backwards.
    function reanchorAll(){
        liveRunning.forEach(function(el){
            if (runningAlive(el) && (el._tbAnchoredFrom === undefined || el._tbAnchoredFrom !== el.dataset.elapsedMs)) anchor(el);
        });
    }
    function tickAll(){
        flushHeld();
        liveRunning.forEach(function(el){ if (runningAlive(el)) tick(el); });
        syncAllBadges();
        paintRegions();
    }
    function reanchorAndTick(evt){
        // Scope the synchronous refresh to the swapped target; the observer
        // below backstops every other insertion path (OOB inserts outside
        // the target, ws frames, in-place morphs), so this never needs a
        // document-wide scan.
        var t = evt && evt.detail && (evt.detail.target || evt.detail.elt);
        if (t && (t.nodeType === 1 || t.nodeType === 9)) collect(t);
        reanchorAll();
        tickAll();
    }
    // Backstop: every DOM insertion and every status/estimate edit lands
    // here, so nodes the swap handler cannot see still join or leave the
    // live sets. Each callback costs work proportional to the changed nodes
    // only. Poller wrappers are born by insertion (childList) and die by
    // terminalization or removal (lazy prune in syncBadgeLive) — never by a
    // class flip a filter would need to watch, so `class` stays unobserved.
    // Viewer choices carried across live updates. A poll swap, a WebSocket
    // frame and a board update each replace rendered markup wholesale, and
    // the old markup leaves in the same observer batch that brings its
    // replacement, so a choice the viewer made on the old markup is moved
    // onto the new one before it paints: a disclosure's open state, matched
    // by data-treebar-disclosure in document order, and a WebSocket frame's
    // pill toggles (data-show-*), matched by the frame's id. Server defaults
    // apply only to markup that replaces nothing. Costs work proportional to
    // the changed fragments, like the live sets above.
    var CARRY_SEL = 'details[data-treebar-disclosure], .treebar-ws-frame[id]';
    function eachCarried(root, fn){
        if (root.nodeType !== 1) return;
        if (root.matches(CARRY_SEL)) fn(root);
        var q = root.querySelectorAll(CARRY_SEL);
        for (var i = 0; i < q.length; i++) fn(q[i]);
    }
    function carryViewerState(removed, added){
        if (!removed.length || !added.length) return;
        var open = {}, frames = {}, any = false;
        removed.forEach(function(root){ eachCarried(root, function(el){
            any = true;
            if (el.tagName !== 'DETAILS'){ frames[el.id] = el; return; }
            var key = el.dataset.treebarDisclosure;
            (open[key] = open[key] || []).push(el.open);
        }); });
        if (!any) return;
        added.forEach(function(root){
            if (!root.isConnected) return;
            eachCarried(root, function(el){
                if (el.tagName !== 'DETAILS'){
                    var from = frames[el.id];
                    if (from) Object.keys(from.dataset).forEach(function(k){
                        if (k.indexOf('show') === 0) el.dataset[k] = from.dataset[k];
                    });
                    return;
                }
                var was = open[el.dataset.treebarDisclosure];
                if (was && was.length){ var o = was.shift(); if (el.open !== o) el.open = o; }
            });
        });
    }
    var tbObserver = new MutationObserver(function(records){
        var removed = [], added = [];
        for (var i = 0; i < records.length; i++){
            var r = records[i];
            if (r.type === 'childList'){
                for (var j = 0; j < r.addedNodes.length; j++){ collect(r.addedNodes[j]); added.push(r.addedNodes[j]); }
                for (var k = 0; k < r.removedNodes.length; k++) removed.push(r.removedNodes[k]);
            } else if (r.type === 'attributes' && r.target.nodeType === 1){
                var el = r.target;
                if (!el.classList.contains('treebar-duration')) continue;
                if (r.attributeName === 'data-treebar-status'){
                    if (el.dataset.treebarStatus === 'running') trackRunning(el);
                    else liveRunning.delete(el);
                } else if ((r.attributeName === 'data-elapsed-ms' || r.attributeName === 'data-eta-ms') &&
                           el.dataset.treebarStatus === 'running'){
                    // A morph refreshed the server estimate in place:
                    // re-anchor so the ticker counts from the fresh value.
                    anchor(el);
                    liveRunning.add(el);
                }
            }
        }
        carryViewerState(removed, added);
    });
    // htmx 2 announces each swap on every element its answer has settled so
    // far, all with one shared detail: an answer with N out-of-band elements
    // fires htmx:afterSwap N+1 times and htmx:oobAfterSwap N(N+3)/2 times (its
    // k-th out-of-band swap k+1 times). Announcements of one swap differ only
    // in detail.elt, which only terminalization reads, so that runs on every
    // announcement; the refresh reads detail.target and runs once per swap,
    // and again after a terminalization, which it must follow. Without a
    // detail.target the refresh is scoped by detail.elt, so each of those
    // announcements refreshes. An answer then costs work linear in its swaps,
    // not in their square.
    function onSwapAnnounced(){
        var refreshed = new WeakSet();
        return function(evt){
            var d = evt && evt.detail;
            var ended = terminalizePoller(evt);
            if (d && d.target){
                if (!ended && refreshed.has(d)) return;
                refreshed.add(d);
            }
            reanchorAndTick(evt);
        };
    }
    document.addEventListener('htmx:afterSwap', onSwapAnnounced());
    document.addEventListener('htmx:oobAfterSwap', onSwapAnnounced());

    // --- Keyed board (htmx_render_board) -----------------------------------
    // Every update — a poll response, a WebSocket frame, treebarUpdateBoard —
    // carries the FULL current list, so reconciling is idempotent and a dropped
    // update costs nothing. Items are matched by data-treebar-key: an existing
    // item keeps its wrapper (and the UI state on it) and swaps only its
    // .treebar-board-item-content; a new item is inserted in server order; an
    // item that left the list shows its final state for the board's linger
    // time and is then removed. The server decides how long a done/failed item
    // stays listed, so a board can also hold recent history.
    function isTerminalState(s){ return s === 'done' || s === 'failed' || s === 'ended'; }
    function boardList(board){ return board.querySelector(':scope > .treebar-board-list'); }
    function boardItems(list){
        return Array.prototype.filter.call(list.children, function(c){
            return c.classList.contains('treebar-board-item');
        });
    }
    function boardEmpty(board){
        var list = boardList(board), empty = board.querySelector(':scope > .treebar-board-empty');
        if (list && empty) empty.hidden = boardItems(list).length > 0;
    }
    function boardLinger(board, item){
        var ms = parseInt(item.dataset.treebarLingerMs || board.dataset.treebarLingerMs, 10);
        return isNaN(ms) ? 3000 : Math.max(0, ms);
    }
    function scheduleLeave(board, item){
        if (item._tbLeave) return;
        var leave = function(){
            // A paused board is frozen: lingering items wait for Resume.
            if (board.dataset.paused === '1'){ item._tbLeave = setTimeout(leave, 250); return; }
            item.remove();
            boardEmpty(board);
        };
        item._tbLeave = setTimeout(leave, boardLinger(board, item));
    }
    function cancelLeave(item){
        if (!item._tbLeave) return;
        clearTimeout(item._tbLeave);
        item._tbLeave = null;
        item.classList.remove('treebar-board-leaving');
    }
    // An item that left the list lingers, then leaves. If the server never
    // showed it terminal it ends where it stands: clocks freeze, it reads
    // "ended".
    function endItem(board, item){
        if (!isTerminalState(item.dataset.treebarState)){
            item.dataset.treebarState = 'ended';
            var hd = item.querySelector('.treebar-board-duration');
            if (hd){
                var ms = hd._tbAnchor !== undefined ? Date.now() - hd._tbAnchor : parseInt(hd.dataset.elapsedMs, 10) || 0;
                hd.dataset.treebarStatus = 'ended';
                var T = textsOf(board);
                hd.textContent = ' — ' + fill(T.ended, {elapsed: fmt(ms, T)});
            }
            var tree = item.querySelector('.treebar-board-tree');
            if (tree) tree.classList.add('treebar-frozen');
        }
        item.classList.add('treebar-board-leaving');
        scheduleLeave(board, item);
    }
    function updateItem(item, next){
        var content = next.querySelector(':scope > .treebar-board-item-content');
        if (!content) return;
        content = document.importNode(content, true);
        // The tree's expanded state belongs to the wrapper, not the response.
        var tree = content.querySelector(':scope > .treebar-board-tree');
        if (tree) tree.open = item.dataset.open === '1';
        var old = item.querySelector(':scope > .treebar-board-item-content');
        old ? item.replaceChild(content, old) : item.appendChild(content);
        ['treebarState', 'treebarLingerMs'].forEach(function(k){
            if (next.dataset[k] === undefined) delete item.dataset[k]; else item.dataset[k] = next.dataset[k];
        });
        if (window.htmx) htmx.process(content);
    }
    function reconcileBoard(board, incoming){
        var list = boardList(board), next = boardList(incoming);
        if (!list || !next) return;
        var live = {}, seen = {}, prev = null;
        boardItems(list).forEach(function(it){ live[it.dataset.treebarKey] = it; });
        boardItems(next).forEach(function(n){
            var key = n.dataset.treebarKey, state = n.dataset.treebarState, item = live[key];
            seen[key] = true;
            if (!item){
                item = document.importNode(n, true);
                if (window.htmx) htmx.process(item);
            } else {
                // Listed again after dropping out (a flapping filter): it stays.
                cancelLeave(item);
                updateItem(item, n);
            }
            var at = prev ? prev.nextSibling : list.firstChild;
            if (item !== at) list.insertBefore(item, at);
            prev = item;
        });
        Object.keys(live).forEach(function(key){ if (!seen[key]) endItem(board, live[key]); });
        var count = board.querySelector(':scope > .treebar-board-header > .treebar-board-count');
        var ncount = incoming.querySelector(':scope > .treebar-board-header > .treebar-board-count');
        if (count && ncount) count.replaceWith(document.importNode(ncount, true));
        var overview = board.querySelector(':scope > .treebar-board-overview');
        var noverview = incoming.querySelector(':scope > .treebar-board-overview');
        if (noverview) {
            var freshOverview = document.importNode(noverview, true);
            if (overview) overview.replaceWith(freshOverview);
            else board.insertBefore(freshOverview, list);
        } else if (overview) overview.remove();
        boardEmpty(board);
        // The reconciler inserts spans through DOM APIs, not an htmx swap, so
        // track them synchronously (scoped to the board); the observer below
        // backstops the same insertions idempotently.
        collect(board);
        reanchorAll(); tickAll();
    }
    function parseBoards(html){
        if (typeof html !== 'string' || html.indexOf('treebar-board') === -1) return [];
        var t = document.createElement('template');
        t.innerHTML = html;
        return Array.prototype.slice.call(t.content.querySelectorAll('.treebar-board'));
    }
    // Apply every board in `html` to the live board with the same id; returns
    // how many were applied (or dropped because that board is paused). The
    // single client entry point for any transport — polls and htmx WebSocket
    // frames route through it; SSE or custom sockets can call it directly.
    function updateBoards(html){
        var n = 0;
        parseBoards(html).forEach(function(incoming){
            var board = incoming.id && document.getElementById(incoming.id);
            if (!board || !board.classList.contains('treebar-board')) return;
            n += 1;
            if (board.dataset.paused === '1') return;
            reconcileBoard(board, incoming);
            markOk(board);
        });
        return n;
    }
    window.treebarUpdateBoard = updateBoards;
    // Board polls: htmx would replace the board (the no-script fallback the
    // poll element's hx-target/hx-select describe); hand the response to the
    // reconciler instead.
    document.addEventListener('htmx:beforeSwap', function(evt){
        var d = evt.detail || {};
        if (!d.shouldSwap) return;
        // detail.elt is the swap TARGET here; the requester is on requestConfig.
        var el = (d.requestConfig && d.requestConfig.elt) || d.elt;
        var board = el && el.classList && el.classList.contains('treebar-board-poll') ?
            el.closest('.treebar-board') : d.target;
        if (!board || !board.classList || !board.classList.contains('treebar-board')) return;
        d.shouldSwap = false;
        if (board.dataset.paused === '1') return;
        var incoming = parseBoards(d.serverResponse).filter(function(b){ return b.id === board.id; })[0];
        if (incoming) reconcileBoard(board, incoming);
    });
    // WebSocket boards (htmx ws extension, see ws_board): same reconciler.
    document.addEventListener('htmx:wsBeforeMessage', function(evt){
        if (updateBoards(evt.detail && evt.detail.message) > 0) evt.preventDefault();
    });
    // Remember a board item's tree expansion on its wrapper (toggle does not
    // bubble, hence the capture listener).
    document.addEventListener('toggle', function(evt){
        var d = evt.target;
        if (!d.classList || !d.classList.contains('treebar-board-tree')) return;
        var item = d.closest('.treebar-board-item');
        if (item) item.dataset.open = d.open ? '1' : '0';
    }, true);
    // Pause: cancel a poller's own `every Xs` poll request while its wrapper
    // is data-paused, or while a push source feeds it (see "Pushed pollers").
    // Scoped to the .treebar-poller-inner element, so the
    // Stop/cancel request (a different element) still fires when paused. The
    // `every` timer keeps rescheduling, so resume needs no re-arming. Keyed
    // on closest('.treebar-poller') → self-contained per poller (nested
    // pollers each govern their own polling).
    document.addEventListener('htmx:beforeRequest', function(evt){
        var el = evt.detail && evt.detail.elt;
        if (el && el.classList.contains('treebar-poller-inner')){
            var p = el.closest('.treebar-poller');
            if (p && (p.dataset.paused === '1' || p._tbPushed)) evt.preventDefault();
        }
        // A board's poll element pauses the same way, keyed on its board.
        if (el && el.classList.contains('treebar-board-poll')){
            var b = el.closest('.treebar-board');
            if (b && b.dataset.paused === '1') evt.preventDefault();
        }
    });
    function start(){
        // The ONE full-document pass: seeds both live sets. Everything
        // after this is incremental (scoped swap refresh + observer).
        collect(document);
        if (!window.__tbObserverStarted){
            window.__tbObserverStarted = true;
            tbObserver.observe(document.documentElement, {childList: true, subtree: true,
                attributes: true, attributeFilter: ['data-treebar-status', 'data-elapsed-ms', 'data-eta-ms']});
        }
        reanchorAndTick();
        if (!window.__tbTickerStarted){ window.__tbTickerStarted = true; setInterval(tickAll, 100); }
    }
    if (document.readyState === 'loading'){
        document.addEventListener('DOMContentLoaded', start);
    } else {
        start();
    }
})();
"""))
