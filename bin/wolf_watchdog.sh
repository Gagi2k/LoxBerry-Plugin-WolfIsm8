#!/bin/bash

. $LBHOMEDIR/libs/bashlib/loxberry_log.sh

SCRIPTPATH=`dirname "$0"`;
PACKAGE=wolfism8
NAME=watchdog
LOGDIR=${LBPLOG}/${PACKAGE}

on_die()
{
        pkill -f wolf_ism8i.pl
        LOGEND "Server stopped"

        # Need to exit the script explicitly when done.
        # Otherwise the script would live on, until system
        # realy goes down, and KILL signals are send.
        #
        exit 0
}

trap 'on_die' TERM

LOGSTART "Server 'Wolf ISM8 Server' started"
starttime=`date +%s`
restart_counter=0
time_threshold=5
restart_threshold=5
until perl -X $SCRIPTPATH/wolf_ism8i.pl >> ${FILENAME} 2>&1; do
    LOGERR "Server 'Wolf ISM8 Server' crashed with exit code $?.  Respawning.." >&2
    stoptime=`date +%s`
    timediff=$((stoptime-starttime))
    if  ((restart_counter >= restart_threshold)); then
        LOGCRIT "Server crashed $restart_threshold times in a row! Stopping watchdog."
        LOGEND ""
        exit 1;
    fi
    if  ((timediff <= time_threshold)); then
        restart_counter=$((restart_counter+1));
        LOGWARN "Server crashed within $time_threshold Seconds.. Attempt: $restart_counter"
    else
        restart_counter=0
    fi
    sleep 5
    starttime=`date +%s`
done
