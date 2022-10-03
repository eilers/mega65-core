#!/bin/bash

SCRIPT="$(readlink --canonicalize-existing "$0")"
SCRIPTPATH="$(dirname "${SCRIPT}")"
SCRIPTNAME=${SCRIPT##*/}

usage () {
    echo "Usage: ${SCRIPTNAME} MODEL VERSION [noreg|repack]"
    echo
    echo "  noreg   skip regression testing"
    echo "  repack  don't copy new stuff, redo cor and mcs, make new 7z"
    echo
    echo "Example: ${SCRIPTNAME} mega65r3 'Experimental Build'"
    echo
    if [[ "x$1" != "x" ]]; then
        echo $1
        echo
    fi
    exit 1
}

if [[ $# -lt 2 || $# -gt 3 ]]; then
    usage
fi

MODEL=$1
VERSION=$2

# determine branch
BRANCH=`git rev-parse --abbrev-ref HEAD`
BRANCH=${BRANCH:0:6}

REPACK=0
NOREG=0
if [[ $# -eq 3 ]]; then
    if [[ $3 == "noreg" ]]; then
        NOREG=1
    elif [[ $3 == "repack" ]]; then
        NOREG=1
        REPACK=1
    else
        usage "unknown option $3"
    fi
fi

if [[ ${MODEL} = "mega65r3" ]]; then
    RM_TARGET="MEGA65R3 boards -- DevKit, MEGA65 R3 and R3a (Artix A7 200T FPGA)"
elif [[ ${MODEL} = "mega65r2" ]]; then
    RM_TARGET="MEGA65R2 boards -- Limited Testkit (Artix A7 100T FPGA)"
elif [[ ${MODEL} = "nexys4ddr-widget" ]]; then
    RM_TARGET="Nexys4DDR boards -- Nexys4DDR, NexysA7 (Artix A7 100T FPGA)"
else
    usage "unknown model ${MODEL}"
fi

PKGPATH=${SCRIPTPATH}/${MODEL}-${BRANCH}
REPOPATH=${SCRIPTPATH%/*}

if [[ ${REPACK} -eq 0 ]]; then
    echo "Cleaning ${PKGPATH}"
    echo
    rm -rvf ${PKGPATH}
fi

for dir in ${PKGPATH}/log ${PKGPATH}/sdcard-files ${PKGPATH}/extra; do
    if [[ ! -d ${dir} ]]; then
        mkdir -p ${dir}
    fi
done

# put text files into package path
echo "Creating info files from templates"
for txtfile in README.md Changelog.md; do
    echo ".. ${txtfile}"
    envsubst < ${SCRIPTPATH}/${txtfile} > ${PKGPATH}/${txtfile}
done

BITPATH=$( ls -1 --sort time ${REPOPATH}/bin/${MODEL}*.bit | head -1 )
BITNAME=${BITPATH##*/}
BITBASE=${BITNAME%.bit}
HASH=${BITBASE##*-}

echo "Bitstream found: ${BITNAME}"
echo

if [[ ${REPACK} -eq 0 ]]; then
    echo "Copying build files"
    echo
    cp ${REPOPATH}/bin/HICKUP.M65 ${PKGPATH}/extra/
    cp ${REPOPATH}/sdcard-files/* ${PKGPATH}/sdcard-files/

    cp ${BITPATH} ${PKGPATH}/
    cat $( ls -1 --sort time ${REPOPATH}/vivado*.log | head -2 | tac ) > ${PKGPATH}/log/${BITBASE}.log
    cp ${BITPATH%.bit}.timing.txt ${PKGPATH}/log/
    VIOLATIONS=$( grep -c VIOL ${BITPATH%.bit}.timing.txt )
    if [[ $VIOLATIONS -gt 0 ]]; then
        touch ${PKGPATH}/WARNING_${VIOLATIONS}_TIMING_VIOLATIONS
    fi
fi

echo "Building COR/MCS"
echo
if [[ ${MODEL} == "nexys4ddr-widget" ]]; then
    bit2core nexys4ddrwidget ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor
elif [[ ${MODEL} == "mega65r2" ]]; then
    bit2core mega65r2 ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor
else
    bit2core ${MODEL} ${PKGPATH}/${BITNAME} MEGA65 "${VERSION} ${HASH}" ${PKGPATH}/${BITBASE}.cor ${REPOPATH}/../mega65-release-prep/MEGA65.ROM ${PKGPATH}/sdcard-files/*
fi
bit2mcs ${PKGPATH}/${BITBASE}.cor ${PKGPATH}/${BITBASE}.mcs 0

# do regression tests
echo
if [[ $NOREG -eq 1 ]]; then
    echo "Skipping regression tests"
    if [[ ${REPACK} -eq 0 ]]; then
        touch ${PKGPATH}/WARNING_NO_TESTS_COULD_BE_MADE
    fi
else
    echo "Starting regression tests"
    ${REPOPATH}/../mega65-tools/src/tests/regression-test.sh ${BITPATH} ${PKGPATH}/log/
    if [[ $? -ne 0 ]]; then
        touch ${PKGPATH}/WARNING_TESTS_HAVE_FAILED_SEE_LOGS
    fi
    echo "done"
fi
echo

if [[ -e ${SCRIPTPATH}/${MODEL}-reltest-${HASH}.7z ]]; then
    rm -f ${SCRIPTPATH}/${MODEL}-reltest-${HASH}.7z
fi
7z a ${SCRIPTPATH}/${MODEL}-reltest-${HASH}.7z ${PKGPATH}
