#!/usr/bin/env bash
# Install Grafana Alloy as a standalone binary (NOT via apt) and run it under
# systemd --user as the current user. This is deliberate: the apt package
# runs Alloy as a system service under a dedicated `alloy` system user, which
# has no read access to $HOME/.claude/projects/*.jsonl. Running it as the
# invoking user under systemd --user avoids sudo entirely and matches file
# permissions on the JSONL transcripts it needs to tail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ALLOY_VERSION="v1.17.1"
INSTALL_DIR="$HOME/.local/bin"
CONFIG_DIR="$HOME/.config/alloy"
UNIT_DIR="$HOME/.config/systemd/user"
BIN_PATH="$INSTALL_DIR/alloy"

mkdir -p "$INSTALL_DIR" "$CONFIG_DIR" "$UNIT_DIR"

if [ -x "$BIN_PATH" ]; then
  echo "alloy binary already present at $BIN_PATH, skipping download"
else
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  url="https://github.com/grafana/alloy/releases/download/${ALLOY_VERSION}/alloy-linux-amd64.zip"
  echo "downloading $url"
  curl -fsSL -o "$tmp/alloy.zip" "$url"
  unzip -q -o "$tmp/alloy.zip" -d "$tmp"
  install -m 0755 "$tmp/alloy-linux-amd64" "$BIN_PATH"
  echo "installed alloy binary to $BIN_PATH"
fi

sed "s#__HOME__#${HOME}#g" "$REPO_ROOT/alloy/config.alloy.template" > "$CONFIG_DIR/config.alloy"
echo "wrote $CONFIG_DIR/config.alloy"

sed \
  -e "s#__ALLOY_BIN__#${BIN_PATH}#g" \
  -e "s#__CONFIG_DIR__#${CONFIG_DIR}#g" \
  "$REPO_ROOT/systemd/claude-alloy.service.template" > "$UNIT_DIR/claude-alloy.service"
echo "wrote $UNIT_DIR/claude-alloy.service"

systemctl --user daemon-reload
systemctl --user enable --now claude-alloy.service
echo "claude-alloy.service enabled and started"

linger="$(loginctl show-user "$(whoami)" -p Linger --value 2>/dev/null || echo no)"
if [ "$linger" != "yes" ]; then
  cat >&2 <<EOF

warning: lingering is not enabled for user '$(whoami)'.
  Without it, systemd --user (and claude-alloy.service) stops once your last
  login/terminal session ends, so log tailing pauses in the background.
  This requires root, so it is NOT run automatically. To fix, run:

    sudo loginctl enable-linger $(whoami)

EOF
fi
