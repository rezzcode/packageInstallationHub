#!/usr/bin/env bash
# =============================================================================
# ERPNext / Frappe Server Setup Script (Ubuntu 24.04+)
# Targets Frappe / ERPNext v16 stack (Python 3.14 + Node 24)
# =============================================================================

set -euo pipefail

# ---------- Colors & helpers ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log()   { echo -e "${BLUE}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

if [[ $EUID -eq 0 ]]; then
  error "Do not run this script as root. Run it as a normal user with sudo privileges."
fi

if ! command -v sudo &>/dev/null; then
  error "sudo is required but not installed."
fi

# ---------- Collect input ----------
echo
log "# ----------- ERPNext / Frappe Setup -----------"
echo

# MariaDB root password
while true; do
  read -s -p "Enter new MariaDB root password: " MYSQL_ROOT_PASSWORD
  echo
  read -s -p "Confirm MariaDB root password: " MYSQL_ROOT_PASSWORD_CONFIRM
  echo
  if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
    warn "Password cannot be empty."
    continue
  fi
  if [[ "$MYSQL_ROOT_PASSWORD" == "$MYSQL_ROOT_PASSWORD_CONFIRM" ]]; then
    break
  fi
  warn "Passwords do not match. Try again."
done

# Site name
read -p "Enter site name [localhost]: " SITE_NAME
SITE_NAME=${SITE_NAME:-localhost}

# Administrator password for the new site
while true; do
  read -s -p "Enter Administrator password for the site: " ADMIN_PASSWORD
  echo
  read -s -p "Confirm Administrator password: " ADMIN_PASSWORD_CONFIRM
  echo
  if [[ -z "$ADMIN_PASSWORD" ]]; then
    warn "Password cannot be empty."
    continue
  fi
  if [[ "$ADMIN_PASSWORD" == "$ADMIN_PASSWORD_CONFIRM" ]]; then
    break
  fi
  warn "Passwords do not match. Try again."
done

BENCH_DIR="$HOME/frappe-bench"
FRAPPE_USER="$USER"

# ---------- System update ----------
log "Updating system packages..."
sudo apt-get update -y
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

# ---------- Core dependencies ----------
log "Installing system dependencies..."
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
  git curl wget software-properties-common \
  build-essential pkg-config \
  python3-dev python3-setuptools python3-pip \
  libffi-dev libssl-dev \
  redis-server \
  nginx supervisor \
  mariadb-server mariadb-client libmariadb-dev \
  xvfb libfontconfig1 fontconfig \
  cron

ok "System packages installed"

# ---------- MariaDB configuration (critical for Frappe) ----------
log "Configuring MariaDB for Frappe (utf8mb4)..."

sudo tee /etc/mysql/mariadb.conf.d/frappe.cnf > /dev/null <<'EOF'
[mysqld]
character-set-client-handshake = FALSE
character-set-server = utf8mb4
collation-server = utf8mb4_unicode_ci
max-allowed-packet = 256M

[mysql]
default-character-set = utf8mb4
EOF

# Set root password and secure the installation
sudo mysql -u root <<MYSQL_SCRIPT
ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
MYSQL_SCRIPT

sudo systemctl restart mariadb
sudo systemctl enable mariadb
ok "MariaDB configured and secured"

# ---------- Redis ----------
sudo systemctl enable --now redis-server
ok "Redis started"

# ---------- Node.js 24 via nvm (official recommendation) ----------
log "Installing Node.js 24 via nvm..."
export NVM_DIR="$HOME/.nvm"
if [[ ! -d "$NVM_DIR" ]]; then
  curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
fi

# shellcheck source=/dev/null
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

nvm install 24
nvm use 24
nvm alias default 24

npm install -g yarn
ok "Node $(node -v) and Yarn installed"

# ---------- Python 3.14 via uv (official recommendation) ----------
log "Installing Python 3.14 via uv..."
if ! command -v uv &>/dev/null; then
  curl -LsSf https://astral.sh/uv/install.sh | sh
  # shellcheck source=/dev/null
  source "$HOME/.local/bin/env" 2>/dev/null || true
  export PATH="$HOME/.local/bin:$PATH"
fi

uv python install 3.14 --default
ok "Python $(python3 --version) ready"

# ---------- Install frappe-bench ----------
log "Installing frappe-bench..."
uv tool install frappe-bench
# Ensure the tool is on PATH
export PATH="$HOME/.local/bin:$PATH"
ok "bench $(bench --version) installed"

# ---------- Initialize bench ----------
if [[ -d "$BENCH_DIR" ]]; then
  warn "Directory $BENCH_DIR already exists. Skipping bench init."
else
  log "Initializing frappe-bench (this can take several minutes)..."
  cd "$HOME"
  bench init frappe-bench --python 3.14 --frappe-branch version-16
  ok "Bench initialized"
fi

cd "$BENCH_DIR"

# Allow the web user to traverse the home directory
# (needed for production)
sudo chmod 755 "$HOME"

log "Downloading apps..."
bench get-app --branch version-16 erpnext
bench get-app --branch version-16 hrms
bench get-app --branch version-16 lending
bench get-app payments   # payments is usually on main / develop
ok "Apps downloaded"

log "Creating site: $SITE_NAME ..."
bench new-site "$SITE_NAME" \
  --db-root-username root \
  --db-root-password "$MYSQL_ROOT_PASSWORD" \
  --admin-password "$ADMIN_PASSWORD"

ok "Site $SITE_NAME created"

log "Installing apps on site..."
bench --site "$SITE_NAME" install-app erpnext
bench --site "$SITE_NAME" install-app hrms
bench --site "$SITE_NAME" install-app lending
bench --site "$SITE_NAME" install-app payments
ok "Apps installed"

# ---------- Production setup ----------
log "Setting up production environment (Nginx + Supervisor)..."
sudo bench setup production "$FRAPPE_USER" --yes

# meke your site name default
bench use "$SITE_NAME"

bench restart
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl restart all
sudo systemctl restart nginx

ok "Production setup complete"

log "Creating a helper script that you can run later"
cat > "$HOME/frappe-firewall.sh" << 'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

echo "Configuring UFW firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 'Nginx Full'
sudo ufw --force enable
echo "Firewall enabled (OpenSSH + Nginx Full)."
echo

# 2. Optional Let's Encrypt
read -r -p "Do you have a domain pointing to this server? (y/n): " option

if [[ "$option" =~ ^[Yy]$ ]]; then
    read -r -p "Enter the site name / domain (e.g. erp.rezzcode.me): " domain
    if [[ -z "$domain" ]]; then
        echo "Error: Domain/site name cannot be empty." >&2
        exit 1
    fi

    if [[ ! -d "$HOME/frappe-bench" ]]; then
        echo "Error: ~/frappe-bench not found." >&2
        exit 1
    fi

    cd "$HOME/frappe-bench"
    echo "Setting up Let's Encrypt for: $domain"
    sudo bench setup lets-encrypt "$domain"
    echo "SSL certificate installed successfully."
else
    echo "Skipping Let's Encrypt setup."
    exit 0
fi

echo
echo "Done!"
SCRIPT

chmod +x "$HOME/frappe-firewall.sh"
echo
ok "Helper script created: ~/frappe-firewall.sh"

# ---------- Final notes ----------
echo
echo "======================================================================"
ok "ERPNext setup finished successfully!"
echo
echo "  Site name        : $SITE_NAME"
echo "  Access URL       : http://$(hostname -I | awk '{print $1}')  (or http://localhost/)"
echo "  Administrator    : Administrator"
echo "  Admin password   : (the one you set earlier)"
echo
echo "Useful commands:"
echo "  cd $BENCH_DIR"
echo "  bench start                 # development mode"
echo "  bench restart               # after code changes"
echo "  bench --site $SITE_NAME console"
echo "  sudo supervisorctl status   # production services"
echo
warn "Recommended next steps:"
echo "  1. Point a domain to this server and run the helper script below"
echo "		==>> ~/frappe-firewall.sh"
echo "  2. Or manually:"
echo "       sudo ufw allow OpenSSH && sudo ufw allow 'Nginx Full' && sudo ufw enable"
echo "       sudo bench setup lets-encrypt $SITE_NAME"
echo "  3. Take a backup: bench --site $SITE_NAME backup --with-files"
echo "======================================================================"
