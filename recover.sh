#!/usr/bin/env bash

# RecoveryArea must be set
[ -z "$RecoveryArea" ] && exit 1
# This command can be used to recover files in a disaster recovery environment.
# Such an environment typically does not have access to all storage pools.
# When the Pool parameter is sepcified, recovery will be restricted to 
# this Pool.
Pool="$1"

read -r JsonObject
Host=$(echo $JsonObject | jq -er .client)  || exit 2
File=$(echo $JsonObject | jq -er .path) || exit 3
Uid=$(echo $JsonObject | jq -er .uid)
Time=$(echo $JsonObject | jq -er .time)
Exclude=$(echo $JsonObject | jq -er .exclude)

echo "$(date '+%m/%d %H:%M:%S'): starting recovery $Host $File $Uid $Time"

[ -z "$Host" ] || [ -z "$File" ] && exit 2

echo $Host $File $Uid $Time

Destination=$RecoveryArea/$Host

[ -d $Destination ] || mkdir $Destination
[ $(stat -c %g $Destination) -eq 4 ] || chgrp $RecoveryAreaGid $Destination
[ $(stat -c %a $Destination) -eq 0770 ] || chmod 0770 $Destination

RecoverOptions=( -iY -a "-c $Host" "-d $Destination" )
if [ -n "$Pool" ]; then
    # Adding the -b option to the recover command will make it fail immediately
    # when a file is not found in the specified Pool, rather than waiting for a
    # pool that is not available in the recovery environemnt.  
    RecoverOptions+=("-b $Pool")
    # Even when the -b option is set, the recover command will try to restore
    # from another pool if that pool contains a more recent version.
    # Setting Time to the time of the most recent saveset in our Pool avoids
    # recovery failure due to other pools, not available in the recovery
    # environment, containing a more recent version of the file to be restored.
    if [ -z "$Time" -o "$Time" == 'null' ]; then
        Time=$(mminfo -c $Host -ot -q "pool=$Pool" -r  'savetime(17)' | tail -1)
        echo "Setting recovery time to the savetime of the most recent saveset in pool $Pool: $Time"
    fi
fi

if [ -n "$Time" -a "$Time" != 'null' ]; then
    RecoverOptions+=("-t '$(date -d "$Time" +%m/%d/%Y\ %H:%M:%S)'")
    [ $? -eq 0 ] || exit 4
    echo "Setting recovery time to: $Time"
fi

if [ "$Exclude" != 'null' ]; then
  ExcludeFile="/tmp/$$.$RANDOM"
  echo $Exclude | jq -er '.[]' >$ExcludeFile
  trap "{ echo $ExcludeFile; rm -f $ExcludeFile; }" EXIT
  RecoverOptions+=("-e $ExcludeFile")
fi

# Recursive recover for symbolic links
function nrwrecover {
 Basename=$(basename $File)
 eval recover ${RecoverOptions[@]} $File
 RC=$?
 # treat non-zero rc as warning, because it may be harmless
 # for example, files that grew during backup
 [ $RC -ne 0 ] && echo "Warning: recover ended with non-zero rc: $RC"

 [ -e "$Destination/$Basename" ] || exit 5    # recovery failed
 [ "$Uid" == "null" ] || chown -R  $Uid $Destination/$Basename

 # If recoverd file is a symlink, also recover the file it points to
 if [ -L "$Destination/$Basename" ]; then
   Dirname=$(dirname $File)
   $File=$(readlink "$Destination/$Basename")
   # Resolve relative path names
   [ ${File:0:1} == '/' ] || File=$Dirname/$File
   nrwrecover
 fi
}

nrwrecover

exit 0
