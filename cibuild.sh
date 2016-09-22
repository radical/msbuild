#!/usr/bin/env bash

set -e

usage()
{
    echo "Options"
    echo "  --scope <scope>                Scope of the build (Compile / Test)"
    echo "  --target <target>              CoreCLR or Mono (default: CoreCLR)"
    echo "  --host <host>                  CoreCLR or Mono (default: CoreCLR)"
    echo "  --skip-bootstrap               Do not rebuild msbuild with local binaries"
}

restoreBuildTools(){
    eval "$THIS_SCRIPT_PATH/init-tools.sh"
}

# home is not defined on CI machines
setHome()
{
    if [ -z ${HOME+x} ]
    then
        export HOME=$HOME_DEFAULT
        mkdir -p $HOME_DEFAULT
    fi
}

downloadMSBuildForMono()
{
    if [ ! -e "$MSBUILD_EXE" ]
    then
        mkdir -p $PACKAGES_DIR # Create packages dir if it doesn't exist.

        echo "** Downloading MSBUILD from $MSBUILD_DOWNLOAD_URL"
        curl -sL -o $MSBUILD_ZIP "$MSBUILD_DOWNLOAD_URL"

        unzip -q $MSBUILD_ZIP -d $PACKAGES_DIR
        find "$PACKAGES_DIR/msbuild" -name "*.exe" -exec chmod "+x" '{}' ';'
        rm $MSBUILD_ZIP
    fi
}

runMSBuildWith()
{
    local runtimeHost=$1
    local runtimeHostArgs=$2
    local msbuildExe=$3
    local msbuildArgs=$4
    local logPath=$5

    local buildCommand="$runtimeHost $runtimeHostArgs $msbuildExe $msbuildArgs"" /fl "'"'"/flp:v=diag;logfile=$logPath"'"'

    echo
    echo "** using MSBuild in path: $msbuildExe"
    echo "** using runtime host in path: $runtimeHost"
	echo "** $buildCommand"
    eval "$buildCommand"

    echo
	echo "** Build completed. Exit code: $?"
	egrep "Warning\(s\)|Error\(s\)|Time Elapsed" "$logPath"
	echo "** Log: $logPath"
}

setMonoDir(){
    if [[ "$MONO_BIN_DIR" = "" ]]; then
                MONO_BIN_DIR=`dirname \`which mono\``
                MONO_BIN_DIR=${MONO_BIN_DIR}/
    fi
}

SKIP_BOOTSTRAP=false

# Paths
THIS_SCRIPT_PATH="`dirname \"$0\"`"
PACKAGES_DIR="$THIS_SCRIPT_PATH/packages"
TOOLS_DIR="$THIS_SCRIPT_PATH/Tools"
#MSBUILD_DOWNLOAD_URL="https://github.com/Microsoft/msbuild/releases/download/mono-hosted-msbuild-v0.2/mono_msbuild_bootstrap_5e01f07.zip"
MSBUILD_DOWNLOAD_URL="https://github.com/radical/msbuild/releases/download/v0.03/mono_msbuild_d25dd923839404bd64cc63f420e75acf96fc75c4.zip"
MSBUILD_ZIP="$PACKAGES_DIR/msbuild.zip"
HOME_DEFAULT="/tmp/msbuild-CI-home"

BOOTSTRAP_BUILD_LOG_PATH="$THIS_SCRIPT_PATH"/"msbuild_bootstrap_build.log"
LOCAL_BUILD_LOG_PATH="$THIS_SCRIPT_PATH"/"msbuild_local_build.log"
MOVE_LOG_PATH="$THIS_SCRIPT_PATH"/"msbuild_move_bootstrap.log"

PROJECT_FILE_ARG='"'"$THIS_SCRIPT_PATH/build.proj"'"'
BOOTSTRAP_FILE_ARG='"'"$THIS_SCRIPT_PATH/BootStrapMSBuild.proj"'"'
CORERUN_BOOTSTRAPPED_EXE='"'"$THIS_SCRIPT_PATH/bin/Bootstrap/corerun"'"'
MSBUILD_BOOTSTRAPPED_EXE='"'"$THIS_SCRIPT_PATH/bin/Bootstrap/MSBuild.exe"'"'

# Default msbuild arguments
TARGET_ARG="Build"
EXTRA_ARGS=""


#parse command line args
while [ $# -gt 0 ]
do
    opt="$1"
    case $opt in
        -h|--help)
        usage
        exit 1
        ;;

        --scope)
        SCOPE=$2
        shift 2
        ;;

        --target)
        target=$2
        shift 2
        ;;

        --host)
        host=$2
        shift 2
        ;;

        --skip-bootstrap)
        SKIP_BOOTSTRAP=true
        shift 1
        ;;

        *)
        usage
        exit 1
        ;;
    esac
done

# determine OS
OS_NAME=$(uname -s)
case $OS_NAME in
    Darwin)
        OS_ARG="OSX"
        ;;

    Linux)
        OS_ARG="Unix"
        ;;

    *)
        echo "Unsupported OS $OS_NAME detected, configuring as if for Linux"
        OS_ARG="Unix"
        ;;
esac

if [ "$SCOPE" = "Compile" ]; then
	TARGET_ARG="Build"
elif [ "$SCOPE" = "Test" ]; then
	TARGET_ARG="BuildAndTest"
fi

# Determine configuration
case $target in
    CoreCLR)
        CONFIGURATION=Debug-NetCore
        ;;

    Mono)
        setMonoDir
        CONFIGURATION=Debug-MONO
        EXTRA_ARGS="/p:CscToolExe=mcs /p:CscToolPath=$MONO_BIN_DIR"
        RUNTIME_HOST_ARGS="--debug"
        ;;
    *)
        echo "Unsupported target detected: $target. Configuring as if for CoreCLR"
        CONFIGURATION=Debug-NetCore
        ;;
esac

# Determine runtime host
until [[ "$RUNTIME_HOST" != "" ]]; do
      case $host in
          CoreCLR)
              RUNTIME_HOST="$TOOLS_DIR/corerun"
              RUNTIME_HOST_ARGS=""
              MSBUILD_EXE="$TOOLS_DIR/MSBuild.exe"
              EXTRA_ARGS="$EXTRA_ARGS /m"
              ;;

          Mono)
              setMonoDir
              RUNTIME_HOST="${MONO_BIN_DIR}mono"
              MSBUILD_EXE="$PACKAGES_DIR/msbuild/MSBuild.exe"

              downloadMSBuildForMono
              ;;
          *)
              echo "Unsupported host detected: $host. Configuring as if for CoreCLR"
              host=CoreCLR
              ;;
      esac
done

BUILD_MSBUILD_ARGS="$PROJECT_FILE_ARG /t:$TARGET_ARG /p:OS=$OS_ARG /p:Configuration=$CONFIGURATION /verbosity:minimal $EXTRA_ARGS"

setHome

echo "** Using mono version:"
$RUNTIME_HOST --version 
#echo "** deleting nuget caches"
#rm -Rf ~/.nuget/cache
#rm -Rf ~/.local/share/NuGet/
restoreBuildTools
#echo "================ Dumping init-tools.log ============="
#cat init-tools.log
#echo "================ END: Dumping init-tools.log ============="

echo
echo "** Rebuilding MSBuild with binaries from BuildTools"
runMSBuildWith "$RUNTIME_HOST" "$RUNTIME_HOST_ARGS" "$MSBUILD_EXE" "$BUILD_MSBUILD_ARGS" "$BOOTSTRAP_BUILD_LOG_PATH"

if [[ $SKIP_BOOTSTRAP = true ]]; then
    exit $?
fi

echo
echo "** Moving bootstrapped MSBuild to the bootstrap folder"
MOVE_MSBUILD_ARGS="$BOOTSTRAP_FILE_ARG /p:OS=$OS_ARG /p:Configuration=$CONFIGURATION /verbosity:minimal"
runMSBuildWith "$RUNTIME_HOST" "$RUNTIME_HOST_ARGS" "$MSBUILD_EXE" "$MOVE_MSBUILD_ARGS" "$MOVE_LOG_PATH"

# Use the "current" coreclr runtime host; the one in tools/ may be
# stale and incompatible.
if [[ "$host" = "CoreCLR" ]]; then
    RUNTIME_HOST=$CORERUN_BOOTSTRAPPED_EXE
fi

echo
echo "** Rebuilding MSBuild with locally built binaries"
runMSBuildWith "$RUNTIME_HOST" "$RUNTIME_HOST_ARGS" "$MSBUILD_BOOTSTRAPPED_EXE" "$BUILD_MSBUILD_ARGS" "$LOCAL_BUILD_LOG_PATH"
