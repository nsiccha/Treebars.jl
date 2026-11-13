## Duration formatting

using Dates: Millisecond, Second, Minute, Hour, value

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

"""
    short_duration(dt::Union{Dates.CompoundPeriod, Dates.Period}) -> String

Format a duration using seconds below a minute and the two most significant
canonical parts for longer durations. Subsecond values below 100 milliseconds
retain millisecond precision; longer subminute values use tenths of a second,
truncated rather than rounded.
"""
function short_duration(dt::Millisecond)
    ms = value(dt)
    ms == 0 && return "0s"
    ms < 60_000 && return _short_subminute(ms)
    _short_duration_parts(dt)
end

short_duration(dt) = _short_duration_parts(dt)
function _short_duration_parts(dt)
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
    short_string(x; sigdigits=2) -> String

Format values for progress messages. Numbers use significant digits and
abbreviations at large magnitudes, with the same rules for integers and
reals. Negative values retain their sign. Below abbreviation thresholds,
integers are unchanged. Non-finite values pass through.

Containers forward `sigdigits` to supported elements. Long vectors show their
first and last elements; pairs and named tuples retain keys. A [`Fraction`](@ref)
formats as a percentage. `sigdigits` must be positive. Extend this function
in a consuming package for domain-specific values.
"""
short_string(x) = string(x)

# `round(x; sigdigits=0)` silently returns 0.0, so a non-positive count would
# render every number as "0.0" instead of failing.
function _check_sigdigits(sigdigits::Integer)
    sigdigits > 0 || throw(ArgumentError("short_string: sigdigits must be positive, got $sigdigits"))
    sigdigits
end

# Round to `sigdigits` significant figures with a trailing ".0" trimmed once it is
# not one of them: the un-suffixed core shared by the Real and Integer methods. It
# must NOT recurse back into `short_string`, or a scaled value ≥ 1e3 would be
# abbreviated a second time (`10^12` → "1.0kG").
function _short_significand(x::Real, sigdigits::Integer)
    rv = string(round(x; sigdigits))
    # Count DIGITS, not the raw length: a leading "-" must not tip the threshold,
    # else "1.0" is kept while "-1.0" becomes "-1" (so 1000 → "1.0k" but
    # -1000 → "-1k").
    ndigits = length(rv) - (startswith(rv, "-") ? 1 : 0) - 1  # minus the "."
    endswith(rv, ".0") && ndigits > sigdigits ? rv[1:end-2] : rv
end

# Largest-first. Full SI range: stopping at "G" made anything ≥ 1e12 scale into a
# mantissa that itself needed a suffix ("1000G") or that `string` rendered in
# scientific notation ("9.2e9G" for typemax(Int64)).
const _SI_SUFFIXES = ((1e18, "E"), (1e15, "P"), (1e12, "T"), (1e9, "G"), (1e6, "M"), (1e3, "k"))

# `float` before `abs` so `abs(typemin(Int))` can't wrap around to a negative.
# The upper bound keeps the mantissa in [1, 1000) — beyond the largest suffix
# (≥ 1e21, reachable only by BigInt) we fall back to the un-suffixed form rather
# than emit "1000E". Thresholds key off the RAW value, so rounding may still carry
# a mantissa up to "1000" (999_999 → "1000k"); that is the documented behavior.
function _si_suffixed(x::Real, sigdigits::Integer)
    ax = abs(float(x))
    for (scale, suffix) in _SI_SUFFIXES
        scale <= ax < 1000scale && return _short_significand(x / scale, sigdigits) * suffix
    end
    nothing
end

function short_string(x::Real; sigdigits::Integer=2)
    _check_sigdigits(sigdigits)
    isfinite(x) || return string(x)
    @something _si_suffixed(x, sigdigits) _short_significand(x, sigdigits)
end
short_string(x::Integer; sigdigits::Integer=2) =
    @something _si_suffixed(x, _check_sigdigits(sigdigits)) string(x)
# Keyword dispatch sees only methods that accept keywords, so passing `sigdigits`
# to every element would silently skip a consumer's plain `short_string(::MyType)`.
# An element gets the keyword only when its own most specific method takes it; at
# the default no element needs it.
function _short_element(v, sigdigits::Integer)
    sigdigits == 2 && return short_string(v)
    method = which(short_string, Tuple{typeof(v)})
    :sigdigits in Base.kwarg_decl(method) ? short_string(v; sigdigits) : short_string(v)
end

function short_string(x::AbstractVector; sigdigits::Integer=2)
    _check_sigdigits(sigdigits)
    s(v) = _short_element(v, sigdigits)
    "[" * if length(x) > 7
        join(map(s, x[1:3]), ", ") * ", ..., " * join(map(s, x[end-2:end]), ", ")
    else
        join(map(s, x), ", ")
    end * "]"
end
short_string(x::Pair; sigdigits::Integer=2) =
    "$(_short_element(first(x), _check_sigdigits(sigdigits))) => $(_short_element(last(x), sigdigits))"
function short_string(x::NamedTuple; sigdigits::Integer=2)
    _check_sigdigits(sigdigits)
    "(;" * join([
        short_string(key) * "=" * _short_element(value, sigdigits)
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
short_string(x::Fraction; sigdigits::Integer=2) = short_string(x.value * 100; sigdigits) * "%"
Base.isless(x::Fraction, y::Fraction) = isless(x.value, y.value)
Base.isequal(x::Fraction, y::Fraction) = isequal(x.value, y.value)
