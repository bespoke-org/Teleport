#!/bin/sh
set -eu

if [ "$(id -u)" -ne 0 ]; then
    printf '%s\n' "This reset must run as root. Use: sudo sh scripts/reset_legacy_privileged_helper.sh" >&2
    exit 1
fi

LABEL='dev.x.teleport.PrivilegedHelper'
if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    printf '%s\n' "Booting out system/$LABEL"
    launchctl bootout "system/$LABEL"
else
    printf '%s\n' "No loaded service at system/$LABEL"
fi

remove_path() {
    path=$1
    printf '%s\n' "Removing $path"
    rm -rf -- "$path"
}

remove_path '/var/run/dev.x.teleport.helper.sock'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.xray'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.xray-assets'
remove_path '/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist'
remove_path '/var/db/dev.x.teleport'

printf '%s\n' 'Legacy Teleport privileged-helper state was removed.'
