#! /usr/local/bin/bash
# Scan pool for failed disks and light failure LED
# Should work with Supermicro SAS2 backplanes, unknown if it will work in other environments
# https://github.com/danb35/zpscan

# Possible failure conditions:
# -Unable to detect the correct LED if a failure happens before the first problem-free run after boot
# -Unable to light fault LED if controller cannot see the drive
# -Assumes drive serial numbers are unique in a system

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
    controller=$(echo $record | cut -f 3 -d " ")
    encaddr=$(echo $record | cut -f 4 -d " ")
    echo Locating: $record
    sas2ircu $controller locate $encaddr ON
    # Add to list of enabled LEDs
    if [ $(egrep "$controller $encaddr" $locsfile | wc -c) -eq 0 ]; then
      echo $controller $encaddr >> $locsfile
    fi
  done
  rm /tmp/glabel-lookup.sed
else
  echo "Saving drive list."
  glabel status | awk '{print "s|"$1"|"$3"\t\t\t      |g"}' > /tmp/glabel-lookup.sed
  drivelist=$(zpool status $pool | sed -f /tmp/glabel-lookup.sed | sed 's/p[0-9]//' | grep -E $'^\t  ' | grep -vE "^\W+($pool|NAME|mirror|raidz|stripe|logs|spares)" | sed -E $'s/^[\t ]+//;s/([a-z0-9]+).*/\\1/')
  controllerlist=$(sas2ircu list | grep -E ' [0-9]+ ' | sed -E $'s/^[\t ]+//;s/([0-9]+).*/\\1/')
  printf "" > $drivesfile
  # Go through each controller and check if the drive is attached to that controller
  for controller in $controllerlist;
  do
    saslist=$(sas2ircu $controller display)
    for drive in $drivelist;
    do
      # "diskinfo -s disk" and "camcontrol identify [device id] -S" should be equivalent
      # WD disks have a WD- prefix that sas2ircu does not show, so we remove it
      serial=$(diskinfo -s /dev/$drive 2>/dev/null | sed -E 's/^WD-//;s/[\t ]+//')
      encaddr=$(echo "$saslist" | grep "$serial" -B 8 | sed -E '1!d;N;s/^.*: ([0-9]+)\n.*: ([0-9]+)/\1:\2/')
      # Add to list of mappings
      if [ "${encaddr}" ]; then
        echo $drive $serial $controller $encaddr >> $drivesfile
      fi
    done
  done

  # Turn off all enabled LEDs
  while IFS= read -r loc;
  do
    controller=$(echo "$loc" | cut -f 1 -d " ")
    encaddr=$(echo "$loc" | cut -f 2 -d " ")
    sas2ircu $controller locate $encaddr OFF
  done < $locsfile
  printf "" > $locsfile
  rm /tmp/glabel-lookup.sed
fi
