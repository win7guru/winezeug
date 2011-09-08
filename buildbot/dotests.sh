#!/bin/sh
# Script to build and test wine under various conditions,
# skipping tests listed in bugzilla as failing.

set -e
set -x

SRC=`dirname $0`
SRC=`cd $SRC; pwd`

usage() {
    cat <<_EOF_
Usage: $0 command
Commands:
   goodtests
   badtests
   flakytests
_EOF_
    exit 1
}

# DLLs whose tests don't need DISPLAY set
HEADLESS_DLLS="\
    advpack amstream avifil32 browseui cabinet comcat credui crypt32 \
    cryptnet cryptui d3d10 d3d10core d3dxof \
    dispex dmime dmloader dnsapi dplayx dxdiagn dxgi faultrep fusion \
    gameux hlink imagehlp imm32 inetcomm inetmib1 infosoft iphlpapi \
    itss jscript localspl localui lz32 mapi32 mlang msacm32 \
    mscms mscoree msi mstask msvcp90 msvcr90 msvcrt msvcrtd msvfw32 \
    msxml3 netapi32 ntdll ntdsapi ntprint odbccp32 oleacc \
    oledb32 pdh propsys psapi qedit qmgr \
    rasapi32 rpcrt4 rsaenh schannel secur32 serialui setupapi \
    shdocvw snmpapi spoolss sti twain_32 urlmon userenv \
    uxtheme vbscript version wer windowscodecs winhttp \
    winspool.drv wintab32 wintrust wldap32 xinput1_3 xmllite"

# Run all tests that don't require the display
do_background_tests() {
    background_errors=0
   
    OLDDISPLAY=DISPLAY
    unset DISPLAY
    export WINEPREFIX=`pwd`/wineprefix-background
    cd dlls
    for dir in *
    do
        if echo $HEADLESS_DLLS | grep -qw $dir && test -d $dir/tests && cd $dir/tests
        then
            make -k test || background_errors=`expr $background_errors + 1`
            cd ../..
        fi
    done
    cd ..
    cd programs
    for dir in *
    do
        if test -d $dir/tests && cd $dir/tests
        then
            make -k test || background_errors=`expr $background_errors + 1`
            cd ../..
        fi
    done

    # probably not needed, but...
    case "$OLDDISPLAY" in
    "") ;;
    *) DISPLAY=$OLDDISPLAY; export DISPLAY;;
    esac

    case $background_errors in
    0) echo "do_background_tests pass."; return 0 ;;
    *) echo "do_background_tests fail: $background_errors directories had errors." ; return 1;;
    esac
}

# Run all tests that do require the display
do_foreground_tests() {
    foreground_errors=0
    export WINEPREFIX=`pwd`/wineprefix-foreground
    cd dlls
    for dir in *
    do
        if echo $HEADLESS_DLLS | grep -vqw $dir && test -d $dir/tests && cd $dir/tests
        then
            make -k test || foreground_errors=`expr $foreground_errors + 1`
            cd ../..
        fi
    done
    cd ..

    # In win64, currently iexplore and rpcss hang around after tests
    # causing buildbot to not detect that tests have completed.
    server/wineserver -k

    case $foreground_errors in
    0) echo "do_foreground_tests pass."; return 0 ;;
    *) echo "do_foreground_tests fail: $foreground_errors directories had errors." ; return 1;;
    esac
}

# Blacklist format
# test condition [bug]
# Tests may appear multiple times in the list.
# Supported conditions:
# FLAKY - fails sometimes
# CRASHY - crashes sometimes
# SYS - always fails on some systems, not on others
# HEAP - fails or crashes if warn+heap
# NOTTY - test fails if output redirected
# BAD64 - always fails on 64 bits

# Return tests that match given criterion
# Usage: get_blacklist regexp
# e.g.
#  get_blacklist 'SYS' gets all tests that reliably crash on some systems
#  get_blacklist 'FLAKY|CRASHY' gets all tests that fail or crash occasionally

get_blacklist() {
    egrep "$1" < $SRC/dotests_blacklist.txt | awk '{print $1}' | sort -u
}

# Run all the known good tests
# This takes a while, so speed things up a bit by running some tests in background
do_goodtests() {
    # Skip all tests that might fail
    match='SYS|FLAKY|CRASHY'
    case `arch` in
    x86_64) match="$match|BAD64";;
    esac
    echo "Checking WINEDEBUG ($WINEDEBUG)"
    case "$WINEDEBUG" in
    *warn+heap*) match="$match|HEAP" ;;
    esac
    if ! test -t 1
    then
        match="$match|NOTTY"
    fi
    touch `get_blacklist "$match"`

    # Many tests only work in english locale
    LANG=en_US.UTF-8
    export LANG

    if test "$DISPLAY" = ""
    then
        echo "DISPLAY not set, doing headless tests"
        do_background_tests
    else
        echo "DISPLAY set, doing full tests"
        # Run two groups of tests in parallel
        # The background tests don't need the display, and use their own wineprefix
        # Neither use much CPU, so this should save time even on slow computers
        do_background_tests > background.log 2>&1 &
        # Under set -e, script aborts early for foreground failures, and on wait %1 for background failures,
        # making it hard to show the background log before aborting.
        # So use set +e, and check status of background and foreground manually.
        set +e
        do_foreground_tests
        foreground_status=$?
        wait %1
        background_status=$?
        cat background.log
        if test $foreground_status -ne 0 || test $background_status -ne 0
        then
            echo "FAIL: background_status $background_status, foreground_status $foreground_status"
            exit 1
        fi
        set -e
    fi
    echo "goodtests done."
}

# Run tests that are expected to fail for given reason
# Usage: do_badtests regexp
# e.g.
#  do_badtests . - to get all tests that fail somewhere sometimes
#  do_badtests 'FLAKY|CRASHY' - to get only the unreliably unreliable tests
do_badtests() {
    # Many tests only work in english locale
    # FIXME Someday change this to choose a non-english locale
    LANG=en_US.UTF-8
    export LANG

    for badtest in `get_blacklist $1`
    do
        badtestdir=${badtest%/*}
        badtestfile=${badtest##*/}
        (
        cd $badtestdir
        if make $badtestfile
        then
            reasons="`grep $badtest < $SRC/dotests_blacklist.txt | awk '{print $2}'`"
            bugs="`grep $badtest < $SRC/dotests_blacklist.txt | awk '{print $3}'`"
            if test "$bugs"
            then
                echo "$badtest passed; the blacklist says this test is $reasons, and is mentioned in bug $bugs."
            fi
        else
            echo "$badtest FAILED."
        fi
        )
    done
    echo "badtests $1 done."
}

if ! test "$1"
then
    usage
fi

# Get elapsed time of each test
WINETEST_WRAPPER=time
export WINETEST_WRAPPER

arg="$1"
shift
case "$arg" in
goodtests)   do_goodtests               ;;
badtests)    do_badtests .              ;;
flakytests)  do_badtests 'FLAKY|CRASHY' ;;
*) usage;;
esac