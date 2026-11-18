#!/usr/bin/env bash
# Treebars gordito one-off service launcher: the demo app in the foreground on
# loopback port 8098. The KB starts it (`POST /remote_service_start`, Restart,
# Switch to latest; skill expose-publicly §2b-0) and serves it at /p/Treebars/.
# It runs under non-interactive sshd, so PATH is set here, not inherited from
# an agent shell. An optional first argument overrides the port for a trial
# boot on a scratch port; the KB passes none.
set -euo pipefail
export PATH="$HOME/.local/bin:$HOME/.julia/juliaup/bin:/usr/local/bin:/usr/bin:/bin"
# The KB proxy and the service helper's readiness check reach it on loopback.
export TREEBARS_WEB_HOST=127.0.0.1
port="${1:-8098}"
cd "$(dirname "$0")/../.."
# The KB resolves this environment on every start, restart and switch.
# kb-resolve: web/app
cd web/app
# No startup file, so no Revise: the service loads landed code in a fresh
# process. main.jl serves asynchronously; wait() keeps the process in the
# foreground.
exec julia --startup-file=no -t 4,1 --project=. -e 'include("main.jl"); wait()' -- "$port"
