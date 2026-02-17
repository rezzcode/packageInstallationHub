#!/usr/bin/env bash

set -euo pipefail

echo "=== Docker installation script ==="

# Ensure script is not run as root (recommended)
if [[ "$EUID" -eq 0 ]]; then
  echo "===XXX===> Do not run this script as root. Run as a normal user."
  exit 1
fi

# Remove old Docker versions if present (ignore errors)
echo "===> Removing old Docker packages (if any)..."
sudo apt-get remove -y docker docker-engine docker.io containerd runc || true

# Update package index
echo "===> Updating package index..."
sudo apt-get update -y

# Install prerequisites
echo "===> Installing prerequisites..."
sudo apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# Add Docker's official GPG key
echo "===> Adding Docker GPG key..."
sudo install -m 0755 -d /etc/apt/keyrings
if [[ ! -f /etc/apt/keyrings/docker.gpg ]]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
fi

# Add Docker repository
echo "===> Adding Docker APT repository..."
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/ubuntu \
  $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index again
sudo apt-get update -y

# Install Docker Engine
echo "===> Installing Docker Engine..."
sudo apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# Enable and start Docker
echo "===> Enabling Docker service..."
sudo systemctl enable docker
sudo systemctl start docker

# Add user to docker group (do not fail script if already added)
echo "===> Adding user '$USER' to docker group..."
sudo usermod -aG docker "$USER" || true

sudo chown $USER /var/run/docker.sock

# Verify installation
echo "===> Verifying Docker installation..."
docker --version
docker compose version

echo
echo " ===> Docker installed successfully."
echo " !!! ===> Log out and log back in for docker group changes to take effect."
