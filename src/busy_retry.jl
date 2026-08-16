"""
    ResourceBusy(message="Resource busy")

Explicit result from a resource-acquisition callback passed to
[`with_busy_retry`](@ref). Only this result is retryable; thrown exceptions and
other return values are treated as non-retryable failures.
"""
struct ResourceBusy
    message::String
end

ResourceBusy(message::AbstractString="Resource busy") = ResourceBusy(String(message))

"""
    ResourceAcquired(value)

Explicit successful result from a resource-acquisition callback passed to
[`with_busy_retry`](@ref). `value` is forwarded to the consumer body.
"""
struct ResourceAcquired{T}
    value::T
end

"""
    BusyRetryPolicy(; initial_delay=0.5, multiplier=2, max_delay=8,
        jitter=0.5, max_retries=nothing, max_elapsed=nothing)

Policy for [`with_busy_retry`](@ref). At least one bound must be supplied:

- `max_retries` counts retries *after* the initial acquisition attempt. Thus
  `max_retries=6` permits at most seven acquisition calls.
- `max_elapsed` is a wall-clock budget in seconds. A retry whose delay would
  exceed the remaining budget is not started.

The nominal delay grows by `multiplier` up to `max_delay`. `jitter` selects a
uniform lower range: the actual delay is between `(1-jitter) * nominal_delay`
and `nominal_delay`. Set `jitter=0` for deterministic delays.
"""
struct BusyRetryPolicy
    initial_delay::Float64
    multiplier::Float64
    max_delay::Float64
    jitter::Float64
    max_retries::Union{Nothing,Int}
    max_elapsed::Union{Nothing,Float64}

    function BusyRetryPolicy(
        initial_delay::Float64,
        multiplier::Float64,
        max_delay::Float64,
        jitter::Float64,
        max_retries::Union{Nothing,Int},
        max_elapsed::Union{Nothing,Float64},
    )
        isfinite(initial_delay) && initial_delay >= 0 ||
            throw(ArgumentError("initial_delay must be finite and non-negative"))
        isfinite(multiplier) && multiplier >= 1 ||
            throw(ArgumentError("multiplier must be finite and at least 1"))
        isfinite(max_delay) && max_delay >= initial_delay ||
            throw(ArgumentError("max_delay must be finite and at least initial_delay"))
        isfinite(jitter) && 0 <= jitter <= 1 ||
            throw(ArgumentError("jitter must be finite and between 0 and 1"))
        isnothing(max_retries) || max_retries >= 0 ||
            throw(ArgumentError("max_retries must be non-negative"))
        isnothing(max_elapsed) || (isfinite(max_elapsed) && max_elapsed >= 0) ||
            throw(ArgumentError("max_elapsed must be finite and non-negative"))
        isnothing(max_retries) && isnothing(max_elapsed) &&
            throw(ArgumentError("set max_retries, max_elapsed, or both"))
        isnothing(max_retries) && initial_delay == 0 &&
            throw(ArgumentError("an elapsed-only policy requires a positive initial_delay"))
        new(initial_delay, multiplier, max_delay, jitter, max_retries, max_elapsed)
    end
end

function BusyRetryPolicy(;
    initial_delay::Real=0.5,
    multiplier::Real=2,
    max_delay::Real=8,
    jitter::Real=0.5,
    max_retries::Union{Nothing,Integer}=nothing,
    max_elapsed::Union{Nothing,Real}=nothing,
)
    BusyRetryPolicy(
        Float64(initial_delay),
        Float64(multiplier),
        Float64(max_delay),
        Float64(jitter),
        isnothing(max_retries) ? nothing : Int(max_retries),
        isnothing(max_elapsed) ? nothing : Float64(max_elapsed),
    )
end

"""
    BusyRetryExhausted

Typed exception thrown by [`with_busy_retry`](@ref) when a busy resource
reaches its retry-count or elapsed-time bound. `attempts` counts all acquisition
calls, including the initial call, and `last_message` is the last
[`ResourceBusy`](@ref) message.
"""
struct BusyRetryExhausted <: Exception
    attempts::Int
    elapsed::Float64
    last_message::String
end

function Base.showerror(io::IO, err::BusyRetryExhausted)
    print(io, "resource remained busy after ", err.attempts,
        err.attempts == 1 ? " attempt" : " attempts",
        " (", round(err.elapsed; digits=3), "s): ", err.last_message)
end

_retry_clock_seconds(clock) = begin
    t = Float64(clock())
    isfinite(t) || throw(ArgumentError("clock must return a finite number of seconds"))
    t
end

_retry_monotonic_seconds() = Base.time_ns() / 1.0e9

function _retry_random01(random)
    x = Float64(random())
    isfinite(x) && 0 <= x < 1 ||
        throw(ArgumentError("random must return a finite value in [0, 1)"))
    x
end

_retry_elapsed(clock, started) = max(0.0, _retry_clock_seconds(clock) - started)

function _retry_delay_text(seconds)
    string(round(seconds; sigdigits=3), "s")
end

function _retry_exhausted!(progress, busy::ResourceBusy, attempts, elapsed)
    err = BusyRetryExhausted(attempts, elapsed, busy.message)
    update_progress!(progress,
        "$(busy.message) — exhausted after $attempts $(attempts == 1 ? "attempt" : "attempts")")
    throw(err)
end

"""
    with_busy_retry(parent, acquire; policy, description="Waiting for resource",
        transient=true, sleeper=sleep, clock=<monotonic clock>, random=rand) do value
        ...
    end

Acquire an explicitly busy resource with bounded exponential backoff and
jitter. `acquire()` must return either [`ResourceBusy`](@ref) or
[`ResourceAcquired`](@ref). Only `ResourceBusy` is retried; acquisition
exceptions and invalid results fail immediately.

Treebars creates one child progress node and reuses it for every busy attempt.
Its message reports the busy reason, retry number, and delay. On acquisition,
the message is cleared and the child is finalized before the consumer body is
called, resetting the backoff lifecycle immediately. A transient child (the
default) therefore disappears on success but remains visible with an exhaustion
summary when it fails.

The consumer body owns use and release of the acquired value. Its exceptions
propagate unchanged and do not trigger acquisition retries. `sleeper`, `clock`
(seconds), and `random` (a sample in `[0, 1)`) are injectable deterministic
test seams.

This helper is for explicit resource-busy acquisition only. It does not alter
Treebars' fixed HTMX, WebSocket, or terminal progress-polling cadence.
"""
function with_busy_retry(
    f::F,
    parent,
    acquire::A;
    policy::BusyRetryPolicy,
    description::AbstractString="Waiting for resource",
    transient::Bool=true,
    sleeper=Base.sleep,
    clock=_retry_monotonic_seconds,
    random=Base.rand,
) where {F,A}
    progress = initialize_progress!(parent; description, transient)
    started = _retry_clock_seconds(clock)
    nominal_delay = policy.initial_delay
    attempts = 0
    acquired = nothing

    try
        while true
            attempts += 1
            result = acquire()
            if result isa ResourceAcquired
                acquired = result.value
                break
            elseif !(result isa ResourceBusy)
                throw(ArgumentError(
                    "acquire must return ResourceBusy or ResourceAcquired, got $(typeof(result))"))
            end

            elapsed = _retry_elapsed(clock, started)
            retries_used = attempts - 1
            (!isnothing(policy.max_retries) && retries_used >= policy.max_retries) &&
                _retry_exhausted!(progress, result, attempts, elapsed)
            (!isnothing(policy.max_elapsed) && elapsed >= policy.max_elapsed) &&
                _retry_exhausted!(progress, result, attempts, elapsed)

            capped_delay = min(nominal_delay, policy.max_delay)
            delay = policy.jitter == 0 ? capped_delay :
                capped_delay * (1 - policy.jitter * _retry_random01(random))
            (!isnothing(policy.max_elapsed) && elapsed + delay > policy.max_elapsed) &&
                _retry_exhausted!(progress, result, attempts, elapsed)

            retry_number = retries_used + 1
            retry_limit = isnothing(policy.max_retries) ? "" : "/$(policy.max_retries)"
            update_progress!(progress,
                "$(result.message) — retry $retry_number$retry_limit in $(_retry_delay_text(delay))")
            sleeper(delay)
            nominal_delay = min(policy.max_delay, nominal_delay * policy.multiplier)
        end
    catch err
        err isa BusyRetryExhausted || update_progress!(progress, "")
        fail_progress!(progress, err)
        rethrow()
    end

    update_progress!(progress, "")
    finalize_progress!(progress)
    f(acquired)
end
