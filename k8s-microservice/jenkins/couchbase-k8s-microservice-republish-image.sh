#!/bin/bash -e

script_dir=$(dirname $(readlink -e -- "${BASH_SOURCE}"))

source ${script_dir}/../../utilities/shell-utils.sh
source ${script_dir}/util/funclib.sh

chk_set PRODUCT
chk_set VERSION
chk_set REGISTRY

function republish() {
    product=$1
    version=$2

    short_product=${product/couchbase-/}

    # Rebuild the images on internal registry - this will update the base image.
    # Pass the -P argument to have the new images Published.
    status Rebuilding ${product} ${version}
    ${script_dir}/util/build-k8s-images.sh -R ${REGISTRY} -P -p ${product} -v ${version}
}


# Main program logic begins here

ROOT=$(pwd)

# See if this version is marked to be ignored - some older
# versions just won't build anymore due to changes in package
# repositories, etc.
if curl --silent --fail \
    http://releases.service.couchbase.com/builds/releases/${PRODUCT}/${VERSION}/.norebuild
then
    status "Skipping ${PRODUCT} ${VERSION} due to .norebuild"
    exit 0
fi

republish ${PRODUCT} ${VERSION}
