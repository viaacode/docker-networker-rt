#!/usr/bin/env bash

function wait_for_networker_startup {
while ! pgrep -x nsrmmd >/dev/null; do
   echo 'waiting for nsrmmd'
   sleep 30
done
}

# Function bootstrap
# Parameters: bootstrapinfo, a string with format: "ssid,file,record,volume"
#
# This function recovers the networker server from a bootstrap save set.
# It:
#   - defines the device that contains the bootstrap saveset using the
#     resource file /bootstrapdevice.  This resource file must define a
#     read-only resource.
#   - recovers the bootstrap with the given bootstrapid using the mmrecov command.
#     (the 'nsrdr' command is not used because mmrecov allows to recover 
#     a subset of resources, hence resources that are not
#     available or not needed in the DR test environment can be 'masked'.

function bootstrap {

BootStrapId=${1%,*}
Volume=${1#*,}

# Create a networker resource for the DD device that contains the
# backup filesets and bootstraps
nsradmin -i /bootstrapdevice
wait_for_networker_startup

# recover the networker bootstrap with bootsrap id $1
# Supply the bootstrap ID with the necessary line feeds at stdin
mmrecov <<EOF
$BootStrapId



EOF

# Stop networker and copy a subset of resources needed for the DR test.
# This includes the NSR Client resources and the label and pool resources. 
# Don't copy device resource files, as our device must remain read-only.

/etc/init.d/networker stop

cd /nsr/res.R || exit 1

# Copy Media Pool Resources
# All Pool resources are copied, but note that recovery is restricted to the 
# pool containing our bootstrap device. (see below)
find . -type f -exec grep -q 'type: NSR pool' {} \;  -print | cpio -pvdm /nsr/res 
 
# Copy Label Templates
find . -type f -exec grep -q 'type: NSR label' {} \; -print | cpio -pvdm /nsr/res 

# Copy client resources except VBA
find . -type f -exec grep -q 'type: NSR client' {} \; \
    -not -exec grep -q 'VBA Server Host;' {} \; -print | cpio -pvdm /nsr/res

# Restart the networker server

/etc/init.d/networker start
wait_for_networker_startup

# Recover the client indexes
mminfo -q volume=$Volume -r client | sort -u | xargs  nsrck -L7 

}

########
#
# MAIN
#
########
# This script requires bootstrap info
# as a string with format: "ssid,file,record,volume"
[ -z "$1" ] && exit 1
BootStrapInfo=$1

echo "Bootstrap Info: $BootStrapInfo"

/etc/init.d/networker start
sleep 30

Volume=${BootStrapInfo#*,}
# only perform bootstrap recovery if our volume is not mounted
# this allows to restart a stopped container without losing state
nsrmm | grep mounted | grep -q $Volume || bootstrap $BootStrapInfo

# Find out to which pool our volume belongs
# Recovery will be restricted to filesets in this pool
Pool=$(mmpool $Volume | grep ^$Volume | cut -f2 -d ' ')

# Listen for incoming recover requests 
# use socat in stead of netcat casue the latter
# does not behave consistently between linux distributions
wait_for_networker_startup
echo "$HOSTNAME is open for recovery"
echo "Usage: echo <client> <path> <uid> | socat -,ignoreeof unix:$RECOVERY_SOCKET_PATH"

socat "$RECOVERY_SOCKET"  EXEC:"/recover.sh $Pool"
