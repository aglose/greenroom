#!/bin/sh
# Starts Greenroom's MCP server (`Greenroom --mcp`, a stdio shim that passes each message to the running app and
# starts the app in the background if it is not open) from wherever Greenroom.app is installed.
#
# Looked for, in order:
#   1. $GREENROOM_APP, when set: the path of a Greenroom.app (a build of your own, or a check's).
#   2. /Applications/Greenroom.app, then ~/Applications/Greenroom.app
#   3. Spotlight, by bundle id (io.github.aglose.greenroom)
#
# $GREENROOM_MCP_ARGS, when set, is added to the command line (split on spaces). Greenroom's own checks set it to
# --agent-check, which with GREENROOM_STATE gives the app a state folder of its own; leave it unset otherwise.
BUNDLE_ID=io.github.aglose.greenroom

fail() {
  echo "greenroom: $1" >&2
  exit 1
}

program() { # APP: its executable, if it is there
  [ -x "$1/Contents/MacOS/Greenroom" ] && echo "$1/Contents/MacOS/Greenroom"
}

first_installed() { # paths of apps on stdin: the program of the first that has one
  # Spotlight may list several copies. Skipped: one macOS runs from a temporary place (App Translocation), one on
  # a mounted disk image, one in the Trash. Those paths stop existing.
  while IFS= read -r app; do
    case "$app" in
      */AppTranslocation/* | /Volumes/* | */.Trash/*) continue ;;
    esac
    program "$app" && return 0
  done
  return 1
}

exe=
if [ -n "${GREENROOM_APP:-}" ]; then
  exe=$(program "${GREENROOM_APP%/}") || fail "GREENROOM_APP is set to $GREENROOM_APP, which is not a Greenroom.app (no Contents/MacOS/Greenroom in it)."
else
  for app in /Applications/Greenroom.app "$HOME/Applications/Greenroom.app"; do
    exe=$(program "$app") && break
  done
  if [ -z "$exe" ] && command -v mdfind >/dev/null 2>&1; then
    exe=$(mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | first_installed)
  fi
  [ -n "$exe" ] || fail "Greenroom.app was not found in /Applications, in ~/Applications or by Spotlight. Install Greenroom (https://github.com/aglose/greenroom/releases), move it to Applications and open it once; or set GREENROOM_APP to the path of your Greenroom.app."
fi

# exec, so the shim's parent is still the agent: the app ties the connection to the agent's worktree by that.
# shellcheck disable=SC2086
exec "$exe" --mcp ${GREENROOM_MCP_ARGS:-}
