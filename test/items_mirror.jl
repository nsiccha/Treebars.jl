using TestItemRunner

# Progress mirrors (`mirror_progress` / `progress_replica` / `apply_frame!`,
# todo 0yn00fr): a tree in one process shown live, as an ordinary tree, in
# another. Frames pass through `Serialization` here, as they do between
# processes, unless a test says otherwise.

@testsnippet MirrorHelpers begin
    using Serialization
    roundtrip(frame) = deserialize(IOBuffer(sprint(serialize, frame)))
    # A running node's duration and ETA are read off the clock at render time,
    # so two renders a moment apart differ there and nowhere else.
    strip_live(s) = replace(s, r" \[[^\]]*\]" => "", r" · ETA ~\S+" => "")
    # Both timestamps of every node, depth first, children in their order.
    times(node) = Any[(node.impl.description, node.impl.started_at, node.impl.finalized_at),
        (times(c) for c in collect(node.children))...]
    count_nodes(node) = 1 + sum(count_nodes, collect(node.children); init=0)
    html(x) = sprint(show, MIME"text/html"(), x)
    # A source, its mirror into a replica, and a function applying everything
    # sent so far.
    function mirrored(root; interval=60, on_interrupt=nothing, target=initialize_progress!(:state; description="queued"))
        frames = ProgressFrame[]
        m = mirror_progress(f -> push!(frames, roundtrip(f)), root; interval)
        replica = progress_replica(target; on_interrupt)
        apply_all!() = (applied = [apply_frame!(replica, f) for f in frames]; empty!(frames); applied)
        sync!() = (flush(m); apply_all!())
        (; m, frames, target, replica, apply_all!, sync!)
    end
end

@testitem "a replica renders as its source, while running and when finished" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    root = initialize_progress!(:state; description="Fit")
    (; m, target, replica, sync!, apply_all!) = mirrored(root)
    @test isopen(m)
    # The opening frame, sent before mirror_progress returned, is the whole tree.
    apply_all!()
    @test strip_live(render_text(target)) == strip_live(render_text(root))

    draws = initialize_progress!(root; description="draws", N=10)
    update_progress!(draws, 4)
    update_progress!(draws; chains=4)                  # an annotation child
    broken = initialize_progress!(root; description="broken")
    fail_progress!(broken)
    never = prepare_progress!(root; description="never")
    skip_progress!(never)
    cached = prepare_progress!(root; description="cached")
    reuse_progress!(cached)
    later = prepare_progress!(root; description="later")
    hidden = initialize_progress!(root; description="", displayed=false)
    initialize_progress!(hidden; description="hoisted leaf")
    update_progress!(initialize_progress!(root; description="indeterminate"), "a message")

    mid = Ref("")
    mid_overview = Ref{Any}(nothing)
    @progress root "Items" for item in 1:3
        @progress "Load"
        if item == 2
            sync!()
            @test strip_live(render_text(target)) == strip_live(render_text(root))
            @test strip_live(render_text(target; phase_overview=true)) == strip_live(render_text(root; phase_overview=true))
            @test phase_overview(target) == phase_overview(root)
            mid[] = render_text(target; phase_overview=true)
        end
        @progress "Fit"
    end
    # The second item was mid-way: its Load running, the first item done.
    @test occursin("Load: 0 pending · 1 running · 1 finished", mid[])
    @test occursin(r"▶ Items \(1/3\)", mid[])

    finalize_progress!(draws)
    finalize_progress!(root)                           # `later` is skipped here
    close(m)
    @test !isopen(m)
    apply_all!()
    @test replica.final
    @test render_text(target) == render_text(root)
    @test render_text(target; phase_overview=true) == render_text(root; phase_overview=true)
    @test phase_overview(target) == phase_overview(root)
    @test occursin("Load: 0 pending · 0 running · 3 finished", render_text(target; phase_overview=true))
    @test times(target) == times(root)
    @test duration(target) == duration(root)
    @test is_skipped(only(c for c in target.children if c.impl.description == "later"))
    @test is_reused(only(c for c in target.children if c.impl.description == "cached"))
    @test is_failed(only(c for c in target.children if c.impl.description == "broken"))
    # Nothing in the replica is left over from nodes that left the source (the
    # finished transient items).
    @test length(replica.nodes) == count_nodes(root)
    end
end

@testitem "notes cross as notes: the replica's page language, and the app's own words" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror, :texts] begin
    let
    notes = treebar_notes(en = (from_disk = "from disk: {size}",),
                          de = (from_disk = "von der Platte: {size}",))
    root = initialize_progress!(:state; description="Load")
    (; m, target, apply_all!) = mirrored(root)
    leaf = initialize_progress!(root; description="table")
    update_progress!(leaf, notes(:from_disk; size=ByteSize(27_000_000)))
    finalize_progress!(root)
    close(m)
    apply_all!()
    copy = only(target.children).impl.message
    @test copy isa TreebarNote
    # It crossed through Serialization: its table is a copy, with the same words.
    @test copy.notes !== notes
    @test copy.notes.fingerprint == notes.fingerprint
    @test render_text(target) == render_text(root)
    @test occursin("from disk: 25.7 MB", render_text(target))
    de = html(htmx_render(target; texts=treebar_texts(:de)))
    @test occursin("von der Platte: 25,7 MB", de)
    @test de == html(htmx_render(root; texts=treebar_texts(:de)))
    # The app's override, keyed by its own table, finds the copy too.
    own = treebar_texts(:de, notes => (from_disk = "geladen ({size})",))
    @test occursin("geladen (25,7 MB)", html(htmx_render(target; texts=own)))
    @test html(htmx_render(target; texts=own)) == html(htmx_render(root; texts=own))
    # Different words, different fingerprint.
    @test treebar_notes(en = (from_disk = "from disk {size}",)).fingerprint != notes.fingerprint
    end
end

@testitem "htmx_render and the poller draw a replica as they draw its source" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    ext = Base.get_extension(Treebars, :HTMXObjectsExt)
    root = initialize_progress!(:state; description="Export")
    (; m, target, sync!, apply_all!) = mirrored(root)
    @progress root "Items" for item in 1:2
        @progress "Load"
        @progress "Fit"
    end
    running = initialize_progress!(root; description="fit", N=4)
    update_progress!(running, 1)
    sync!()
    poller(node) = html(ext._polling_running(node; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url="/stop", phase_overview=true))
    # Running: the same markup, up to the times read off the clock.
    # Two passes: one `replace` call matches each position with one pattern.
    live(s) = replace(replace(s, r" data-(elapsed|eta)-ms=\"\d+\"" => ""),
        r"(<span class=\"treebar-duration\"[^>]*>)[^<]*" => s"\1")
    @test live(poller(target)) == live(poller(root))
    # The items finished and left the tree before this frame; their plan's
    # counts came along anyway.
    @test occursin("Items · 2 prepared items", poller(target))
    task = @async sleep(30)
    resolve(node) = html(ext._polling_resolve(task, node; label="Background job", poll_url="/poll",
        poll_interval="200ms", cancel_url="", render_result=identity))
    @test occursin("treebar-poller-inner", resolve(target))
    @test live(resolve(target)) == live(resolve(root))
    finalize_progress!(root)
    close(m)
    apply_all!()
    # Finished: byte for byte, overview and German words included.
    for kw in ((;), (; phase_overview=true), (; phase_overview=:collapsed, texts=treebar_texts(:de)))
        @test html(htmx_render(target; kw...)) == html(htmx_render(root; kw...))
    end
    @test poller(target) == poller(root)
    end
end

@testitem "lost, late and foreign frames: the final frame restores the exact tree" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    root = initialize_progress!(:state; description="Run")
    frames = ProgressFrame[]
    # Explicit flushes keep the lost creation frame separate from a later
    # delta. With interval=0 the background sender can coalesce them, leaving
    # only the final frame after the loss (and no gap to count yet).
    m = mirror_progress(f -> push!(frames, roundtrip(f)), root; interval=60)
    a = initialize_progress!(root; description="a", N=3)
    update_progress!(a)
    flush(m)
    b = initialize_progress!(root; description="b")
    flush(m)
    update_progress!(b, "step one")
    update_progress!(a)
    finalize_progress!(a)
    finalize_progress!(root)
    flush(m)
    close(m)
    @test frames[1].full && !frames[1].final
    @test frames[end].full && frames[end].final
    @test all(!f.full for f in frames[2:end-1])
    @test [f.seq for f in frames] == 1:length(frames)

    # Lose the frame that created `b`: later frames apply as far as they can.
    target = initialize_progress!(:state; description="queued")
    replica = progress_replica(target)
    lost = findfirst(f -> any(n -> n.description == "b", f.nodes), frames)
    @test lost !== nothing && lost < length(frames)
    for (k, f) in enumerate(frames[1:end-1])
        k == lost && continue
        @test apply_frame!(replica, f)
    end
    @test replica.gaps == 1
    @test !any(c -> c.impl.description == "b", target.children)
    @test apply_frame!(replica, frames[end])
    @test render_text(target) == render_text(root)
    @test times(target) == times(root)

    # Late: an old frame, or any frame after the final one, changes nothing.
    @test !apply_frame!(replica, frames[2])
    @test !apply_frame!(replica, frames[end])
    @test render_text(target) == render_text(root)

    # Applying the same frames twice is harmless (each node carries its whole
    # state), and a frame of another mirror is ignored.
    t2 = initialize_progress!(:state; description="queued")
    r2 = progress_replica(t2)
    for f in frames[1:end-1]
        apply_frame!(r2, f)
        r2.seq -= 1
        apply_frame!(r2, f)
    end
    @test strip_live(render_text(t2)) == strip_live(render_text(target))
    other = ProgressFrame[]
    m2 = mirror_progress(f -> push!(other, f), initialize_progress!(:state; description="other"))
    close(m2)
    @test !apply_frame!(r2, other[1])
    end
end

@testitem "Stop on the replica reaches the source node, and later children" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror, :interrupt] begin
    let
    asked = Int[]
    page = initialize_progress!(:state; description="Page")
    target = initialize_progress!(page; description="queued")
    root = initialize_progress!(:state; description="Worker fit")
    (; m, sync!, replica) = mirrored(root; target, on_interrupt = id -> push!(asked, id))
    stage = initialize_progress!(root; description="stage")
    inner = initialize_progress!(stage; description="inner")
    sync!()
    # A viewer stops a node of the replica: its id goes to the source side,
    # which applies it to the real node.
    replica_stage = only(c for c in target.children if c.impl.description == "stage")
    request_interrupt!(replica_stage)
    @test asked == [replica.ids[replica_stage]]
    request_interrupt!(m, only(asked))
    @test stage.interrupt[]
    @test interrupt_requested(inner)
    later = initialize_progress!(stage; description="created later")
    @test interrupt_requested(later)
    @test !interrupt_requested(root)
    sync!()
    @test occursin(r"▶ stage \[[^\]]*\] · interrupt requested", render_text(target))
    # A Stop above the replica (the page's) reaches the source root, once.
    request_interrupt!(page)
    @test asked[end] == 1
    request_interrupt!(page)
    @test count(==(1), asked) == 1
    request_interrupt!(m, 1)
    @test interrupt_requested(root)
    # Unknown ids are ignored.
    @test request_interrupt!(m, 10_000) === m
    finalize_progress!(root)
    close(m)
    # A request already made when the replica is set up is passed on at once.
    early = Int[]
    stopped = initialize_progress!(:state; description="stopped")
    request_interrupt!(stopped)
    progress_replica(stopped; on_interrupt = id -> push!(early, id))
    @test early == [1]
    # A failing handler is logged; the request itself stands.
    noisy = progress_replica(initialize_progress!(:state; description="noisy"); on_interrupt = _ -> error("down"))
    @test_logs (:error, r"on_interrupt") request_interrupt!(noisy.target)
    @test noisy.target.interrupt[]
    close(noisy)
    end
end

@testitem "structure changes made anywhere are mirrored: add_child!, a direct pop!, empty!" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    root = initialize_progress!(:state; description="Reader")
    (; m, target, replica, sync!, apply_all!) = mirrored(root)
    # A node made elsewhere and attached, as DynamicObjects attaches a shared
    # computation's node under each reader.
    elsewhere = initialize_progress!(:state; description="elsewhere")
    shared = initialize_progress!(elsewhere; description="shared lookup", N=2)
    initialize_progress!(shared; description="its own child")
    a = initialize_progress!(root; description="a")
    b = initialize_progress!(root; description="b")
    add_child!(a, shared)
    add_child!(b, shared)                              # held twice
    sync!()
    @test strip_live(render_text(target)) == strip_live(render_text(root))
    update_progress!(shared)                           # one change, under both
    sync!()
    replica_of(desc) = only(n for n in values(replica.nodes) if n.impl.description == desc)
    @test replica_of("shared lookup") in replica_of("a").children
    @test replica_of("shared lookup") in replica_of("b").children
    @test replica_of("shared lookup").impl.i == 1
    # Removed straight from the children set, the way DynamicObjects detaches.
    pop!(a.children, shared, nothing)
    sync!()
    @test strip_live(render_text(target)) == strip_live(render_text(root))
    @test !(replica_of("shared lookup") in replica_of("a").children)
    @test Treebars._track_for(shared, m) !== nothing   # b still holds it
    pop!(b.children, shared, nothing)
    sync!()
    @test Treebars._track_for(shared, m) === nothing   # left the tree: no longer followed
    @test Treebars._track_for(only(shared.children), m) === nothing
    update_progress!(shared)                           # no longer mirrored
    @test !(@atomic m.pending)
    add_child!(root, shared)                           # back again, followed afresh
    initialize_progress!(b; description="b1")
    initialize_progress!(b; description="b2")
    empty!(b.children)
    sync!()
    @test strip_live(render_text(target)) == strip_live(render_text(root))
    # Order follows the source, including a node pushed again after removal.
    pop!(root.children, a)
    push!(root.children, a)
    sync!()
    @test [c.impl.description for c in target.children] == [c.impl.description for c in root.children]
    @test length(replica.nodes) == count_nodes(root)
    close(m)
    apply_all!()
    @test strip_live(render_text(target)) == strip_live(render_text(root))
    @test times(target) == times(root)
    # A closed mirror leaves nothing on the nodes it followed.
    @test isnothing(@atomic root.impl.track)
    @test isnothing(@atomic root.children.track)
    @test isnothing(@atomic shared.impl.track)
    end
end

@testitem "mirror_progress: do-block, nothing, bad arguments, a failing send" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    frames = ProgressFrame[]
    root = initialize_progress!(:state; description="Job")
    rv = mirror_progress(f -> push!(frames, f), root) do
        @progress root "steps" for i in 1:3
        end
        :done
    end
    @test rv === :done
    @test frames[end].final
    @test sprint(show, frames[end]) == "ProgressFrame(#$(length(frames)), final, 2 nodes, 2 child lists, 0 plans)"
    @test mirror_progress(identity, nothing) === nothing
    @test mirror_progress(() -> 7, identity, nothing) == 7
    @test_throws ArgumentError mirror_progress(identity, root; interval=-1)
    # The first send fails loudly, before any work runs, and leaves no trace.
    @test_throws ErrorException mirror_progress(_ -> error("no channel"), root)
    @test isnothing(@atomic root.impl.track)
    # Later, a failing send closes the mirror once, logged; the run carries on.
    sends = Ref(0)
    m = Ref{Any}(nothing)
    @test_logs (:error, r"could not send a progress frame") match_mode=:any begin
        m[] = mirror_progress(_ -> (sends[] += 1) > 1 && error("gone"), root; interval=0)
        initialize_progress!(root; description="next")
        timedwait(() -> !isopen(m[]), 5)
    end
    @test !isopen(m[])
    @test isnothing(@atomic root.impl.track)
    close(m[])                                         # nothing more is sent
    @test sends[] == 2
    @test sprint(show, m[]) == "ProgressMirror(\"Job\", closed)"
    end
end

@testitem "a -t1 worker process mirrors its tree over a socket; Stop goes back" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror, :interrupt] begin
    using Sockets
    let
    server = listen(IPv4(127, 0, 0, 1), 0)
    port = getsockname(server)[2]
    # One thread: while the worker busy-waits, every frame comes from the
    # thread changing the tree. The worker reads Stop requests from the same
    # socket whenever it yields.
    script = """
    using Treebars, Serialization, Sockets
    spin(s) = (t = time(); while time() - t < s; end)
    sock = connect(ip"127.0.0.1", $port)
    write_lock = ReentrantLock()
    send(x) = lock(() -> serialize(sock, x), write_lock)
    root = initialize_progress!(:state; description="Worker fit")
    m = mirror_progress(send, root; interval=0.02)
    @async while isopen(sock)
        id = try deserialize(sock) catch; break end
        request_interrupt!(m, id)
    end
    @progress root "busy" for i in 1:20
        spin(0.02)
    end
    waiting = initialize_progress!(root; description="waiting for Stop")
    t0 = time()
    while !interrupt_requested(waiting) && time() - t0 < 60
        sleep(0.01)
    end
    stopped = interrupt_requested(waiting)
    finalize_progress!(root)
    close(m)
    send((:done, stopped, render_text(root)))
    sleep(0.5)
    close(sock)
    """
    proc = run(pipeline(`$(Base.julia_cmd()) --startup-file=no -t1 --project=$(Base.active_project()) -e $script`;
        stdout=stderr, stderr=stderr); wait=false)
    sock = accept(server)
    target = initialize_progress!(:state; description="queued")
    replica = progress_replica(target; on_interrupt = id -> serialize(sock, id))
    busy_frames = 0
    stop_sent = false
    done = nothing
    while true
        x = deserialize(sock)
        if x isa ProgressFrame
            @test apply_frame!(replica, x)
            occursin(r"▶ busy \(\d+/20\)", render_text(target)) && (busy_frames += 1)
            if !stop_sent && occursin("waiting for Stop", render_text(target))
                request_interrupt!(only(c for c in target.children if c.impl.description == "waiting for Stop"))
                stop_sent = true
            end
        else
            done = x
            break
        end
    end
    wait(proc)
    close(server)
    @test success(proc)
    @test busy_frames >= 3                             # the tree moved while the worker was busy
    @test stop_sent
    @test done[1] == :done
    @test done[2]                                      # the worker saw the Stop
    @test replica.final
    @test render_text(target) == done[3]
    @test occursin("✓ busy (20/20)", done[3])
    end
end

@testitem "threads changing one tree at once: the frames alone reproduce it" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    # Every structure change is recorded inside the children set's lock, so the
    # replica gets the children in the order the source has them even when
    # threads add and remove at once. The test needs real threads to mean
    # anything; at -t1 it still runs, serially.
    root = initialize_progress!(:state; description="Parallel")
    frames = ProgressFrame[]
    frames_lock = ReentrantLock()
    m = mirror_progress(f -> lock(() -> push!(frames, roundtrip(f)), frames_lock), root; interval=0.001)
    elsewhere = initialize_progress!(:state; description="elsewhere")
    shared = [initialize_progress!(elsewhere; description="shared $k", N=3) for k in 1:4]
    workers = [initialize_progress!(root; description="worker $w", N=50) for w in 1:4]
    Threads.@threads for w in 1:4
        node = workers[w]
        for i in 1:50
            item = initialize_progress!(node; description="item $i", transient=i % 2 == 0)
            if i % 5 == 0
                add_child!(item, shared[mod1(i ÷ 5, 4)])
                update_progress!(shared[mod1(i ÷ 5, 4)])
                pop!(item.children, shared[mod1(i ÷ 5, 4)], nothing)
            end
            update_progress!(item, "step $i")
            i % 7 == 0 ? fail_progress!(item) : finalize_progress!(item)
            update_progress!(node)
        end
        @progress node "phased" for j in 1:5
            @progress "Load"
            @progress "Fit"
        end
        finalize_progress!(node)
    end
    finalize_progress!(root)
    flush(m)
    target = initialize_progress!(:state; description="queued")
    replica = progress_replica(target)
    deltas = lock(() -> copy(frames), frames_lock)
    @test all(f -> apply_frame!(replica, f), deltas)
    @test replica.gaps == 0
    @test render_text(target; phase_overview=true) == render_text(root; phase_overview=true)
    @test times(target) == times(root)
    @test length(replica.nodes) == count_nodes(root)
    close(m)
    @test apply_frame!(replica, lock(() -> frames[end], frames_lock))
    @test render_text(target; phase_overview=true) == render_text(root; phase_overview=true)
    @test phase_overview(target) == phase_overview(root)
    end
end

@testitem "frames through a Channel, applied by another task while the run goes on" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    # The shape a worker transport has: frames queue in a channel and a
    # receiving task applies them as they arrive, concurrently with the run.
    root = initialize_progress!(:state; description="Streamed")
    target = initialize_progress!(:state; description="queued")
    replica = progress_replica(target)
    channel = Channel{ProgressFrame}(Inf)
    seen_running = Threads.Atomic{Int}(0)
    receiver = Threads.@spawn for frame in channel
        apply_frame!(replica, roundtrip(frame))
        occursin(r"▶ steps \(\d+/40\)", render_text(target)) && Threads.atomic_add!(seen_running, 1)
    end
    mirror_progress(frame -> put!(channel, frame), root; interval=0.005) do
        @progress root "steps" for i in 1:40
            sleep(0.005)
            i % 10 == 0 && update_progress!(__progress__, "at $i")
        end
        finalize_progress!(root)
    end
    close(channel)
    wait(receiver)
    @test seen_running[] >= 3
    @test replica.final
    @test render_text(target) == render_text(root)
    @test times(target) == times(root)
    end
end

@testitem "a long run's mirror and replica stay the size of its tree" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    # Many transient items, each with its own prepared phases: what they leave
    # behind on either side is their counts on the node that keeps them, not
    # one entry per item.
    root = initialize_progress!(:state; description="Long")
    (; m, target, replica, sync!, apply_all!) = mirrored(root; interval=0.001)
    @progress root "Items" for item in 1:300
        @progress "Load"
        @progress "Fit"
        item % 50 == 0 && sync!()
    end
    sync!()
    @test occursin("Load: 0 pending · 0 running · 300 finished", render_text(target; phase_overview=true))
    @test phase_overview(target) == phase_overview(root)
    @test length(replica.nodes) == count_nodes(root)
    @test length(replica.groups) <= 2
    @test length(m.group_ids) <= 2
    @test length(m.groups) == length(m.group_ids)
    @test length(replica.group_ids) == length(replica.groups)
    @test length(m.group_sent) <= 2
    # Finished first: a running root's duration is read off the clock, so two
    # renders of it a moment apart can differ by a millisecond.
    finalize_progress!(root)
    close(m)
    apply_all!()
    @test render_text(target; phase_overview=true) == render_text(root; phase_overview=true)
    end
end

@testitem "mirror plan indexes preserve order and release departed hosts" setup=[TreebarsTestImports, MirrorHelpers] tags=[:unit, :mirror] begin
    let
    root = initialize_progress!(:state; description="plans")
    # Many plans on one host used to copy and scan that host for each plan.
    for i in 1:1600
        with_prepared_phases(_ -> nothing, root, ["plan $i"])
    end
    frames = ProgressFrame[]
    m = mirror_progress(f -> push!(frames, f), root; interval=1e6)
    full() = lock(() -> Treebars._build_frame(m; full=true), m.lock)
    frame = full()
    @test length(frame.groups) == 1600
    @test @allocated(full()) < 8_000_000
    @test frame.group_order == first(frames).group_order
    close(m)

    # Many hosts used to rebuild a global membership set for each one.
    root = initialize_progress!(:state; description="hosts")
    for i in 1:800
        host = initialize_progress!(root; description="host $i")
        with_prepared_phases(_ -> nothing, host, ["plan $i"])
    end
    (; m, target, replica, sync!, apply_all!) = mirrored(root)
    apply_all!()
    frame = lock(() -> Treebars._build_frame(m; full=true), m.lock)
    reorder() = Treebars._apply_groups!(replica, Treebars._GroupState[], frame.group_order)
    reorder()
    @test @allocated(reorder()) < 8_000_000
    @test phase_overview(target) == phase_overview(root)
    empty!(root.children)
    sync!()
    @test isempty(m.groups) && isempty(m.group_ids) && isempty(m.group_host)
    @test isempty(replica.groups) && isempty(replica.group_ids)
    @test isempty(m.host_groups) && isempty(replica.host_groups)
    close(m)
    end
end
