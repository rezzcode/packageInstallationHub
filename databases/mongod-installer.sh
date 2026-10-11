#!/usr/bin/env bash

set -Eeuo pipefail

# -------------------------------
# Config
# -------------------------------
MONGO_VERSION="8.0"
KEYRING_PATH="/usr/share/keyrings/mongodb-server-${MONGO_VERSION}.gpg"
SOURCE_LIST="/etc/apt/sources.list.d/mongodb-org-${MONGO_VERSION}.list"
REPO_URL="https://repo.mongodb.org/apt/ubuntu"
CODENAME="$(lsb_release -cs)"

# -------------------------------
# Logging helpers
# -------------------------------
log() {
  echo -e "[INFO] $*"
}

warn() {
  echo -e "[WARN] $*" >&2
}

err() {
  echo -e "[ERROR] $*" >&2
}

# -------------------------------
# Root check
# -------------------------------
if [[ "$EUID" -ne 0 ]]; then
  err "Please run as root (use sudo)"
  exit 1
fi

# -------------------------------
# Check OS compatibility
# -------------------------------
if ! command -v lsb_release &>/dev/null; then
  err "lsb_release not found. Install it first."
  exit 1
fi

log "Detected Ubuntu codename: ${CODENAME}"

# -------------------------------
# Install dependencies
# -------------------------------
log "Installing dependencies..."
apt-get update -y
apt-get install -y gnupg curl ca-certificates lsb-release

# -------------------------------
# Add MongoDB GPG key (idempotent)
# -------------------------------
if [[ ! -f "$KEYRING_PATH" ]]; then
  log "Adding MongoDB GPG key..."
  curl -fsSL "https://pgp.mongodb.com/server-${MONGO_VERSION}.asc" \
    | gpg --dearmor -o "$KEYRING_PATH"
else
  log "GPG key already exists, skipping..."
fi

# -------------------------------
# Add repository (idempotent)
# -------------------------------
if [[ ! -f "$SOURCE_LIST" ]]; then
  log "Adding MongoDB repository..."
  echo "deb [arch=amd64,arm64 signed-by=${KEYRING_PATH}] ${REPO_URL} ${CODENAME}/mongodb-org/${MONGO_VERSION} multiverse" \
    > "$SOURCE_LIST"
else
  log "Repository already exists, skipping..."
fi

# -------------------------------
# Install MongoDB
# -------------------------------
log "Updating package index..."
apt-get update -y

if ! dpkg -l | grep -q mongodb-org; then
  log "Installing MongoDB..."
  apt-get install -y mongodb-org
else
  log "MongoDB already installed, skipping..."
fi

# -------------------------------
# Start & enable service
# -------------------------------
log "Starting MongoDB service..."
systemctl daemon-reexec || true
systemctl enable mongod
systemctl start mongod

# -------------------------------
# Verify service
# -------------------------------
if systemctl is-active --quiet mongod; then
  log "MongoDB is running successfully 🎉"
else
  err "MongoDB failed to start"
  systemctl status mongod --no-pager
  exit 1
fi

# -------------------------------
# Show status (concise)
# -------------------------------
log "MongoDB service status:"
systemctl status mongod --no-pager -l

# -------------------------------
# Optional: stop service
# -------------------------------
read -rp "Do you want to stop MongoDB now? (y/N): " STOP_NOW

if [[ "${STOP_NOW,,}" == "y" ]]; then
  log "Stopping MongoDB..."
  systemctl stop mongod
  log "MongoDB stopped."
else
  log "MongoDB left running."
fi
