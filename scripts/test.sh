#!/bin/sh
# Everything CI runs: the unit tests, then the reference harness (the MCP
# server, its Remote Access listener and the launcher over real loopback
# sockets).
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
swift test
swift build --product bridgekit-reference-server
swift build --product bridgekit-reference-launcher
bin=$(swift build --show-bin-path)
export PYTHONPYCACHEPREFIX="$root/.build/pycache"
python3 Tests/harness/mcp_test.py "$bin/bridgekit-reference-server" Tests/harness/ReferenceServer/tools.json
python3 Tests/harness/remote_test.py "$bin/bridgekit-reference-server"
python3 Tests/harness/launcher_test.py "$bin/bridgekit-reference-launcher" "$bin/bridgekit-reference-server"
