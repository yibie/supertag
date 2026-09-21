#!/usr/bin/env bash
# Dependency load path shared by test/run-tests.sh and test/static-gates.sh.
#
# Sourcing this file resolves the ht/dash package directories, exports them as
# SUPERTAG_DEPS_LOADPATH, and leaves the same directories in the
# SUPERTAG_DEPS_DIRS array for callers that build their own `-L' arguments.
#
# Test children spawn Emacs with no package path of their own and read the
# variable only:
#
#   (deps (split-string (or (getenv "SUPERTAG_DEPS_LOADPATH") "") path-separator t))
#
# so a harness that does not export it makes every subprocess test fail on
# `(require 'ht)' while the parent process, which loads its own dependencies
# through `package-initialize', notices nothing.
#
# Resolution order, matching test/static-gates.sh:
#   1. an already-set SUPERTAG_DEPS_LOADPATH is honoured untouched;
#   2. otherwise the highest-versioned "$HOME"/.emacs.d/elpa/{ht,dash}-*
#      directories are used;
#   3. when neither yields a directory, stop the caller with a clear message
#      instead of running suites whose children cannot possibly pass.
#
# Exit status is 1 (and the caller stops) on 3 and on any missing directory.

supertag_test_deps_loadpath_resolve() {
  SUPERTAG_DEPS_DIRS=()
  if [ -n "${SUPERTAG_DEPS_LOADPATH:-}" ]; then
    IFS=: read -r -a SUPERTAG_DEPS_DIRS <<< "$SUPERTAG_DEPS_LOADPATH"
  else
    local name candidate
    for name in ht dash; do
      candidate=$(ls -d "$HOME"/.emacs.d/elpa/${name}-* 2>/dev/null | sort -V | tail -1 || true)
      [ -n "$candidate" ] && SUPERTAG_DEPS_DIRS+=("$candidate")
    done
    case "${#SUPERTAG_DEPS_DIRS[@]}" in
      0) SUPERTAG_DEPS_LOADPATH="" ;;
      *) SUPERTAG_DEPS_LOADPATH=$(IFS=:; printf '%s' "${SUPERTAG_DEPS_DIRS[*]}") ;;
    esac
  fi
  if [ "${#SUPERTAG_DEPS_DIRS[@]}" -eq 0 ]; then
    echo 'No ht/dash dependency directories found; set SUPERTAG_DEPS_LOADPATH' >&2
    exit 1
  fi
  local directory
  for directory in "${SUPERTAG_DEPS_DIRS[@]}"; do
    [ -d "$directory" ] || {
      echo "Dependency directory not found: $directory" >&2
      exit 1
    }
  done
  export SUPERTAG_DEPS_LOADPATH
}

# Native compilation in `emacs -Q' children.
#
# A test that mocks a primitive (`read-string', `completing-read') makes a
# native-comp Emacs compile a trampoline, and linking it needs gcc's own
# library directory (libemutls_w.a). Homebrew's emacs-plus hands that directory
# to libgccjit from site-start.el, which `-Q' skips, so every such child dies
# with "ld: library 'emutls_w' not found". LIBRARY_PATH reaches the driver
# regardless of `-Q'.
#
# Best effort: without a Homebrew gcc there is nothing to add, and an Emacs
# built without native compilation never asks for it.
supertag_test_native_comp_library_path() {
  local gcc emutls directory
  gcc=$(ls /opt/homebrew/opt/gcc/bin/gcc-[0-9]* /usr/local/opt/gcc/bin/gcc-[0-9]* 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$gcc" ] || return 0
  emutls=$("$gcc" -print-file-name=libemutls_w.a 2>/dev/null || true)
  case "$emutls" in
    */*) directory=$(dirname "$emutls") ;;
    *) return 0 ;;
  esac
  [ -d "$directory" ] || return 0
  case ":${LIBRARY_PATH:-}:" in
    *":$directory:"*) ;;
    *) LIBRARY_PATH="$directory${LIBRARY_PATH:+:$LIBRARY_PATH}" ;;
  esac
  export LIBRARY_PATH
}

supertag_test_deps_loadpath_resolve
supertag_test_native_comp_library_path
