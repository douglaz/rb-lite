set shell := ["bash", "-eu", "-o", "pipefail", "-c"]

default:
    @just --list

lint:
    bash -n bin/rb-lite
    bash -n tests/smoke.sh

test: lint
    bash tests/smoke.sh

check: test
    nix flake check

build:
    nix build
