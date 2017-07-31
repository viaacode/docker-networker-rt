#!/usr/bin/env bash
# RECOVERY_AREA must be set
#[ -z "$RECOVERY_AREA" ] && exit 1
Pool="$1"

pgrep -x recover >/dev/null && echo "$(date '+%m/%d %H:%M:%S'): anoher recovery session is runnig, waiting..."
while pgrep -x recover >/dev/null ; do
    sleep 10
done 

read -r Host File Uid
echo "$(date '+%m/%d %H:%M:%S'): starting recovery $Host $File $Uid"

[ -z "$Host" ] || [ -z "$File" ] && exit 2

Basename=$(basename $File)
Dirname=$(dirname $File)
Destination=$RECOVERY_AREA/$Host

RecoverOptions=( -iY -a "-c $Host" "-d $Destination" )
[ -n "$Pool" ] && RecoverOptions+=("-b $Pool")
[ -r $Destination/exclude.lst ] && RecoverOptions+=("-e $Destination/exclude.lst")
recover ${RecoverOptions[@]} $File

RC=$?
# treat non-zero rc as warning, because it may be harmless
# for example, files that grew during backup
[ $RC -ne 0 ] && echo "Warning: recover ended with non-zero rc: $RC"

[ -n "$Uid" ] && [ -e "$Destination/$Basename" ] && chown -R  $Uid $Destination/$Basename

# If recoverd file is a symlink, also recover the file it points to
if [ -L "$Destination/$Basename" ]; then
  Target=$(readlink "$Destination/$Basename")
  # Resolve relative path names
  [ ${Target:0:1} == '/' ] || Target=$Dirname/$Target
  recover ${RecoverOptions[@]} $Target
  [ -n "$Uid" ] && [ -e "$Destination/$Target" ] && chown -R  $Uid $Destination/$Target
fi

