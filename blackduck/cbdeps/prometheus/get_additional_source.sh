#!/bin/bash -e

# This will also create
# `src/cbdeps::prometheus-black-duck-manifest.yaml` containing an entry
# for "Go programming language" with the appropriate version.
export PATH="$(${WORKSPACE}/build-tools/blackduck/jenkins/util/go-path-from-manifest.sh):$PATH"
