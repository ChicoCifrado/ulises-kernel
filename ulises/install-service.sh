#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_FILE="$SCRIPT_DIR/ulises-ui.service"

if [ ! -f "$SERVICE_FILE" ]; then
  echo "Error: ulises-ui.service not found in $SCRIPT_DIR"
  exit 1
fi

echo "Installing Ulises UI service..."
echo "Make sure you've edited ulises-ui.service with your username and paths first!"
echo ""

sudo cp "$SERVICE_FILE" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable ulises-ui
sudo systemctl start ulises-ui
sudo systemctl status ulises-ui
