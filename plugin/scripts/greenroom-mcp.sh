#!/bin/sh
# Starts Greenroom's MCP server (`Greenroom --mcp`, a stdio shim that passes each message to the running app and
# starts the app in the background if it is not open) from wherever Greenroom.app is installed. The plugin's
# manifest runs this; the finding is done by the plugin's `greenroom` command (../bin/greenroom), which says where
# it looks ($GREENROOM_APP, /Applications, ~/Applications, Spotlight) and what $GREENROOM_MCP_ARGS is for.
#
# exec, so the shim's parent is still the agent: the app ties the connection to the agent's worktree by that.
exec /bin/sh "$(dirname "$0")/../bin/greenroom" mcp
