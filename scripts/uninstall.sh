#!/usr/bin/env bash
# Removes Teleport's privileged helper from a machine the app may already be
# gone from. The same removal is available in Settings > General while the app
# is installed. Paths mirror Shared/PrivilegedHelperConstants.swift and the
# LaunchDaemon plist in teleport/HelperInstallation/PrivilegedHelperInstaller.swift;
# teleportTests/MachServiceInstallationTests.swift checks they stay in step.
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    exec sudo -p 'Administrator password to remove the Teleport helper: ' "$0" "$@"
fi

LABEL='dev.x.teleport.PrivilegedHelper'
PF_ANCHOR='com.apple/dev.x.teleport'

if launchctl print "system/$LABEL" >/dev/null 2>&1; then
    echo "Stopping system/$LABEL"
    launchctl bootout "system/$LABEL" || echo "Could not stop system/$LABEL; removing its files anyway" >&2
else
    echo "No loaded service at system/$LABEL"
fi

remove_path() {
    if [[ -e "$1" ]]; then
        echo "Removing $1"
        rm -rf -- "$1"
    else
        echo "Absent  $1"
    fi
}

remove_path '/Library/LaunchDaemons/dev.x.teleport.PrivilegedHelper.plist'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.PrivilegedHelper'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.xray'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.installation.json'
remove_path '/Library/PrivilegedHelperTools/dev.x.teleport.xray-assets'
remove_path '/var/db/dev.x.teleport'
remove_path '/var/log/teleport-privileged-helper.log'

# Staging directories of an install that was killed before its cleanup ran.
for staging in /Library/PrivilegedHelperTools/.teleport-install.*; do
    [[ -e "$staging" ]] && remove_path "$staging"
done

echo "Flushing pf anchor $PF_ANCHOR"
/sbin/pfctl -a "$PF_ANCHOR" -F all >/dev/null 2>&1 || echo "No pf rules under $PF_ANCHOR"

cat <<'EOF'

Teleport's privileged helper is removed.

Left in place, per user, for you to remove if you want nothing of Teleport kept:
  ~/Library/Application Support/teleport/   (encrypted connections and settings, logs, downloaded geodata)
  Keychain item "dev.x.teleport.configuration"   (the key they are encrypted with; Keychain Access or:
      security delete-generic-password -s dev.x.teleport.configuration)
  Login item "Teleport"   (System Settings > General > Login Items, if it was enabled)
EOF
