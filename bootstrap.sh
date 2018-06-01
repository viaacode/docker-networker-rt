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
Device=$(sed -r -n -e  's/^\s+name:\s*([^;]+);/\1/p' /bootstrapdevice )

# Create a networker resource for the device containing the
# backup filesets and bootstraps
nsradmin -i /bootstrapdevice
wait_for_networker_startup


nsrdr -a -B $BootStrapId  -d $Device -v

# Unmount all volumes
/usr/sbin/nsrmm -u -y

# Disable all workflows
nsrpolicy policy list |\
    while read -r pol; do
        nsrpolicy workflow list -p "$pol" |\
            while read -r wfl; do
                nsrpolicy workflow update -p "$pol" -w "$wfl" -u No -E No
            done
        done

# Disable devices and delete vproxies
nsradmin -i /mask_devices.nsradmin

# Re-enable and mount our Disaster Recovery Device
nsradmin <<EOF
. name:$Device
update enabled:Yes
y
EOF
/usr/sbin/nsrmm -m $Volume -f $Device -r

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
set -x

BootStrapInfo=$1
Volume=${BootStrapInfo#*,}

echo "Bootstrap Info: $BootStrapInfo"

/etc/init.d/networker start
sleep 30

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
echo "Listening on $(expr match "$RecoverySocket" '\([^,]\+\)')"
echo "Usage: echo <client> <path> <uid> | socat -,ignoreeof <socket>"

socat "$RecoverySocket"  EXEC:"/recover.sh $Pool"
