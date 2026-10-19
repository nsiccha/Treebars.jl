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
    short_string(x; sigdigits=2) -> String

Compact string form for progress display:

- Reals and Integers alike are abbreviated with `k`/`M`/`G`/`T`/`P`/`E` suffixes
  once `abs(x)` reaches the corresponding threshold (`1_500_000 → "1.5M"`,
  `72000.0 → "72k"`, `-72000.0 → "-72k"`, `1e12 → "1.0T"`). The same numeric
  value renders identically whatever its type, and `-x` always renders as `x`
  with a leading `"-"`.
- Below `1e3` a Real is rounded to `sigdigits` significant digits (the default 2
  is [`round2`](@ref)); an Integer renders as-is. A trailing `".0"` is trimmed
  once it is not one of those digits (`12.0 → "12"` but `1.0 → "1.0"`, and
  `12.0 → "12.0"` at `sigdigits=3`). Non-finite Reals pass through.
- `sigdigits` sets the precision of a suffixed mantissa the same way
  (`short_string(123_456.0; sigdigits=4) == "123.5k"`, Integers included). It
  must be positive. Numbers, vectors, pairs, named tuples and a wrapped
  [`Fraction`](@ref) take it; containers pass it on to each element whose own
  method takes it and render any other element with its plain method.
- Thresholds key off the *raw* value, so rounding may carry a mantissa up to
  `"1000"` (`999.0 → "1000"`, `999_999 → "1000k"`). Magnitudes past the largest
  suffix (`≥ 1e21`, BigInt only) render un-suffixed.
- Vectors of length > 7 are summarized as `[first 3, ..., last 3]`.
- Pairs render as `"k => v"`; named tuples as `"(;k=v, …)"`.
- A wrapped [`Fraction`](@ref) renders as a percentage.

Extend with package-specific methods in consuming packages; accept a
`sigdigits` keyword for it to reach your method.
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
