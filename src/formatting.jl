## Duration formatting

using Dates: Millisecond, Second, Minute, Hour, value

"""
    short_duration(dt::Union{Dates.CompoundPeriod, Dates.Period}) -> String

Human-friendly duration string. Sub-minute durations render as a single
one-decimal-second value (`"0.6s"`, `"2.7s"`, `"13.9s"`, `"13s"`); sub-100ms
keep millisecond precision (`"47ms"`); minute-and-up join the two most
significant canonical parts (`"1m 30s"`, `"1h 1m"`).
"""
_short_period(p::Hour)   = "$(value(p))h"
_short_period(p::Minute) = "$(value(p))m"
_short_period(p::Second) = "$(value(p))s"
_short_period(p::Millisecond) =
    let v = value(p); v >= 100 ? "$(div(v, 100) / 10)s" : "$(v)ms" end
_short_period(p) = string(p)

# Sub-minute label: <100ms keeps ms precision, otherwise a single decimal-second
# value at 0.1s resolution, TRUNCATING (floor) not rounding — matches the JS
# ticker's floor and the stopwatch convention (13.9s until 14.0s elapses).
function _short_subminute(ms)
    ms < 100 && return "$(ms)ms"
    s = floor(ms / 100) / 10
    str = string(s)
    endswith(str, ".0") ? "$(str[1:end-2])s" : "$(str)s"
end

function short_duration(dt)
    cp = canonicalize(dt)
    parts = cp.periods
    isempty(parts) && return "0s"
    # Total milliseconds — wall-clock durations are Millisecond-based, so every
    # canonical part converts cleanly.
    ms = sum(p -> value(convert(Millisecond, p)), parts)
    ms < 60_000 && return _short_subminute(ms)
    # ≥ 1 min: the two most-significant canonical parts.
    labels = map(_short_period, parts)
    join(labels[1:min(2, length(labels))], " ")
end

## Generic formatting utilities for progress display
# These are general-purpose; domain-specific `short_string` methods
# (e.g. for MatrixFactorization) should be defined in the consuming package.

"""
    round2(x)

Round `x` to two significant digits. Integers are returned unchanged.
Tuples, named tuples, and arrays are mapped element-wise. `missing` and
`String` values pass through.

Used as a building block for [`short_string`](@ref); useful directly when
preparing label values for [`update_progress!`](@ref).
"""
round2(x::Real) = round(x; sigdigits=2)
round2(x::Integer) = round(x)
round2(x::Union{Tuple,NamedTuple,AbstractArray}) = map(round2, x)
round2(x::Missing) = x
round2(x::String) = x

"""
    short_string(x) -> String

Compact string form for progress display:

- Reals are rounded via [`round2`](@ref), trailing `".0"` trimmed.
- Integers are abbreviated with `k`/`M`/`G` suffixes (`1_500_000 → "1.5M"`).
- Vectors of length > 7 are summarized as `[first 3, ..., last 3]`.
- Pairs render as `"k => v"`; named tuples as `"(;k=v, …)"`.
- A wrapped [`Fraction`](@ref) renders as a percentage.

Extend with package-specific methods in consuming packages.
"""
short_string(x) = string(x)
function short_string(x::Real)
    rv = string(round2(x))
    endswith(rv, ".0") && length(rv) > 3 ? rv[1:end-2] : rv
end
function short_string(x::Integer)
    if x >= 1e9
        short_string(x / 1e9) * "G"
    elseif x >= 1e6
        short_string(x / 1e6) * "M"
    elseif x >= 1e3
        short_string(x / 1e3) * "k"
    else
        string(x)
    end
end
function short_string(x::AbstractVector)
    "[" * if length(x) > 7
        join(map(short_string, x[1:3]), ", ") * ", ..., " * join(map(short_string, x[end-2:end]), ", ")
    else
        join(map(short_string, x), ", ")
    end * "]"
end
short_string(x::Pair) = "$(short_string(first(x))) => $(short_string(last(x)))"
function short_string(x::NamedTuple)
    "(;" * join([
        short_string(key) * "=" * short_string(value)
        for (key, value) in pairs(x)
    ], ", ") * ")"
end

"""
    Fraction(value)

Marker wrapper that makes [`short_string`](@ref) render a number as a
percentage (`Fraction(0.95) |> short_string == "95%"`). Useful for things
like acceptance rates in progress labels. Comparison and equality forward to
the underlying `value`.
"""
struct Fraction{T}
    value::T
end
short_string(x::Fraction) = short_string(x.value * 100) * "%"
Base.isless(x::Fraction, y::Fraction) = isless(x.value, y.value)
Base.isequal(x::Fraction, y::Fraction) = isequal(x.value, y.value)
