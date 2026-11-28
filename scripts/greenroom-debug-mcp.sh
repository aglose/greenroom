#!/bin/sh
# Starts Greenroom Debug's MCP server for an agent working in this repository or one of its worktrees. The
# repository's .mcp.json runs it, so the Debug copy (the build for developing Greenroom itself) is offered here and
# in no other project: an agent testing an Android app elsewhere only ever has the release copy's `greenroom` server.
#
# Looked for, in order:
#   1. $GREENROOM_DEBUG_APP, when set: the path of a Greenroom Debug.app.
#   2. /Applications/Greenroom Debug.app, then ~/Applications/Greenroom Debug.app: the installed copy.
#   3. build/Greenroom Debug.app in this checkout: what scripts/bundle.sh --variant debug makes.
#
# $GREENROOM_MCP_ARGS, when set, is added to the command line (Greenroom's own checks set it to --agent-check).
here=$(cd "$(dirname "$0")/.." && pwd)

program() { # APP: its executable, if it is there
  [ -x "$1/Contents/MacOS/Greenroom" ] && echo "$1/Contents/MacOS/Greenroom"
}

exe=
if [ -n "${GREENROOM_DEBUG_APP:-}" ]; then
  exe=$(program "${GREENROOM_DEBUG_APP%/}") || {
    echo "greenroom-debug: GREENROOM_DEBUG_APP is set to $GREENROOM_DEBUG_APP, which is not a Greenroom Debug.app (no Contents/MacOS/Greenroom in it)." >&2
    exit 1
  }
else
  for app in "/Applications/Greenroom Debug.app" "$HOME/Applications/Greenroom Debug.app" "$here/build/Greenroom Debug.app"; do
    exe=$(program "$app") && break
  done
  [ -n "$exe" ] || {
    echo "greenroom-debug: Greenroom Debug.app was not found in /Applications, in ~/Applications or in this checkout's build folder. Build it with scripts/bundle.sh --variant debug, or set GREENROOM_DEBUG_APP to its path." >&2
    exit 1
  }
fi

# exec, so the shim's parent is still the agent: the app ties the connection to the agent's worktree by that.
# shellcheck disable=SC2086
exec "$exe" --mcp ${GREENROOM_MCP_ARGS:-}
