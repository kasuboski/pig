#!/usr/bin/env bash
# Opt-in live verification. Always uses gpt-6-luna with low reasoning.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mise exec -- bash -c 'cd packages/pig_proxy && gleam build --warnings-as-errors'
exec mise exec -- uv run --python 3.13 scripts/validate_prompt_cache_live.py
