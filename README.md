# Treebars.jl

[![Dev Docs](https://img.shields.io/badge/docs-dev-blue.svg)](https://nsiccha.github.io/Treebars.jl/dev/)

Tree-structured nested progress bars with a backend-agnostic interface.

## Features

- **`@progress` macro**: annotate loops and blocks with progress tracking
- **`ProgressNode` tree structure**: nested progress bars organized hierarchically
- **Thread-safe `StateProgress`**: safe concurrent updates from multiple threads
- **Multiple backends**: Term.jl for terminal output, web-based display via package extensions

## Installation

```julia
using Pkg
Pkg.add(url="https://github.com/nsiccha/Treebars.jl")
```

## Related packages

- [WarmupHMC.jl](https://github.com/nsiccha/WarmupHMC.jl) -- uses Treebars.jl for sampling progress display
- [ReactiveHMC.jl](https://github.com/nsiccha/ReactiveHMC.jl) -- HMC sampler with Treebars.jl integration
