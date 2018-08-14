#!/usr/bin/env bash

function wait_for_storage_node {
while ! pgrep -x nsrmmd >/dev/null; do
   echo 'waiting for nsrmmd'
   sleep 30
done
}

# Function bootstrap
# Parameters: bootstrapinfo, a string with format: "ssid,volume,device"
# Environment variable: LockBoxPassPhrase
#
# This function recovers the networker server from a bootstrap save set.
# It:
#   - defines the device that contains the bootstrap saveset using the
#     resource file /bootstrapdevice.  This resource file should define a
#     read-only resource.
#   - recovers the bootstrap with the given bootstrapid
#   - disables the workfows
#   - disables all devices, except the device containing the bootstrap

function bootstrap {

BootStrapId=${1%,*}
Volume=${1#*,}

Device=$(sed -r -n -e  's/^\s+name:\s*([^;]+);/\1/p' /bootstrapdevice )

# Create a networker resource for the device containing the
# backup filesets and bootstraps
nsradmin -i /bootstrapdevice
wait_for_storage_node


TERM=xterm nsrdr -a -B $BootStrapId  -d $Device -v

# Disable all workflows
nsrpolicy policy list |\
    while read -r pol; do
        nsrpolicy workflow list -p "$pol" |\
            while read -r wfl; do
                nsrpolicy workflow update -p "$pol" -w "$wfl" -u No -E No
            done
        done

# Recreate the lockbox and restart networker, in order to avoid the following
# error:
# nsrd RAP critical Error encountered while re-signing lockbox
# '/nsr/lockbox/dg-mgm-bkp-01.dg.viaa.be/clb.lb': The Lockbox stable value
# threshold was not met because the system fingerprint has changed. To reset 
# the system fingerprint, open the Lockbox using the passphrase
LBScript=/LB.$(date '+%N')
cat >$LBScript <<EOF
option hidden

delete type:NSR lockbox

create type:NSR lockbox;
name: $HOSTNAME;
client: $HOSTNAME;
users: "user=root,host=$HOSTNAME", "user=administrator,host=$HOSTNAME", "user=system,host=$HOSTNAME";
external roles: ;
hostname: $HOSTNAME;
administrator: "user=root,host=$HOSTNAME", "user=administrator,host=$HOSTNAME", "user=system,host=$HOSTNAME";

. type:NSR
update datazone pass phrase:$LockBoxPassPhrase
EOF

nsradmin -i $LBScript
rm -f $LBScript

/etc/init.d/networker stop

# Disable devices and delete vproxies
nsradmin -d /nsr/res/nsrdb -i /mask_devices.nsradmin

# Re-enable our Disaster Recovery Device (read only)
nsradmin -d /nsr/res/nsrdb <<EOF
. name:$Device
update enabled:Yes
y
EOF

/etc/init.d/networker start
wait_for_storage_node

# Recover the client indexes
# Restrict recovery to indexes available on our disaster recovery volume
# use the -t option of nsrck to prevent it from trying
# to restore a more recent index that might be present on another volume 
mminfo -q volume=$Volume -r client | sort -u |\
    while read -r client; do
        SaveTime=$(mminfo -v -ot -N "index:$client" -q level=full -r 'savetime(22)' $Volume | tail -1)
        nsrck -L7 -t "$SaveTime" $client
    done
}

########
#
# MAIN
#
########
# This script requires bootstrap info
# as a string with format: "ssid,volume"
[ -z "$1" ] && exit 1

# LockBoxPassPhrase must be set
[ -z "$LockBoxPassPhrase" ] && exit 2

BootStrapInfo=$1

Volume=${BootStrapInfo#*,}

echo "Bootstrap Info: $BootStrapInfo"

# Render nsr logs to container stderr
mkfifo /tmp/daemon.raw
tail -F /nsr/logs/daemon.raw >/tmp/daemon.raw &
nsr_render_log /tmp/daemon.raw >&2 &

/etc/init.d/networker start

# Wait for media database to get ready
sleep 30
 
# only perform bootstrap recovery if our volume is not mounted
# this allows to restart a stopped container without losing state
nsrmm | grep mounted | grep -q $Volume || bootstrap $BootStrapInfo

# Find out to which pool our volume belongs
# Recovery will be restricted to filesets in this pool
Pool=$(mmpool $Volume | grep ^$Volume | cut -f2 -d ' ')

wait_for_storage_node

# Listen for incoming recover requests 
# use socat in stead of netcat casue the latter
# does not behave consistently between linux distributions

echo "$HOSTNAME is open for recovery"
echo "Listening on $(expr match "$RecoverySocket" '\([^,]\+\)')"
echo "Usage: echo <client> <path> <uid> | socat -,ignoreeof <socket>"

socat "$RecoverySocket"  EXEC:"/recover.sh $Pool"
