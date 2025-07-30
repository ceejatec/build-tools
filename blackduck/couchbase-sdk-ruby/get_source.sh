#!/bin/bash -ex

# current repo, do not remove:
# github.com/couchbase/couchbase-ruby-client

SCRIPT_ROOT="$(dirname ${BASH_SOURCE[0]})"

WORKDIR="${WORKSPACE}/src"

# example usage
# get_source.sh couchbase-sdk-ruby 3.4.5 3.4.5 9999

# "couchbase-sdk-ruby", ignored in this script
PRODUCT=$1
# by default this will be the same as VERSION; however, if your scan-config.json specified a release key for this version, that value will be passed here
RELEASE=$2
# one of the version keys from scan-config.json
VERSION=$3
# ignored in this script, as it is not useful for SDK scans (will be 9999)
BLD_NUM=$4

# There's no consistent place across versions to grab a cmake version from
# the source, at time of writing 3.28.3 is the latest release
CMAKE_VERSION=3.28.3
cbdep install -d "${WORKSPACE}/extra" cmake ${CMAKE_VERSION}
export PATH="${WORKSPACE}/extra/cmake-${CMAKE_VERSION}/bin:${PATH}"

export GEM_HOME="${SCRIPT_ROOT}/.gem"
export GEM_PATH="${GEM_HOME}"

ruby --version

pushd "${WORKDIR}"
bundle config set --local path "${GEM_HOME}"
ruby "${SCRIPT_ROOT}/get_source.rb" $VERSION $RELEASE
popd
