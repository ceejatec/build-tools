#!/bin/bash -ex

PRODUCT=$1
RELEASE=$2
VERSION=$3
BLD_NUM=$4

MAVEN_VERSION=3.6.3

cbdep install -d "${WORKSPACE}/extra" mvn ${MAVEN_VERSION}
export PATH="${WORKSPACE}/extra/mvn-${MAVEN_VERSION}/bin:${PATH}"

git clone ssh://git@github.com/couchbase/couchbase-jvm-clients
pushd couchbase-jvm-clients

if [[ "$VERSION" == 1.* ]]
then
    TAG=kotlin-client-$VERSION
else
    TAG=$VERSION
fi

if git rev-parse --verify --quiet $TAG >& /dev/null
then
    echo "$TAG exists, checking it out"
    git checkout $TAG
else
    echo "No $TAG tag or branch, assuming master"
fi

# The fit-performer packages are test-only and require a non-public
# jar, so they'll never be shipped; but their poms mess up the scans.
rm -rf *-fit-performer

# And now we actually need to build stuff for it to be found
# by the detector
mvn --batch-mode dependency:resolve || {
    for project in protostellar core-io-deps test-utils tracing-opentelemetry-deps . ; do
        if [ -e "$project" ]; then
            mvn --batch-mode -f "$project/pom.xml" -Dmaven.test.skip=true clean install
        fi
    done
}

popd
