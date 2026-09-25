using TestItemRunner

const _TREEBARS_TEST_PREFIX = "--htmxo-test="
const _TREEBARS_NAME_PREFIX = "--name="
const _TREEBARS_TAG_PREFIX = "--tag="
const _TREEBARS_FILE_PREFIX = "--file="
const _TREEBARS_REQUESTED_TESTS = Set(
    arg[length(_TREEBARS_TEST_PREFIX) + 1:end]
    for arg in ARGS if startswith(arg, _TREEBARS_TEST_PREFIX)
)
const _TREEBARS_REQUESTED_NAMES = Set(
    arg[length(_TREEBARS_NAME_PREFIX) + 1:end]
    for arg in ARGS if startswith(arg, _TREEBARS_NAME_PREFIX)
)
const _TREEBARS_REQUESTED_TAGS = Set(Symbol(
    arg[length(_TREEBARS_TAG_PREFIX) + 1:end]
) for arg in ARGS if startswith(arg, _TREEBARS_TAG_PREFIX))
const _TREEBARS_REQUESTED_FILES = Set(replace(
    arg[length(_TREEBARS_FILE_PREFIX) + 1:end], '\\' => '/'
) for arg in ARGS if startswith(arg, _TREEBARS_FILE_PREFIX))
const _TREEBARS_LIST_ONLY = "--list" in ARGS
const _TREEBARS_PROJECT_ROOT = normpath(joinpath(@__DIR__, ".."))
const _TREEBARS_AVAILABLE_TESTS = Set{String}()
const _TREEBARS_AVAILABLE_NAMES = Set{String}()
const _TREEBARS_AVAILABLE_TAGS = Set{Symbol}()
const _TREEBARS_AVAILABLE_FILES = Set{String}()
const _TREEBARS_SELECTED_TESTS = Set{String}()

function _treebars_test_identity(item)
    file = replace(relpath(item.filename, _TREEBARS_PROJECT_ROOT), '\\' => '/')
    file, file * "::" * item.name
end

function _treebars_test_filter(item)
    file, key = _treebars_test_identity(item)
    push!(_TREEBARS_AVAILABLE_TESTS, key)
    push!(_TREEBARS_AVAILABLE_NAMES, item.name)
    push!(_TREEBARS_AVAILABLE_FILES, file)
    union!(_TREEBARS_AVAILABLE_TAGS, item.tags)

    selected = (isempty(_TREEBARS_REQUESTED_TESTS) || key in _TREEBARS_REQUESTED_TESTS) &&
        (isempty(_TREEBARS_REQUESTED_NAMES) || item.name in _TREEBARS_REQUESTED_NAMES) &&
        (isempty(_TREEBARS_REQUESTED_TAGS) || !isdisjoint(_TREEBARS_REQUESTED_TAGS, item.tags)) &&
        (isempty(_TREEBARS_REQUESTED_FILES) || file in _TREEBARS_REQUESTED_FILES)
    selected && push!(_TREEBARS_SELECTED_TESTS, key)
    !_TREEBARS_LIST_ONLY && selected
end

@run_package_tests filter=_treebars_test_filter verbose=true

function _treebars_require_known(label, requested, available)
    missing = setdiff(requested, available)
    isempty(missing) || error("Unknown $label selection(s): " * join(sort!(string.(collect(missing))), ", "))
end

_treebars_require_known("test", _TREEBARS_REQUESTED_TESTS, _TREEBARS_AVAILABLE_TESTS)
_treebars_require_known("name", _TREEBARS_REQUESTED_NAMES, _TREEBARS_AVAILABLE_NAMES)
_treebars_require_known("tag", _TREEBARS_REQUESTED_TAGS, _TREEBARS_AVAILABLE_TAGS)
_treebars_require_known("file", _TREEBARS_REQUESTED_FILES, _TREEBARS_AVAILABLE_FILES)

if _TREEBARS_LIST_ONLY
    for key in sort!(collect(_TREEBARS_SELECTED_TESTS))
        println(key)
    end
elseif (!isempty(_TREEBARS_REQUESTED_TESTS) || !isempty(_TREEBARS_REQUESTED_NAMES) ||
        !isempty(_TREEBARS_REQUESTED_TAGS) || !isempty(_TREEBARS_REQUESTED_FILES)) &&
        isempty(_TREEBARS_SELECTED_TESTS)
    error("The requested selection matched zero tests.")
end
