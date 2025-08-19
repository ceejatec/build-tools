#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

TAG=$VERSION
git clone ssh://git@github.com/couchbaselabs/couchbase-analytics-jvm-clients
pushd couchbase-analytics-jvm-clients
if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "Tag $TAG exists, checking it out"
    git checkout $TAG
else
    echo "No tag $TAG, assuming master"
fi

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf couchbase-analytics-java-client/fit
rm -rf couchbase-analytics-java-client/examples

# And now we actually need to build stuff for it to be found by the
# detector :( Use a custom local Maven repository per-product to ensure
# SNAPSHOT stuff doesn't cross-polinate.
export MAVEN_CONFIG="--batch-mode -Dmaven.repo.local=/home/couchbase/.m2/${PRODUCT}-repository -Dmaven.test.skip=true"
make install

popd
