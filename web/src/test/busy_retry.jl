using Test
using Treebars

@testset "BusyRetryPolicy bounds and validation" begin
    @test_throws ArgumentError BusyRetryPolicy()
    @test_throws ArgumentError BusyRetryPolicy(max_retries=-1)
    @test_throws ArgumentError BusyRetryPolicy(max_elapsed=1, initial_delay=0, max_delay=1)
    @test_throws ArgumentError BusyRetryPolicy(max_retries=1, jitter=1.1)
    @test_throws ArgumentError BusyRetryPolicy(max_retries=1, multiplier=0.9)

    policy = BusyRetryPolicy(max_retries=6)
    @test policy.max_retries == 6
    @test policy.initial_delay == 0.5
    @test policy.max_delay == 8.0
end

@testset "busy retry acquires immediately and forwards the value" begin
    root = initialize_progress!(:state; description="root")
    child = Ref{Any}()
    result = with_busy_retry(root,
            () -> begin
                child[] = only(root.children)
                ResourceAcquired(42)
            end;
            policy=BusyRetryPolicy(max_retries=3),
            sleeper=_ -> error("must not sleep")) do value
        value + 1
    end

    @test result == 43
    @test is_finished(child[])
    @test child[].impl.message == ""
    @test isempty(root.children) # successful transient wait nodes disappear
end

@testset "busy retry uses capped lower-range jitter deterministically" begin
    root = initialize_progress!(:state; description="root")
    child = Ref{Any}()
    attempts = Ref(0)
    now = Ref(0.0)
    sleeps = Float64[]
    messages = String[]
    samples = Iterators.Stateful((0.0, 0.5))

    result = with_busy_retry(root,
            () -> begin
                attempts[] += 1
                child[] = only(root.children)
                attempts[] <= 2 ? ResourceBusy("Evaluator capacity busy") : ResourceAcquired(:lease)
            end;
            policy=BusyRetryPolicy(
                initial_delay=0.5, multiplier=2, max_delay=0.75,
                jitter=0.5, max_retries=2),
            clock=() -> now[],
            random=() -> popfirst!(samples),
            sleeper=delay -> begin
                push!(sleeps, delay)
                push!(messages, child[].impl.message)
                now[] += delay
            end) do value
        value
    end

    @test result === :lease
    @test attempts[] == 3 # initial call plus two retries
    @test sleeps == [0.5, 0.5625]
    @test occursin("retry 1/2", messages[1])
    @test occursin("retry 2/2", messages[2])
    @test child[].impl.message == ""
    @test is_finished(child[])
end

@testset "retry count exhaustion is typed and stays visible" begin
    root = initialize_progress!(:state; description="root")
    now = Ref(0.0)
    sleeps = Float64[]
    err = try
        with_busy_retry(root, () -> ResourceBusy("Evaluator capacity busy");
                policy=BusyRetryPolicy(
                    initial_delay=0.5, multiplier=2, max_delay=8,
                    jitter=0, max_retries=2),
                clock=() -> now[], random=() -> 0.0,
                sleeper=delay -> (push!(sleeps, delay); now[] += delay)) do _
            error("unreachable")
        end
        nothing
    catch caught
        caught
    end

    @test err isa BusyRetryExhausted
    @test err.attempts == 3
    @test err.elapsed == 1.5
    @test err.last_message == "Evaluator capacity busy"
    @test sleeps == [0.5, 1.0]
    child = only(root.children)
    @test is_failed(child)
    @test occursin("exhausted after 3 attempts", child.impl.message)
end

@testset "elapsed bound does not start a retry that cannot fit" begin
    root = initialize_progress!(:state; description="root")
    now = Ref(0.0)
    sleeps = Float64[]
    attempts = Ref(0)
    err = try
        with_busy_retry(root,
                () -> (attempts[] += 1; ResourceBusy("queue busy"));
                policy=BusyRetryPolicy(
                    initial_delay=0.75, multiplier=2, max_delay=2,
                    jitter=0, max_elapsed=1.0),
                clock=() -> now[], random=() -> 0.0,
                sleeper=delay -> (push!(sleeps, delay); now[] += delay)) do _
            error("unreachable")
        end
        nothing
    catch caught
        caught
    end

    @test err isa BusyRetryExhausted
    @test err.attempts == 2
    @test attempts[] == 2
    @test sleeps == [0.75]
end

@testset "non-retryable acquisition and body failures propagate unchanged" begin
    acquisition_error = ErrorException("acquire failed")
    root = initialize_progress!(:state; description="root")
    caught = try
        with_busy_retry(root, () -> throw(acquisition_error);
                policy=BusyRetryPolicy(max_retries=2)) do _
            error("unreachable")
        end
        nothing
    catch err
        err
    end
    @test caught === acquisition_error
    failed_wait = only(root.children)
    @test is_failed(failed_wait)
    @test failed_wait.impl.message == ""

    body_error = ErrorException("body failed")
    released = Ref(false)
    root2 = initialize_progress!(:state; description="root")
    caught = try
        with_busy_retry(root2, () -> ResourceAcquired(nothing);
                policy=BusyRetryPolicy(max_retries=2)) do _
            try
                throw(body_error)
            finally
                released[] = true
            end
        end
        nothing
    catch err
        err
    end
    @test caught === body_error
    @test released[]
    @test isempty(root2.children) # acquisition already succeeded
end

@testset "invalid acquisition results fail without retrying" begin
    root = initialize_progress!(:state; description="root")
    attempts = Ref(0)
    @test_throws ArgumentError with_busy_retry(root,
            () -> (attempts[] += 1; :busy);
            policy=BusyRetryPolicy(max_retries=2)) do _
        error("unreachable")
    end
    @test attempts[] == 1
    @test is_failed(only(root.children))
end

@testset "a fresh acquisition resets the backoff" begin
    sleeps = Float64[]
    for _ in 1:2
        root = initialize_progress!(:state; description="root")
        attempts = Ref(0)
        with_busy_retry(root,
                () -> begin
                    attempts[] += 1
                    attempts[] == 1 ? ResourceBusy("busy") : ResourceAcquired(nothing)
                end;
                policy=BusyRetryPolicy(
                    initial_delay=0.5, multiplier=2, max_delay=8,
                    jitter=0, max_retries=1),
                random=() -> error("zero jitter must not sample randomness"),
                sleeper=delay -> push!(sleeps, delay)) do _
            nothing
        end
    end
    @test sleeps == [0.5, 0.5]
end
