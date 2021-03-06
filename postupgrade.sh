#!/bin/sh

# To use important variables from command line use the following code:
COMMAND=$0    # Zero argument is shell command
PTEMPDIR=$1   # First argument is temp folder during install
PSHNAME=$2    # Second argument is Plugin-Name for scipts etc.
PDIR=$3       # Third argument is Plugin installation folder
PVERSION=$4   # Forth argument is Plugin version
#LBHOMEDIR=$5 # Comes from /etc/environment now. Fifth argument is
              # Base folder of LoxBerry

# Combine them with /etc/environment
PCGI=$LBPCGI/$PDIR
PHTML=$LBPHTML/$PDIR
PTEMPL=$LBPTEMPL/$PDIR
PDATA=$LBPDATA/$PDIR
PLOG=$LBPLOG/$PDIR # Note! This is stored on a Ramdisk now!
PCONFIG=$LBPCONFIG/$PDIR
PSBIN=$LBPSBIN/$PDIR
PBIN=$LBPBIN/$PDIR

echo "<INFO> Copy back existing config files /tmp/${PDIR}.SAVE/* $PCONFIG/"
cp -v -r /tmp/${PDIR}.SAVE/* $PCONFIG/

echo "<INFO> Remove temporary folder /tmp/${PDIR}.SAVE"
rm -rf /tmp/${PDIR}.SAVE

enabled=`awk -F'[ ]' '/enable/{print $2}' $PCONFIG/wolf_ism8i.conf`

if [ "$enabled" -eq "1" ]; then
    # Enable
    echo "<INFO> Restarting server"
    $PBIN/wolf_server restart > /dev/null 2>&1
fi

# Exit with Status 0
exit 0
