#!/usr/bin/env bash
# RECOVERY_AREA must be set
[ -z "$RECOVERY_AREA" ] && exit 1
Pool="$1"

pgrep -x recover >/dev/null && echo "$(date '+%m/%d %H:%M:%S'): anoher recovery session is runnig, waiting..."
while pgrep -x recover >/dev/null ; do
    sleep 10
done

read -r JsonObject
Host=$(echo $JsonObject | jq -er .client)  || exit 2
File=$(echo $JsonObject | jq -er .path) || exit 3
Uid=$(echo $JsonObject | jq -er .uid)
Time=$(echo $JsonObject | jq -er .time)
Exclude=$(echo $JsonObject | jq -er .exclude)

echo "$(date '+%m/%d %H:%M:%S'): starting recovery $Host $File $Uid $Time"

[ -z "$Host" ] || [ -z "$File" ] && exit 2

echo $Host $File $Uid $Time

Basename=$(basename $File)
Dirname=$(dirname $File)
Destination=$RECOVERY_AREA/$Host

RecoverOptions=( -iY -a "-c $Host" "-d $Destination" )
[ -n "$Pool" ] && RecoverOptions+=("-b $Pool")

if [ "$Time" != 'null' ]; then
    RecoverOptions+=("-t '$(date -d $Time +%m/%d/%Y\ %H:%M:%S)'")
    [ $? -eq 0 ] || exit 4
fi

if [ "$Exclude" != 'null' ]; then
  ExcludeFile="/tmp/$$.$RANDOM"
  echo $Exclude | jq -er '.[]' >$ExcludeFile
  RecoverOptions+=("-e $ExcludeFile")
fi

eval recover ${RecoverOptions[@]} $File
RC=$?
# treat non-zero rc as warning, because it may be harmless
# for example, files that grew during backup
[ $RC -ne 0 ] && echo "Warning: recover ended with non-zero rc: $RC"

[ "$Uid" != "null" ] && [ -e "$Destination/$Basename" ] && chown -R  $Uid $Destination/$Basename

# If recoverd file is a symlink, also recover the file it points to
if [ -L "$Destination/$Basename" ]; then
  Target=$(readlink "$Destination/$Basename")
  # Resolve relative path names
  [ ${Target:0:1} == '/' ] || Target=$Dirname/$Target
  eval recover ${RecoverOptions[@]} $Target
  [ "$Uid" != "null" ] && [ -e "$Destination/$Target" ] && chown -R  $Uid $Destination/$Target
fi

[ -n "$ExcludeFile" ] && rm $ExcludeFile
