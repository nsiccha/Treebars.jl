# Core reference

## Instrumentation

```@docs
@progress
@phases
@with_progress
with_progress
with_prepared_progress
with_prepared_phases
progress_map
```

## Nodes and lifecycle

```@docs
ProgressNode
StateProgress
initialize_progress!
update_progress!
prepare_progress!
start_progress!
finalize_progress!
fail_progress!
skip_progress!
reuse_progress!
add_child!
```

## State queries

```@docs
is_pending
is_running
is_finished
is_failed
is_skipped
is_reused
is_displayed
duration
eta
```

## Interrupts

```@docs
request_interrupt!
interrupt_requested
throw_if_interrupted
ProgressInterrupted
```

## Resource acquisition

```@docs
with_busy_retry
BusyRetryPolicy
ResourceBusy
ResourceAcquired
BusyRetryExhausted
```

## Formatting

```@docs
short_duration
short_string
round2
Fraction
ByteSize
```

```@example formatting
using Treebars, Dates
for value in (Millisecond(47), Second(13), Minute(2) + Second(5))
    println(value, " → ", short_duration(value))
end
for value in (1_500_000, -72_000.0, 12.0)
    println(value, " → ", short_string(value))
end
```
