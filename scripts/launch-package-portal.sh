#!/usr/bin/bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/lib.sh
source "$script_dir/lib.sh"

"$script_dir/check.sh" --package-prefix /usr --require-production

resolve_xdg_paths "" "" "" "" ""
portal_env=$config_dir/portal.env
export XENEON_EDGE_OUTPUT
export XENEON_EDGE_SERIAL
export XENEON_EDGE_MODEL
XENEON_EDGE_OUTPUT=$(portal_env_value "$portal_env" XENEON_EDGE_OUTPUT)
XENEON_EDGE_SERIAL=$(portal_env_value "$portal_env" XENEON_EDGE_SERIAL)
XENEON_EDGE_MODEL=$(portal_env_value "$portal_env" XENEON_EDGE_MODEL)

exec /usr/bin/quickshell \
  --no-duplicate \
  --path /usr/share/xeneon-edge-agents/quickshell
