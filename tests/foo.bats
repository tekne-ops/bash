#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$(dirname "${BATS_TEST_FILENAME}")/.." && pwd)"
  PATH="${REPO_ROOT}/bin:${PATH}"
}

@test "foo prints hello with default name" {
  run bash "${REPO_ROOT}/bin/foo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello, world!"* ]]
}

@test "foo supports custom name" {
  run bash "${REPO_ROOT}/bin/foo" -n David
  [ "$status" -eq 0 ]
  [[ "$output" == *"Hello, David!"* ]]
}
