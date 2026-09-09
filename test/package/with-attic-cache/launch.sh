#!/bin/dash
set -eu

fail() {
  printf '%s\n' "FAIL: $*" >&2
  exit 1
}

pass() {
  printf '%s\n' "PASS: $*" >&2
}

assert_file_contains() {
  label=$1
  file=$2
  pattern=$3
  grep -q "$pattern" "$file" || fail "$label: missing $pattern in $file"
  pass "$label"
}

# shellcheck disable=SC1091,SC2154
. "$test/run.sh"
