#!/usr/bin/env bash

function wait_for_storage_node {
echo 'Waiting for strorage node'
tail -0f /nsr/logs/daemon.raw | while read -r line ; do
  [ $(expr "$line" : '.*nsrsnmd process on storage node .*s changed its state .* SNMD_READY') -gt 0 ] && break
done
echo 'Strorage node is ready'
}

function wait_for_media_database {
echo 'Waiting for media database'
tail -0f /nsr/logs/daemon.raw | while read -r line ; do
  [ $(expr "$line" : '.*Media database is open for business') -gt 0 ] && break
done
echo 'Media database is ready'
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

echo "$(date) Import device containing the backup filesets and bootstraps"
nsradmin -i /bootstrapdevice

wait_for_storage_node

echo "$(date) Starting disaster recovery'"
TERM=xterm nsrdr -a -B $BootStrapId  -d $Device -v

echo "$(date) Disable all workflows"
nsrpolicy policy list |\
    while read -r pol; do
        nsrpolicy workflow list -p "$pol" |\
            while read -r wfl; do
                nsrpolicy workflow update -p "$pol" -w "$wfl" -u No -E No
            done
        done

# Recreate the lockbox and restart networker, in order to avoid the following
# error:
# Unable to query NSR database for list of configured devices:
#   Unable to decrypt data: error:06065064:digital envelope routines:
#   EVP_DecryptFinal_ex:bad decrypt
#   The result is that the index recovery after the bootstrap are tried from a
#   device that is noy available in the DR environment.
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

echo "$(date) Stopping networker"
/etc/init.d/networker stop

echo "$(date) Disable devices, set them read-only and delete vproxies"
# Most devices are not avaliable in the DR environment
# and the DR instnace of networker must not have write access to
# any of them.
nsradmin -d /nsr/res/nsrdb -i /mask_devices.nsradmin

echo "$(date) Re-enable our Disaster Recovery Device"
# It has been set read only by the command above
nsradmin -d /nsr/res/nsrdb <<EOF
. name:$Device
update enabled:Yes
y
EOF

echo
/etc/init.d/networker start
wait_for_storage_node
sleep 30
# Recover the client indexes
# Restrict recovery to indexes available on our disaster recovery volume
# use the -t option of nsrck to prevent it from trying
# to restore a more recent index that might be present on another volume 
# that is not available in the DR environment.
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

echo "$(date) Bootstrap Info: $BootStrapInfo"

# Render nsr logs to container stderr
mkfifo /tmp/daemon.raw
tail -F /nsr/logs/daemon.raw >/tmp/daemon.raw &
nsr_render_log /tmp/daemon.raw >&2 &

/etc/init.d/networker start

# only perform bootstrap recovery if our volume is not mounted
# this allows to restart a stopped container without losing state
wait_for_media_database
if nsrmm | grep mounted | grep -q $Volume; then
  wait_for_storage_node
else
  bootstrap $BootStrapInfo
fi

# Find out to which pool our volume belongs
# Recovery will be restricted to filesets in this pool
# this avoids recovery attempts from devices that are disabled 
# or not avaibale in the DR environment
Pool=$(mmpool $Volume | grep ^$Volume | cut -f2 -d ' ')

# Listen for incoming recover requests 
# use socat in stead of netcat casue the latter
# does not behave consistently between linux distributions

echo "$(date) $HOSTNAME is open for recovery"
echo "Listening on $(expr match "$RecoverySocket" '\([^,]\+\)')"
echo "Usage: echo <client> <path> <uid> | socat -,ignoreeof <socket>"

socat "$RecoverySocket"  EXEC:"/recover.sh $Pool"
