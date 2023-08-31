#!/bin/zsh -e

#${KEYCHAIN_PASSWORD} and ${AC_PASSWORD} are injected as an env password in jenkins job

function usage
{
  echo "\nUsage: $0 -p <Product> -r <Release> -v <Version> -b <Build> -e <Edition> -a <Arch> -n\n"
  echo "  -p Product:  couchbase-server|sync_gateway|couchbase-lite-c \n"
  echo "  -r Release: i.e. elixir, 3.1.0 \n"
  echo "  -v Version: i.e. 7.2.0, 3.1.0 \n"
  echo "  -b Build: i.e. 123 \n"
  echo "  optional: \n"
  echo "  -e Edition: enterprise(default)|community \n"
  echo "  -a Arch: x86_64(default)|arm64 \n"
  echo "  -d: download\n"
}

function unlock_keychain
{
    #unlock keychain
    echo "------- Unlocking keychain -----------"
    security unlock-keychain -p ${KEYCHAIN_PASSWORD} ${HOME}/Library/Keychains/login.keychain-db
}

function codesign_pkg
{
    pkg_dir=$1
    pkg_signed=$2
    echo "pkg_dir $pkg_dir\n"
    echo "pkg_signed $pkg_signed\n"
    echo "------- Codesigning binaries within the package -------"
    find ${pkg_dir} -type f | while IFS= read -r file
    do
        ##binaries in jars have to be signed.
        if [[ "${file}" =~ ".jar" ]]; then
            libs=$(jar -tf "${file}" | grep ".jnilib\|.dylib")
            if [[ ! -z ${libs} ]]; then
                for lib in ${libs}; do
                    dir=$(echo ${l} |awk -F '/' '{print $1}')
                    jar xf "${file}" "${lib}"
                    codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} "${lib}"
                    jar uf "${file}" "${lib}"
                    rm -rf ${dir}
                done
                rm -rf META-INF
            fi
        elif [[ `file --brief "${file}"` =~ "Mach-O" ]]; then
            codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} "${file}"
        fi
    done

    echo "------- Codesigning the package ${pkg_signed} -------"
    pushd ${pkg_dir}
    zip --symlinks -r -X ../${pkg_signed} *
    popd
    codesign ${(z)SIGN_FLAGS} --sign ${CERT_NAME} ${pkg_signed}
}

##Main

#unlock keychain
unlock_keychain

ARCH=x86_64
EDITION=enterprise
DOWNLOAD=false

while getopts a:b:e:p:r:v:d opt
do
  case ${opt} in
    a)
      ARCH=${OPTARG}
      ;;
    b) BUILD_NUM=${OPTARG}
      ;;
    e) EDITION=${OPTARG}
      ;;
    p) PRODUCT=${OPTARG}
      ;;
    r) RELEASE=${OPTARG}
      ;;
    v) VERSION=${OPTARG}
      ;;
    d) DOWNLOAD=true
      ;;
    *)
      usgae
      ;;
    esac
done

if [[ -z ${PRODUCT} || -z ${VERSION} || -z ${RELEASE} || -z ${BUILD_NUM} ]]; then
    usage
    exit 1;
fi

SIGN_FLAGS="--force --timestamp --options=runtime  --verbose --entitlements cb.entitlement --preserve-metadata=identifier,requirements"
CERT_NAME="Developer ID Application: Couchbase, Inc. (N2Q372V7W2)"

PKG_URL=http://latestbuilds.service.couchbase.com/builds/latestbuilds/${PRODUCT}/${RELEASE}/${BUILD_NUM}

declare -A PKGS
declare -A PKGS_SIGNED

case ${PRODUCT} in
sync_gateway)
    PKGS[couchbase-sync-gateway]=couchbase-sync-gateway-${EDITION}_${VERSION}-${BUILD_NUM}_${ARCH}_unsigned.zip
    PKGS_SIGNED[couchbase-sync-gateway]=couchbase-sync-gateway-${EDITION}_${VERSION}-${BUILD_NUM}_${ARCH}.zip
    PRIMARY_BUNDLE_ID=com.couchbase.couchbase-sync-gateway
    ;;
couchbase-lite-c)
    PKGS[${PRODUCT}]=${PRODUCT}-${EDITION}-${VERSION}-${BUILD_NUM}-macos_unsigned.zip
    PKGS_SIGNED[${PRODUCT}]=${PRODUCT}-${EDITION}-${VERSION}-${BUILD_NUM}-macos.zip
    PKGS[${PRODUCT}-symbols]=${PRODUCT}-${EDITION}-${VERSION}-${BUILD_NUM}-macos-symbols_unsigned.zip
    PKGS_SIGNED[${PRODUCT}-symbols]=${PRODUCT}-${EDITION}-${VERSION}-${BUILD_NUM}-macos-symbols.zip
    PRIMARY_BUNDLE_ID=com.couchbase.couchbase-lite-c
    ;;
couchbase-server)
    PKGS[${PRODUCT}]=${PRODUCT}-tools_${VERSION}-${BUILD_NUM}-macos_${ARCH}_unsigned.zip
    PKGS_SIGNED[${PRODUCT}]=${PRODUCT}-tools_${VERSION}-${BUILD_NUM}-macos_${ARCH}.zip
    PRIMARY_BUNDLE_ID=com.couchbase.couchbase-server-tools
    ;;
*)
    echo "Unsupported product ${PRODUCT}, exit now..."
    exit 1
    ;;
esac

for pkg pkg_name in ${(@kv)PKGS}; do
    rm -rf ${pkg}
    if [[ ${DOWNLOAD} == "true" ]]; then
        curl -LO ${PKG_URL}/${pkg_name}
    fi

    mkdir ${pkg}
    unzip -qq ${pkg_name} -d ${pkg}
    codesign_pkg ${pkg} ${PKGS_SIGNED[${pkg}]}
done
