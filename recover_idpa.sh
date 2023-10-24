#!/usr/bin/env bash

# Environment must be set
[ -z "$RecoveryArea" ] && exit 1
[ -z "$AvamarUser" ] && exit 7
[ -z "$AvamarPassword" ] && exit 8

# wait for incoming recovery request at stdin
read -r JsonObject
Host=$(echo $JsonObject | jq -er .client)  || exit 2
File=$(echo $JsonObject | jq -er .path) || exit 3
Uid=$(echo $JsonObject | jq -er .uid)
Time=$(echo $JsonObject | jq -er .time)
Exclude=$(echo $JsonObject | jq -er .exclude)

echo "$(date '+%m/%d %H:%M:%S'): starting recovery $Host $File $Uid $Time"
[ -z "$Host" ] || [ -z "$File" ] && exit 2
[ "$File" == "null" ] && exit 2 # Do not restore null

Destination=$RecoveryArea/$Host
[ -d $Destination ] || mkdir $Destination
[ $(stat -c %g $Destination) -eq $RecoveryAreaGid ] || chgrp $RecoveryAreaGid $Destination
[ $(stat -c %a $Destination) -eq 0770 ] || chmod 0770 $Destination

function findbackup(){
  FileToFind=$1
  if [ "$Exclude" != 'null' ]; then
    ExcludeFile="/tmp/$$.$RANDOM"
    echo "Excluding $Exclude"
    echo $Exclude | jq -er '.[]' >$ExcludeFile
    trap "{ echo $ExcludeFile; }" EXIT
    RecoverOptions+=("--exclude-from=$ExcludeFile")
  fi

  # If Time is given, it is the RPO: the data must be recovered as it was at
  # the time of $Time, or before.
  if [ -n "$Time" -a "$Time" != 'null' ]; then
      RPOEpoch=$(date -d "$Time" +%s) # Set RPO to current date if $Time is not set
  else
      RPOEpoch=$(date +%s)
  fi
  RPO="--before=\"$(date -d @$RPOEpoch '+%F %T')\""

  # Only search in backups that are younger then 36 h before the RPO
  # This is for performance reasons on the idpa.
  # Could be improved by using the idpa search index, eg.
  # - first search in index
  # - of not found, search using avtar but only in backups taken since latest
  #   index update
  AfterEpoch=$((RPOEpoch - 36*3600))
  After="--after=\"$(date -d @$AfterEpoch '+%F %T')\""

  AvtarOptions="--server=do-mgm-idpa-ava.do.viaa.be --account=/clients/$Host \
      --id=$AvamarUser --ap=$AvamarPassword"
  RecoverOptions+=("$AvtarOptions" "--target=$Destination" --dereference
      "--browse_filter_threshold_value=0")
  Basename=$(basename $FileToFind)
  echo "searching $FileToFind in backups" 

  BackupToRestore=-1
  # The recover API's contract when restoring a file or directory is to recover
  # the most recent version of that file or directory before or at the given RPO.
  # A backup set in the idpa always contain the complete directory hierarchy
  # towards the file or directory being backed up. When listing the contents of
  # a backupset, the complete hierarchy is listed. When looking for a backup of
  # a given directory, the directory will be listed in all backupsets that
  # contain flies in a subdirectory of the given directory. Restoring the
  # directory from such a backup set results in the resroe of an empty
  # directory because the backupset does nonly contain data of the files in the
  # subdirectories that were backed up.
  # This is a problem for the postgres backups. Because the transactions logs
  # live in a subdirectory of the database files (pg_wal), the database
  # directory is listed in all backups of the transaction logs. When looking to
  # restore a database, the first backup found will most probably be a backup of
  # the transaction logs and hence will contain no data.
  # In order to avoid this, we first look for a backupset which has the
  # directory mentionned as backup target. Only when it is not found there, we
  # start looking in the contents of all backup sets. 
  Target=( $(avtar --backups $AvtarOptions "$RPO" "$After" | \
      sed -r 's/[0-9-]+ +[[0-9:]+ +([0-9]+).*(Linux|Unix) +([^ ]+) +([^ ]+).*/\1 \3 \4/' | \
      while read id wd tgt; do
          expr "$tgt" : '/' >/dev/null && echo "$id $tgt" || echo "$id $wd/$tgt"
      done | egrep "[ ,]${FileToFind%/}(,|$)" | head -1) )
  if [ -n "$Target" ]; then
      WorkDir=$(avtar --backups $AvtarOptions --labelnum=$Target | \
          sed -rn "s/ *[0-9-]+ +[[0-9:]+ +$Target .*(Linux|Unix) +([^ ]+) +([^ ]+).*/\2/p")/
      FileToRestore=${FileToFind#$WorkDir}
      BackupToRestore=$Target
  else
      FileToRestore="${FileToFind}"
      BackupIds=( $(avtar --backups $AvtarOptions "$RPO" "$After" | tr -s ' ' | \
          cut -d ' ' -f 4))
      # Remove first 2 lines of output
      unset BackupIds[0]
      unset BackupIds[1]
      for id in ${BackupIds[@]} 
      do
          echo "Searching in backup $id"
          BackupContent=( $(avtar --list --labelnum=$id $AvtarOptions --quiet) )
          for content in ${BackupContent[@]}
          do 
              if [ $content = "$FileToFind" ]; then
                  echo "Found $File in $id"
                  BackupToRestore=$id
                  break 2
              fi
          done
      done
  fi
  # Restore the requested file/directory from the given Backupset
  # We recover the complete parent directory (dirname) as a way of prefetching.
  # This speeds up possible subsequent recovers of files from the same
  # directory.
  if [[ $BackupToRestore -gt -1 ]]; then
      echo "Restoring backup with id $BackupToRestore"
      if [[ "$FileToFind" == */  ]]; then
        echo "ENDS WITH /"
        RecoverOptions+=(" --target=$Destination/$Basename ")
      else
          FileToRestore=$(dirname $FileToRestore)
      fi
      avtar -x ${RecoverOptions[@]} $FileToRestore --labelnum=$BackupToRestore
  else
      echo "Searched ${#BackupIds[@]} backups, but could not find $File. Aborting restore." 
      exit 5
  fi
}

Basename=$(basename $File)
# Recover file if it has not been prefetched
[ -r "$Destination/$Basename" ] && [ "$File" != */  ] || findbackup "$File"
RC=$?
# treat non-zero rc as warning, because it may be harmless
# for example, files that grew during backup
[ $RC -ne 0 ] && echo "Warning: recover ended with non-zero rc: $RC"
[ -e "$Destination/$Basename" ] || exit 5    # recovery failed
[ "$Uid" == "null" ] || chown -R  $Uid $Destination/$Basename

exit 0
