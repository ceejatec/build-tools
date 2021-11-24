#!/bin/bash -ex

INSTALL_DIR=$1
PLATFORM=$2

ARCH=`uname -m`

pushd $(dirname $0) > /dev/null
SCRIPTPATH=$(pwd -P)
popd > /dev/null

DEPS=/tmp/deps
rm -rf ${DEPS}
mkdir -p ${DEPS}

# This is horrible and I hate it, but it's required for building v8
# using gcc, and I really don't like the idea of baking this into
# our build agent images *just* to build v8. I suggest destroying
# the build agents after compiling v8 ("docker stack rm" then
# re-deploy).
if [[ "${PLATFORM}" =~ amzn*|centos*|rhel*|linux* ]]; then
    sudo yum install -y glib2-devel
elif [[ "${PLATFORM}" =~ suse* ]]; then
    # suse12 can't do this because the agents aren't hosted on
    # suse12 VMs, so we have to bake it in there :(
    [ "${PLATFORM}" = suse12 ] || sudo zypper install -y glib2-devel
elif [[ "${PLATFORM}" =~ debian*|ubuntu* ]]; then
    # This env var helps work around a problem with libstdc++ from
    # /usr/local breaking apt-get on ubuntu20; should be harmless
    # on other platforms
    sudo LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu apt-get update
    sudo LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu apt-get install -y libglib2.0-dev
fi

# If a newer GCC exists in /opt, use it
if [ -d /opt/gcc/bin ]; then
    export PATH=/opt/gcc/bin:${PATH}
fi

# We assume a reasonable python2 is available for aarch64 builds.
# Can't fall back to miniconda there because miniconda doesn't have
# aarch64 versions of python2.
#
# Homebrew or /usr/local is likely the first entry of PATH on Mac.  Python
# usually points to python3.  glcient requires Python2.  Put /usr/bin
# in the front so that in the front so that python defaults to python2.
if [[ "${PLATFORM}" == "macosx" ]]; then
    export PATH=/usr/bin:${PATH}
elif [[ "${ARCH}" == "x86_64" ]]; then
    # Download cbdep to get python2 (still required for this build sadly).
    CBDEP_TOOL_VER=1.1.1
    MINICONDA_VER=4.7.12.1

    # Download cbdep, unless it's already available in the local .cbdepscache
    OPSYS=$(uname -s | tr "[:upper:]" "[:lower:]")
    CBDEP_BIN_CACHE=/home/couchbase/.cbdepscache/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-${OPSYS}

    if [[ -f ${CBDEP_BIN_CACHE} ]]; then
        cp ${CBDEP_BIN_CACHE} /tmp/cbdep
    else
        CBDEP_URL=https://packages.couchbase.com/cbdep/${CBDEP_TOOL_VER}/cbdep-${CBDEP_TOOL_VER}-${OPSYS}
        curl -o /tmp/cbdep ${CBDEP_URL}
    fi

    chmod +x /tmp/cbdep

    # Use cbdep to install miniconda2. Add to PATH *last* (so it only adds
    # python2, not overriding anything). Also add to LD_LIBRARY_PATH as the
    # "vpython" script the build uses creates a copy of "python2" but doesn't
    # copy libpython2 as well.  ubuntu20 comes with python3, v8 doesn't
    # work well with python3, put miniconda2 in the front as well.

    /tmp/cbdep install -d ${DEPS} miniconda2 ${MINICONDA_VER}
    export PATH_ORG=${PATH}
    export LD_LIBRARY_PATH=${DEPS}/miniconda2-${MINICONDA_VER}/lib

    if [[ "${PLATFORM}" != "ubuntu20.04" && "${PLATFORM}" != "ubuntu18.04" ]]; then
        export PATH=${PATH_ORG}:${DEPS}/miniconda2-${MINICONDA_VER}/bin
    else
        export PATH=${DEPS}/miniconda2-${MINICONDA_VER}/bin:${PATH_ORG}
    fi
fi
# Get Google's depot_tools; lock to moderately recent build (as of June 2021)
git clone https://chromium.googlesource.com/chromium/tools/depot_tools.git
pushd depot_tools && git checkout 5ba5119227002ab191b0f916df435b7410c4ca3c && popd
export PATH=$(pwd)/depot_tools:$PATH

# Do NOT use their bundled python binary
export VPYTHON_BYPASS="manually managed python not supported by chrome operations"

# Build Ninja, which is needed to build gn
pushd ${DEPS}
if [ ! -d ninja ]; then
    mkdir ninja
    pushd ninja
    git clone https://github.com/ninja-build/ninja.git
    cd ninja
    git checkout 112f85e1536b82d5f0bd84ceea5df4634151dfa9
    ./configure.py --bootstrap
    popd
fi
export PATH=$(pwd)/ninja/ninja:$PATH
popd

# Build gn based on specific SHA, which is compatible with v8 (9.7.37 as of 10/2021)
# When upgrading v8, gn's SHA will need to be advanced as needed.
# We have to build our own on at least some platforms either due to Google's depot_tools' gn using too
# new a glibc(i.e. 2.18+ in 10/2021), or else not working on aarch64. We also have to
# force it to use our compiler.

pushd ${DEPS}
if [ ! -d gn ]; then
    mkdir gn
    pushd gn
    git clone https://gn.googlesource.com/gn
    cd gn
    git checkout 79c6c1b1a24c46df5a773cc61604bb5051ca6cf4
    CC=$(which gcc) CXX=$(which g++) python build/gen.py
    ninja -C out
    popd
fi
export PATH=$(pwd)/gn/gn/out:$PATH
popd

# Set up gclient config for tag to pull for v8, then do sync
# (this handles the 'fetch v8' done by the usual process)
cat > .gclient <<EOF
solutions = [
  {
    "url": "https://github.com/couchbasedeps/v8-mirror.git@9.7.37",
    "managed": False,
    "name": "v8",
    "deps_file": "DEPS",
  },
];
EOF

gclient sync

# Several patches and tweaks for Linux builds
if [[ $PLATFORM != "macosx" ]]; then
    # Apply change to enable RPATH (runpath) for libraries/binaries on Linux
    pushd v8/build
    git apply $SCRIPTPATH/linux_patches/v8_linux_runpath.patch
    popd

    # Necessary for building on aarch64.
    # test-code-stub-assembler.cc is broken on aarch64 with ""invalid addressing mode at operand 2"
    # Comment it out until it is fixed.
    if [[ $ARCH == "aarch64" ]]; then
        pushd v8/test/cctest
        git apply $SCRIPTPATH/linux_patches/cctest_aarch64.patch
        popd
    fi

    # Set up all the weird tool aliases that gn expects
    pushd ${DEPS}
    for tool in gcc g++ ar readelf nm; do
	ln -s $(which ${tool}) $(uname -m)-linux-gnu-${tool}
    done
    export PATH=$(pwd):$PATH
    popd
fi

# Actual v8 configure and build steps - we build debug and release.
if [[ "${ARCH}" = "aarch64" || "${ARCH}" = "arm64" ]]; then
    TARGET_CPU=arm64
else
    TARGET_CPU=x64
fi
if [[ "${PLATFORM}" == "macosx" ]]; then
    IS_CLANG=true
else
    IS_CLANG=false
fi

cd v8
V8_ARGS="target_cpu=\"${TARGET_CPU}\" is_clang=${IS_CLANG} use_sysroot=false use_gold=false linux_use_bundled_binutils=false is_component_build=true v8_enable_backtrace=true v8_use_external_startup_data=false use_custom_libcxx=false v8_enable_pointer_compression=false treat_warnings_as_errors=false"

gn gen out.gn/x64.release --args="$V8_ARGS is_debug=false"
ninja -j4 -C out.gn/x64.release
V8_ARGS="$V8_ARGS v8_enable_slow_dchecks=true"
#only enable v8_optimized_debug=false if it is not macosx as of V8 8.3 as it causes unitest failures
if [[ $PLATFORM != "macosx" ]]; then
    V8_ARGS="$V8_ARGS v8_optimized_debug=false"
fi
gn gen out.gn/x64.debug --args="$V8_ARGS is_debug=true"
ninja -j4 -C out.gn/x64.debug

# Copy right stuff to output directory.
mkdir -p \
    $INSTALL_DIR/lib/Release \
    $INSTALL_DIR/lib/Debug \
    $INSTALL_DIR/include/libplatform \
    $INSTALL_DIR/include/cppgc \
    $INSTALL_DIR/include/unicode
(
    cd out.gn/x64.release
    cp -avi libv8*.* $INSTALL_DIR/lib/Release
    cp -avi libchrome*.* $INSTALL_DIR/lib/Release
    cp -avi libcppgc*.* $INSTALL_DIR/lib/Release
    cp -avi libicu*.* $INSTALL_DIR/lib/Release
    cp -avi icu*.* $INSTALL_DIR/lib/Release
    rm -f $INSTALL_DIR/lib/Release/*.TOC
    rm -f $INSTALL_DIR/lib/Release/*for_testing*
    rm -f $INSTALL_DIR/lib/Release/*debug_helper*
)
(
    cd out.gn/x64.debug
    cp -avi libv8*.* $INSTALL_DIR/lib/Debug
    cp -avi libchrome*.* $INSTALL_DIR/lib/Debug
    cp -avi libcppgc*.* $INSTALL_DIR/lib/Debug
    cp -avi libicu*.* $INSTALL_DIR/lib/Debug
    cp -avi icu*.* $INSTALL_DIR/lib/Debug
    rm -f $INSTALL_DIR/lib/Debug/*.TOC
    rm -f $INSTALL_DIR/lib/Debug/*for_testing*
    rm -f $INSTALL_DIR/lib/Debug/*debug_helper*
)
(
    cd include
    cp -avi v8*.h $INSTALL_DIR/include
    cp -avi libplatform/[a-z]*.h $INSTALL_DIR/include/libplatform
    cp -avi cppgc/[a-z]*.h $INSTALL_DIR/include/cppgc
)
(
    cd third_party/icu/source/common/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/io/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/i18n/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)
(
    cd third_party/icu/source/extra/uconv/unicode
    cp -avi *.h $INSTALL_DIR/include/unicode
)