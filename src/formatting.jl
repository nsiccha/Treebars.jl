## Duration formatting

using Dates: Millisecond, Second, Minute, Hour, value

"""
    short_duration(dt::Union{Dates.CompoundPeriod, Dates.Period}) -> String

Human-friendly duration string: "4s", "1m 23s", "2h 5m".
"""
_short_period(p::Hour)   = "$(value(p))h"
_short_period(p::Minute) = "$(value(p))m"
_short_period(p::Second) = "$(value(p))s"
_short_period(p::Millisecond) =
    let v = value(p); v >= 100 ? "$(div(v, 100) / 10)s" : "$(v)ms" end
_short_period(p) = string(p)

function short_duration(dt)
    cp = canonicalize(dt)
    parts = cp.periods
    isempty(parts) && return "0s"
    # Map each period to a short label
    labels = map(_short_period, parts)
    # Show at most 2 most-significant parts
    join(labels[1:min(2, length(labels))], " ")
end

## Generic formatting utilities for progress display
# These are general-purpose; domain-specific `short_string` methods
# (e.g. for MatrixFactorization) should be defined in the consuming package.

round2(x::Real) = round(x; sigdigits=2)
round2(x::Integer) = round(x)
round2(x::Union{Tuple,NamedTuple,AbstractArray}) = map(round2, x)
round2(x::Missing) = x
round2(x::String) = x

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

struct Fraction{T}
    value::T
end
short_string(x::Fraction) = short_string(x.value * 100) * "%"
Base.isless(x::Fraction, y::Fraction) = isless(x.value, y.value)
Base.isequal(x::Fraction, y::Fraction) = isequal(x.value, y.value)
