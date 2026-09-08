#!/usr/bin/env bash
set -euo pipefail

# -----------------------------------------------------------------------------
# LUAX Headless Neovim Test Runner
# Launches nvim --headless with fully isolated XDG environments in /tmp/
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
LUAX_ROOT="${WORKSPACE_ROOT}/luax"
NVIM_PLUGIN_ROOT="${LUAX_ROOT}/nvim"

# Create isolated XDG scratch directory in /tmp
TMP_DIR=$(mktemp -d /tmp/hydronium_nvim_test_XXXXXX)
trap 'rm -rf "${TMP_DIR}"' EXIT

export XDG_CONFIG_HOME="${TMP_DIR}/config"
export XDG_DATA_HOME="${TMP_DIR}/data"
export XDG_STATE_HOME="${TMP_DIR}/state"
export XDG_CACHE_HOME="${TMP_DIR}/cache"

mkdir -p "${XDG_CONFIG_HOME}/nvim"
mkdir -p "${XDG_DATA_HOME}/nvim/site/parser"
mkdir -p "${XDG_STATE_HOME}"
mkdir -p "${XDG_CACHE_HOME}"

# Ensure compiled tree-sitter luax.so parser is available in isolated site/parser
if [ -f "${LUAX_ROOT}/parser/luax.so" ]; then
  cp "${LUAX_ROOT}/parser/luax.so" "${XDG_DATA_HOME}/nvim/site/parser/luax.so"
elif [ -f "${LUAX_ROOT}/tree-sitter-luax/luax.so" ]; then
  cp "${LUAX_ROOT}/tree-sitter-luax/luax.so" "${XDG_DATA_HOME}/nvim/site/parser/luax.so"
fi

# Locate nvim binary
NVIM_BIN="$(which nvim || echo "/opt/homebrew/bin/nvim")"
if [ ! -x "${NVIM_BIN}" ]; then
  echo "Error: Neovim binary not found." >&2
  exit 1
fi

# Run headless test script with only the standalone LUAX plugin on runtimepath.
# Its setup() must locate the sibling package root for parser/query discovery.
"${NVIM_BIN}" --headless \
  -u NONE \
  --cmd "set rtp^=${NVIM_PLUGIN_ROOT}" \
  --cmd "filetype plugin indent on" \
  -l "${SCRIPT_DIR}/nvim/test_headless.lua"
