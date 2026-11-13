# Source-shape recognition, argument parsing, labels and expansion diagnostics.

# Macro-head recognition, bare OR module-qualified. The walker only ever sees
# SOURCE, so `Treebars.@progress "x"` is a different head from `@progress "x"` —
# matching only the bare Symbol made every qualified spelling invisible to it and
# left it to expand as a STANDALONE call: a 1-arg marker died with an arity error
# that described a different mistake, while `Treebars.@progress "l" body` and
# `Treebars.@phases body` silently built against `BACKEND[]` (a process-global
# root, `nothing` in a web app) instead of the enclosing node — no node, no error.
# The qualified spelling is not exotic: a consumer whose imports are
# `using DynamicObjects` has no bare `@progress` in scope (DO's `@progress` is
# only its LHS parse-marker), so it is the first thing they reach for.
#
# The path is anchored on a trailing `Treebars` component rather than accepting
# any qualifier, so `Treebars.@progress` and `DynamicObjects.Treebars.@progress`
# match while another package's same-named macro (ProgressLogging.jl exports a
# `@progress` too) nested inside our block is left untouched. Same shape as the
# `Threads.@threads` head test below.
#
# THIRD form: `GlobalRef(Treebars, Symbol("@progress"))`. Source-level
# `Treebars.@progress` parses to the dotted Expr, but a macro that EMITS the call
# writes a GlobalRef instead — which is neither of the above. DynamicObjects emits
# exactly this at three sites (`DynamicObjects.jl:5708/:5725/:5760` @ `9f9c8a5` —
# the `@progress`-marked, `@PROGRESS`-marked and UNMARKED property-body wraps),
# and since it wraps EVERY unmarked property body the GlobalRef is now the
# ecosystem's dominant emitted head by a wide margin. A GlobalRef needs no
# `Treebars`-tail guard: it carries the resolved module itself, so it cannot be
# confused with another package's `@progress`. `_is_doc_macrocall` below already
# matches `GlobalRef(Core, Symbol("@doc"))` alongside the bare symbol — same idea.
# (Reported by DynamicObjects:sbpmx-reflect on the snag decision; the emitted AST
# is not visible from this side.)
_qualifier_tail(m::Symbol) = m
_qualifier_tail(m::Expr) =
    Meta.isexpr(m, :.) && m.args[2] isa QuoteNode ? m.args[2].value : nothing
_qualifier_tail(_) = nothing

_is_macro_head(name, mac::Symbol) =
    name === mac || (
        Meta.isexpr(name, :.) && name.args[2] isa QuoteNode &&
        name.args[2].value === mac && _qualifier_tail(name.args[1]) === :Treebars
    )
_is_macro_head(name::GlobalRef, mac::Symbol) =
    name.mod === (@__MODULE__) && name.name === mac

_is_progress_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) >= 2 &&
    _is_macro_head(x.args[1], Symbol("@progress"))

# @phases macrocall recognition (mirrors the @progress pair). The walker
# (`progress_expr`) detects these and eager-expands them in place via the shared
# `_phases_build`, so an `@phases` nested inside `@progress` binds the active node.
_is_phases_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) >= 2 &&
    _is_macro_head(x.args[1], Symbol("@phases"))

# User-supplied args of an @phases macrocall (strip macro name + LineNumberNode)
_phases_user_args(x) = x.args[3:end]

# True for both plain string literals (`"step"`) and interpolated string
# literals (`"step $i"`, parsed as `Expr(:string, …)`). The downstream
# emitter handles `description=$label` as a generic Expr, so the parser-level
# dispatch arms only need to recognise that the label slot was a string at
# the source level.
_is_string_literal(x) = x isa AbstractString || Meta.isexpr(x, :string)

# A conditional that chooses between string literals — `c ? "a" : "b"`, or an
# `if` / `elseif` / `else` chain — is a label too: its value is a string on
# every path, so it is evaluated once at enumeration exactly like
# `"$(c ? "a" : "b")"`. Each branch must be the string itself (a ternary arm, or
# an `if` branch holding nothing but it) or another such conditional, and the
# chain needs its `else`: without it one path yields `nothing`. Only the macro
# form `@progress c ? "a" : "b"` is a marker — a bare conditional statement is
# ordinary code (snag `phase-marker-wit-1fcdd284`).
_is_string_conditional(x) =
    Meta.isexpr(x, (:if, :elseif)) && length(x.args) == 3 &&
    all(_is_label_branch, @view x.args[2:3])
_is_label_branch(x) = _is_label_value(_branch_value(x))
_is_label_value(x) = _is_string_literal(x) || _is_string_conditional(x)
# The value of an `if` branch: the block's only statement, else not a label.
_branch_value(x) = x
function _branch_value(x::Expr)
    x.head === :block || return x
    stmts = filter(a -> !(a isa LineNumberNode), x.args)
    length(stmts) == 1 ? only(stmts) : nothing
end

# Index of a block's TAIL statement (last non-LineNumberNode arg), if any. A
# bare string literal there is the block's VALUE, not a phase marker: the
# parser folds a mid-block `"s"; stmt` into `Core.@doc` (so a user-written
# bare marker never reaches the walker there), but the trailing string has no
# following statement and arrives intact — where the bare-string arm below
# used to consume it, opening an empty phase and returning its node instead
# of the string (snag `trailing-string-f02f8729`). The `@progress "label"`
# macro form keeps its marker meaning in tail position (as a statement it has
# no other reading), and `@phases`-injected markers are unaffected (each is
# immediately followed by its statement, so none is ever the tail).
_tail_index(block::Expr) = findlast(a -> !(a isa LineNumberNode), block.args)

# Phase-marker recognition. The structural shape is a `:macrocall` to
# `@progress` with exactly one user argument; the *kind* of that argument
# (string literal — plain or interpolated — vs anything else) determines
# whether it acts as a marker. A bare string literal ALSO acts as a marker
# (the `@phases` injection path, plus for-bodies, where the parser leaves
# bare strings intact) — EXCEPT in tail position (`is_tail`, from
# `_tail_index`), where it is the block's value. The macro form also takes a
# conditional between string literals (`_is_string_conditional`). Returns
# either `nothing` or the raw label expression (which downstream code splices
# into `description=$label`).
function _phase_marker_label(x, is_tail::Bool=false)
    _is_string_literal(x) && return is_tail ? nothing : x
    if x isa Expr && _is_progress_macrocall(x) && length(x.args) == 3
        label = x.args[3]
        return _is_string_conditional(label) ? label : _phase_marker_label(label, false)
    end
    return nothing
end

# User-supplied args of a @progress macrocall (strip macro name + LineNumberNode)
_progress_user_args(x) = x.args[3:end]

# @progress_scope macrocall recognition (same head shapes as the pair above).
_is_scope_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) >= 2 &&
    _is_macro_head(x.args[1], Symbol("@progress_scope"))

# True iff `x` is a `Threads.@threads` (qualified or bare) applied to a for loop.
function _is_threads_for(x)
    Meta.isexpr(x, :macrocall) || return false
    name = x.args[1]
    is_threads = (
        (Meta.isexpr(name, :.) && name.args[1] === :Threads &&
            name.args[2] isa QuoteNode && name.args[2].value === Symbol("@threads")) ||
        name === Symbol("@threads")
    )
    is_threads && Meta.isexpr(x.args[end], :for)
end

# Single-line source text of an AST fragment: line numbers stripped, all
# whitespace/newlines collapsed. Shared by `_short_label` (@phases phase
# labels) and `_auto_for_label` (bare-for counter labels).
function _flat_source(x)
    clean = x isa Expr ? Base.remove_linenums!(deepcopy(x)) : x
    strip(replace(string(clean), r"\s+" => " "))
end

# Default label for an auto-instrumented bare `for` / `Threads.@threads for`:
# the iteration variables plus the collection source IN FULL when it fits in
# `_PHASE_LABEL_MAXLEN`, else just the variables — the collection is omitted
# WHOLE, never clipped (snag `phase-block-auto-211abcde`: the old hardcoded
# `for $lhs in ...` ellipsised even a 4-letter collection).
function _auto_for_label(lhs, rhs)
    vars = _flat_source(lhs)
    full = "for $vars in $(_flat_source(rhs))"
    length(full) <= _PHASE_LABEL_MAXLEN ? full : "for $vars"
end

# Parse top-level @progress args into (backend, label, body). Length-cased
# branches dispatch on the position-relevant arg's type instead of running
# `_is_string`-style guards inside the body.
function _parse_toplevel_args(args)
    length(args) == 1 && return _toplevel_one_arg(args[1])
    length(args) == 2 && return _split_two_args(args[1], args[2])
    length(args) == 3 && return _toplevel_three_args(args[1], args[2], args[3])
    error("@progress: too many arguments")
end

# Length-1 form: a body expression. A bare string literal (plain or
# interpolated) here is a user error — but which one is ambiguous, so name both.
# Reaching expansion at all means no enclosing `@progress` walker claimed this as
# a phase marker, and the likeliest reason is a head the walker cannot see: it
# matches `@progress` and `Treebars.@progress` (see `_is_macro_head`), so a
# marker written through any other alias falls through to here. The old message
# named only the arity, which points at adding a body — exactly the wrong fix for
# a marker (snag `used-an-inline-p-baab62f1`).
_toplevel_one_arg(a) =
    _is_label_value(a) ? error("""
        @progress $(a isa AbstractString ? repr(a) : _source(a)) reached expansion as a STANDALONE call. Either:
          • it was meant as a PHASE MARKER inside a `@progress [begin … end]` block — then the \
        enclosing block did not recognise it, because a marker must be spelled `@progress "label"` \
        or `Treebars.@progress "label"`. Import the macro with `using Treebars: @progress` (from a \
        `using DynamicObjects` consumer: `using DynamicObjects.Treebars: @progress`); or
          • you meant the wrapping form, which needs a body: `@progress "label" body`.
        """) :
        (nothing, nothing, a)

# Two-arg @progress form: a (plain or interpolated) string is the label;
# anything else is the backend.
_split_two_args(a, b) = _is_string_literal(a) ? (nothing, a, b) : (a, nothing, b)

# Length-3 form: backend, label, body — label must be a (plain or
# interpolated) string literal.
_toplevel_three_args(backend, label, body) =
    _is_string_literal(label) ? (backend, label, body) :
    error("@progress: three-arg form expects @progress backend \"label\" body")

# Source text for an error message. Julia prints `c ? a : b` as a multi-line
# `if … else … end`, so a conditional whose arms are not blocks (the ternary's
# shape) is printed back as a ternary.
_source(a) = string(a)
_source(a::Expr) = _ternary_source(Base.remove_linenums!(deepcopy(a)))
_ternary_source(a) = string(a)
_ternary_source(a::AbstractString) = repr(a)
_ternary_source(a::Expr) =
    a.head === :if && length(a.args) == 3 && !any(x -> Meta.isexpr(x, :block), @view a.args[2:3]) ?
        join(_ternary_source.(a.args), " ? ", " : ") : string(a)

# True iff `@progress a` lowers exactly as `a` would without it. With no label,
# `_build_body` only walks a body that is not one of its shapes, and that walk
# differs from the enclosing one only in counting loops (an explicit `@progress`
# counts them even in a `@progress_scope` body) — so an argument with no `for`
# and no nested progress form in its source gains nothing from the wrapper.
# Interpolated strings stay out (a stray interpolated marker is lowered as
# before), and so do assignments, definitions and macro calls: `@progress name
# = …` is DynamicObjects' property marker, and a macro's arguments are its own.
_wraps_nothing(a) = true    # a name, a literal, a QuoteNode
_wraps_nothing(a::Expr) =
    !(_is_string_literal(a) || _is_body_shape(a) ||
      a.head in (:(=), :function, :macrocall) || _contains_walked(a))

_contains_walked(x) = false
_contains_walked(x::Expr) =
    x.head === :for || _is_progress_macrocall(x) || _is_phases_macrocall(x) ||
    _is_scope_macrocall(x) || any(_contains_walked, x.args)

function _wraps_nothing_error(a)
    src = _source(a)
    error("""
        @progress $src does nothing. Inside a `@progress` block a one-argument `@progress` is \
        either a phase marker, whose label must be a string (`@progress "label"`, \
        `@progress "Fit \$(k)"`, or a conditional between strings such as \
        `@progress c ? "a" : "b"`), or a body it instruments (a loop, `map`, a comprehension, \
        a `begin … end` block). `$src` is neither, so it would run as plain code and no node \
        would appear. Write
          • `@progress "\$($src)"` for a phase labelled with its value;
          • `@progress "label" $src` to run it in a node of its own; or
          • `$src` without `@progress` to run it as plain code.
        """)
end

# The body shapes `_build_body` lowers into a node of their own even without a
# label. LOCKSTEP: the arms of `_build_body` below.
_is_body_shape(body) =
    _is_threads_for(body) || _is_map_call(body) ||
    Meta.isexpr(body, (:for, :comprehension, :generator, :block))

# Recognise a `map(...)` call — plain `map(f, itrs...)` or do-block form
# `map(itrs...) do args... end` — for the opt-in @progress map-sugar.
_is_map_name(n) = n === :map ||
    (Meta.isexpr(n, :.) && n.args[2] isa QuoteNode && n.args[2].value === :map)
function _is_map_call(x)
    Meta.isexpr(x, :do) && return Meta.isexpr(x.args[1], :call) && _is_map_name(x.args[1].args[1])
    Meta.isexpr(x, :call) && return _is_map_name(x.args[1])
    return false
end

# The docstring trap. Inside a `begin … end` (also `quote` / module / file
# top-level), Julia's PARSER rewrites a string literal immediately followed by
# another statement into `Core.@doc "label" stmt`. So a bare `"label"` written
# as a phase marker is swallowed before `@progress` ever sees it: no node, no
# error, no warning. The code is parse-clean and precompile-clean, which makes
# this the one `@progress` failure mode no offline check can catch — it has
# already cost a real DO property four silently-missing phases.
#
# We do NOT recover the intent by treating it as a marker: a genuine docstring
# is legal here, and silently redefining what it means would trade a visible
# bug for an invisible one. Warning at macro-expansion is enough to kill the
# class — the author sees it the first time the block is compiled, with the
# exact replacement spelled out.
_is_doc_macrocall(x) =
    Meta.isexpr(x, :macrocall) && length(x.args) == 4 &&
    (x.args[1] === GlobalRef(Core, Symbol("@doc")) || x.args[1] === Symbol("@doc")) &&
    _is_string_literal(x.args[3])

function _warn_swallowed_markers(block::Expr)
    line = nothing
    for a in block.args
        a isa LineNumberNode && (line = a; continue)
        _is_doc_macrocall(a) || continue
        label = a.args[3]
        @warn """
            @progress: a bare string literal inside a `begin … end` block was parsed as a \
            DOCSTRING (`Core.@doc`), not a phase marker — it will create no node and render \
            nothing. Write the macro form instead:

                @progress $(label isa AbstractString ? repr(label) : string(label))

            (If you really meant a docstring, this warning is expected — move it out of the \
            `@progress` block to silence it.)
            """ location = line
    end
end

# The two @progress_scope surfaces share these: the macro itself, and the
# walker's in-place lowering of one nested in a @progress block (which first
# walks the node argument, so an `__progress__` there is the enclosing node).
function _scope_args(args)
    length(args) == 2 || error("@progress_scope: expected `@progress_scope node body`")
    node, body = args
    _is_string_literal(node) && error(
        "@progress_scope: the first argument is the node the body reports into, not a label — " *
        "write `@progress_scope node begin @progress $(repr(node)); … end`")
    node isa QuoteNode && error(
        "@progress_scope: expects a ProgressNode (or `nothing`), not the backend `:$(node.value)` — " *
        "create the root with `initialize_progress!(:$(node.value); …)` and pass it")
    node, body
end
