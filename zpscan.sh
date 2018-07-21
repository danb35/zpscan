#! /usr/local/bin/bash
# Scan pool for failed disks and light failure LED
# Should work with Supermicro SAS2 backplanes, unknown if it will work in other environments
# https://github.com/danb35/zpscan

if [ ! "$1" ]; then
  echo "Usage: zpscan.sh pool [email]"
  echo "Scan a pool, send email notification and activate leds of failed drives"
  exit
fi
pool="$1"
basedir="/root/.sas2ircu"
drivesfile=$basedir/drives-$pool
locsfile=$basedir/locs-$pool
if [ ! -d $basedir ]; then
  mkdir $basedir
fi
touch $drivesfile
touch $locsfile
if [ "$2" ]; then
  email="$2"
else
  email="root"
fi
condition=$(/sbin/zpool status $pool | egrep -i '(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED|corrupt|cannot|unrecover)')
if [ "${condition}" ]; then
  glabel status | awk '{print "s|"$1"|"$3"\t\t\t      |g"}' > /tmp/glabel-lookup.sed
  emailSubject="`hostname` - ZFS pool - HEALTH fault"
  mailbody=$(zpool status $pool)
  echo "Sending email notification of degraded pool $pool"
  echo "$mailbody" | mail -s "Degraded pool $pool on `hostname`" $email
  drivelist=$(zpool status $pool | sed -f /tmp/glabel-lookup.sed | sed 's/p[0-9]//' | grep -E "(DEGRADED|FAULTED|OFFLINE|UNAVAIL|REMOVED|FAIL|DESTROYED)" | grep -vE "^\W+($pool|NAME|mirror|raidz|stripe|logs|spares|state)" | sed -E $'s/.*was \/dev\/([0-9a-z]+)/\\1/;s/^[\t  ]+([0-9a-z]+)[\t ]+.*$/\\1/')
  echo "Locating failed drives."
  for drive in $drivelist;
  do
    record=$(grep -E "^$drive" $drivesfile)
    location=$(echo $record | cut -f 3 -d " ")
    echo Locating: $record
    sas2ircu 0 locate $location ON
    if [ ! "$(egrep $location $locsfile)" ]; then
      echo $location >> $locsfile
    fi
  done
  rm /tmp/glabel-lookup.sed
else
  echo "Saving drive list."
  glabel status | awk '{print "s|"$1"|"$3"\t\t\t      |g"}' > /tmp/glabel-lookup.sed
  drivelist=$(zpool status $pool  | sed -f /tmp/glabel-lookup.sed | sed 's/p[0-9]//' | grep -E $'^\t  ' | grep -vE "^\W+($pool|NAME|mirror|raidz|stripe|logs|spares)" | sed -E $'s/^[\t ]+//;s/([a-z0-9]+).*/\\1/')
  saslist=$(sas2ircu 0 display)
  printf "" > $drivesfile
  for drive in $drivelist;
  do
    sasaddr=$(sg_vpd -i -q $drive 2>/dev/null | sed -E '2!d;s/,.*//;s/  0x//;s/([0-9a-f]{7})([0-9a-f])([0-9a-f]{4})([0-9a-f]{4})/\1-\2-\3-\4/')
    encaddr=$(echo "$saslist" | grep $sasaddr -B 2 | sed -E 'N;s/^.*: ([0-9]+)\n.*: ([0-9]+)/\1:\2/')
  echo $drive $sasaddr $encaddr >> $drivesfile
  done

  for loc in $(cat $locsfile);
  do
    sas2ircu 0 locate $loc OFF
  done
  printf "" > $locsfile
  rm /tmp/glabel-lookup.sed
fi
