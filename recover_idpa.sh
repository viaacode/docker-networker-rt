#!/usr/bin/env bash

# RecoveryArea must be set
[ -z "$RecoveryArea" ] && exit 1

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

if [ -n "$Time" -a "$Time" != 'null' ]; then
    echo "Got $Time"
    #RecoverOptions+=("-t '$(date -d "$Time" +%m/%d/%Y\ %H:%M:%S)'")
    #[ $? -eq 0 ] || exit 4
    echo "Setting recovery time to: $Time"
    Before+=("--before=$(date -d "$Time" '+%F %T') ")
fi

if [ "$Exclude" != 'null' ]; then
  ExcludeFile="/tmp/$$.$RANDOM"
  echo "Excluding $Exclude"
  echo $Exclude | jq -er '.[]' >$ExcludeFile
  trap "{ echo $ExcludeFile; }" EXIT
  RecoverOptions+=("--exclude-from=$ExcludeFile")
fi

RecoverOptions+=("--server=do-mgm-idpa-ava.do.viaa.be --path=/clients/$Host --id=$AvamarUser --ap=$AvamarPassword --target=$Destination --dereference --browse_filter_threshold_value=0")

function findbackup(){
  FileToFind=$1
  Basename=$(basename $FileToFind)
  echo "searching" $FileToFind

  BackupIds=( $(avtar --backups --server=do-mgm-idpa-ava.do.viaa.be --id=$AvamarUser --ap=$AvamarPassword --account=/clients/$Host $Before | tr -s ' ' | cut -d ' ' -f 4))

  # Remove first 2 lines of output
  unset BackupIds[0]
  unset BackupIds[1]

  BackupToRestore=-1

  echo $RecoverOptions

  for id in ${BackupIds[@]} 
  do
      echo "Searching in backup $id"
      BackupContent=( $(eval avtar --list --labelnum=$id --id=$AvamarUser --ap=$AvamarPassword --acnt=/clients/$Host --quiet) )
      for content in ${BackupContent[@]}
      do 
          if [ $content = "$FileToFind" ]; then
              echo "Found $File in $id"
              BackupToRestore=$id
              break 2
          fi
      done
  done
  if [[ $BackupToRestore -gt -1 ]]; then
      echo "Restoring backup with id $BackupToRestore"
      if [[ "$FileToFind" == */  ]]; then
        echo "ENDS WITH /"
        RecoverOptions+=(" --target=$Destination/$Basename ")
      fi
      eval avtar -x ${RecoverOptions[@]} $File --labelnum=$BackupToRestore
  else
      echo "Searched ${#BackupIds[@]} backups, but could not find $File. Aborting restore." 
      exit 5
  fi
}

Basename=$(basename $File)
echo "$RecoverOptions"
findbackup "$File"
RC=$?
# treat non-zero rc as warning, because it may be harmless
# for example, files that grew during backup
[ $RC -ne 0 ] && echo "Warning: recover ended with non-zero rc: $RC"
[ -e "$Destination/$Basename" ] || exit 5    # recovery failed
[ "$Uid" == "null" ] || chown -R  $Uid $Destination/$Basename


exit 0
