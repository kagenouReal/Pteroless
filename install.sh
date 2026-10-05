#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
WHITE='\033[1;37m'
RESET='\033[0m'
info() {
printf "%s\n" "$1"
}
ok() {
printf "%s\n" "$1"
}
warn() {
printf "%s\n" "$1"
}
fail() {
printf "%s\n" "$1" >&2
exit 1
}
step() {
printf "\n${BLUE}==>${RESET} ${WHITE}%s${RESET}\n" "$1"
}
trap 'printf "\nInstallation failed at line %s\n" "$LINENO" >&2' ERR
AUTOMATIC_SETUP=false
EMAIL_ENABLED=false
EMAIL_ADDRESS=""
EMAIL_APP_PASSWORD=""
ADMIN_USERNAME="admin"
ADMIN_PASSWORD="admin123"
ADMIN_EMAIL="admin@example.com"
ADMIN_FIRST_NAME="Admin"
ADMIN_LAST_NAME="User"
APP_URL="http://127.0.0.1:8080"
RECAPTCHA_ENABLED=false
RECAPTCHA_SECRET_KEY=""
RECAPTCHA_WEBSITE_KEY=""
PHPV=""
PHP_BIN=""
IS_RAILWAY=false
if [[ -n "${RAILWAY_ENVIRONMENT:-}" || -n "${RAILWAY_PROJECT_ID:-}" || -n "${RAILWAY_SERVICE_ID:-}" ]]; then
IS_RAILWAY=true
fi
if [[ "$IS_RAILWAY" == true ]]; then
if [[ -n "${PTEROLESS_APP_URL:-}" ]]; then
APP_URL="$PTEROLESS_APP_URL"
elif [[ -n "${RAILWAY_PUBLIC_DOMAIN:-}" ]]; then
APP_URL="https://${RAILWAY_PUBLIC_DOMAIN}"
fi
fi
for arg in "$@"; do
case "$arg" in
--automaticsetup|--automatic)
AUTOMATIC_SETUP=true
;;
-h|--help)
cat <<EOF2
Pteroless Installer
Usage:
sudo ./install.sh
sudo ./install.sh --automaticsetup
sudo ./install.sh --automatic
Modes:
Normal
Opens the setup form and asks for:
- Admin username
- Admin password
- Admin email
- First name
- Last name
- App URL
- reCAPTCHA on/off
- reCAPTCHA website key
- reCAPTCHA secret key
- Optional Gmail SMTP email and App Password
Automatic
Uses these defaults:
Username : admin
Password : admin123
Email: admin@example.com
Name : Admin User
App URL: http://127.0.0.1:8080
reCAPTCHA: OFF
Outgoing email: OFF unless both PTEROLESS_EMAIL_ADDRESS and
PTEROLESS_EMAIL_APP_PASSWORD are provided in the environment.
Railway:
Railway/Railpack PHP and Node.js installations are reused instead of
installing a second system PHP/Node stack through APT.
EOF2
exit 0
;;
*)
fail "Unknown argument: $arg"
;;
esac
done
clear 2>/dev/null || true
printf "\n"
printf "${WHITE}Pteroless Installer${RESET}\n"
if [[ "$IS_RAILWAY" == true ]]; then
printf "${CYAN}Railway / Railpack installation mode${RESET}\n"
else
printf "${CYAN}Simple installation for Debian / Ubuntu${RESET}\n"
fi
printf "\n"
if [[ "${EUID}" -ne 0 ]]; then
fail "Please run installer as root: sudo ./install.sh"
fi
if ! command -v apt-get >/dev/null 2>&1; then
fail "apt-get was not found. This installer supports Debian/Ubuntu based systems."
fi
if [[ "$AUTOMATIC_SETUP" == true ]]; then
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export npm_config_yes=true
export CI=true
export GIT_TERMINAL_PROMPT=0
fi
if [[ "$AUTOMATIC_SETUP" == true ]]; then
ADMIN_PASSWORD="admin123"
RECAPTCHA_ENABLED=false
RECAPTCHA_SECRET_KEY=""
RECAPTCHA_WEBSITE_KEY=""
EMAIL_ADDRESS="${PTEROLESS_EMAIL_ADDRESS:-}"
EMAIL_APP_PASSWORD="${PTEROLESS_EMAIL_APP_PASSWORD:-}"
if [[ -n "$EMAIL_ADDRESS" || -n "$EMAIL_APP_PASSWORD" ]]; then
if [[ -z "$EMAIL_ADDRESS" || -z "$EMAIL_APP_PASSWORD" ]]; then
fail "Set both PTEROLESS_EMAIL_ADDRESS and PTEROLESS_EMAIL_APP_PASSWORD to enable Gmail SMTP."
fi
EMAIL_APP_PASSWORD="${EMAIL_APP_PASSWORD//[[:space:]]/}"
if [[ ! "$EMAIL_ADDRESS" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
fail "PTEROLESS_EMAIL_ADDRESS must be a valid email address."
fi
if [[ ! "$EMAIL_APP_PASSWORD" =~ ^[A-Za-z0-9]{16}$ ]]; then
fail "The Gmail App Password must contain 16 letters or numbers."
fi
EMAIL_ENABLED=true
fi
printf "${WHITE}Automatic setup enabled.${RESET}\n"
printf "\n"
printf "Username : ${CYAN}%s${RESET}\n" "$ADMIN_USERNAME"
printf "Password : ${CYAN}%s${RESET}\n" "$ADMIN_PASSWORD"
printf "Email: ${CYAN}%s${RESET}\n" "$ADMIN_EMAIL"
printf "Name : ${CYAN}%s %s${RESET}\n" "$ADMIN_FIRST_NAME" "$ADMIN_LAST_NAME"
printf "App URL: ${CYAN}%s${RESET}\n" "$APP_URL"
printf "reCAPTCHA: ${CYAN}OFF${RESET}\n"
printf "Outgoing email: ${CYAN}%s${RESET}\n" "$([[ "$EMAIL_ENABLED" == true ]] && printf 'Gmail SMTP' || printf 'OFF (log only)')"
printf "\n"
else
printf "${WHITE}Pteroless Setup${RESET}\n"
printf "Enter the information for your first administrator.\n"
printf "\n"
read -r -p "Admin username: " INPUT_USERNAME
ADMIN_USERNAME="${INPUT_USERNAME:-admin}"
while true; do
read -r -p "Admin password: " INPUT_PASSWORD
printf '%s\n' ""
ADMIN_PASSWORD="${INPUT_PASSWORD:-admin123}"
break
done
read -r -p "Admin email: " INPUT_EMAIL
ADMIN_EMAIL="${INPUT_EMAIL:-admin@example.com}"
read -r -p "First name: " INPUT_FIRST
ADMIN_FIRST_NAME="${INPUT_FIRST:-Admin}"
read -r -p "Last name: " INPUT_LAST
ADMIN_LAST_NAME="${INPUT_LAST:-User}"
read -r -p "App URL: " INPUT_URL
APP_URL="${INPUT_URL:-http://127.0.0.1:8080}"
printf "\n"
printf "${WHITE}reCAPTCHA Setup${RESET}\n"
while true; do
read -r -p "Enable reCAPTCHA? (y/N): " INPUT_RECAPTCHA
INPUT_RECAPTCHA="${INPUT_RECAPTCHA:-N}"
case "$INPUT_RECAPTCHA" in
[Yy])
RECAPTCHA_ENABLED=true
read -r -p "reCAPTCHA Website Key: " RECAPTCHA_WEBSITE_KEY
read -r -p "reCAPTCHA Secret Key: " RECAPTCHA_SECRET_KEY
printf '%s\n' ""
if [[ -z "$RECAPTCHA_WEBSITE_KEY" || -z "$RECAPTCHA_SECRET_KEY" ]]; then
warn "Website Key and Secret Key are required when reCAPTCHA is enabled."
RECAPTCHA_ENABLED=false
RECAPTCHA_WEBSITE_KEY=""
RECAPTCHA_SECRET_KEY=""
continue
fi
ok "reCAPTCHA enabled."
break
;;
[Nn])
RECAPTCHA_ENABLED=false
RECAPTCHA_SECRET_KEY=""
RECAPTCHA_WEBSITE_KEY=""
ok "reCAPTCHA disabled."
break
;;
*)
warn "Please enter Y or N."
;;
esac
done
printf "\n"
printf "${WHITE}Outgoing Email Setup${RESET}\n"
while true; do
read -r -p "Enable outgoing email through Gmail SMTP? (y/N): " INPUT_EMAIL_ENABLED
INPUT_EMAIL_ENABLED="${INPUT_EMAIL_ENABLED:-N}"
case "$INPUT_EMAIL_ENABLED" in
[Yy])
while true; do
read -r -p "Gmail address: " INPUT_EMAIL_ADDRESS
EMAIL_ADDRESS="${INPUT_EMAIL_ADDRESS:-$ADMIN_EMAIL}"
if [[ "$EMAIL_ADDRESS" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then
break
fi
warn "Enter a valid email address."
done
while true; do
read -r -p "Gmail App Password (spaces are okay): " INPUT_EMAIL_APP_PASSWORD
printf '%s\n' ""
EMAIL_APP_PASSWORD="${INPUT_EMAIL_APP_PASSWORD//[[:space:]]/}"
if [[ "$EMAIL_APP_PASSWORD" =~ ^[A-Za-z0-9]{16}$ ]]; then
break
fi
warn "Enter the 16-character Google App Password, not your account password."
done
EMAIL_ENABLED=true
ok "Gmail SMTP enabled."
break
;;
[Nn])
EMAIL_ENABLED=false
EMAIL_ADDRESS=""
EMAIL_APP_PASSWORD=""
ok "Outgoing email disabled; messages will use log mode."
break
;;
*)
warn "Please enter Y or N."
;;
esac
done
printf "\n"
printf "${WHITE}Setup summary${RESET}\n"
printf '%s\n' '----------------------------------------'
printf "Username : %s\n" "$ADMIN_USERNAME"
printf "Password : %s\n" "$ADMIN_PASSWORD"
printf "Email: %s\n" "$ADMIN_EMAIL"
printf "Name : %s %s\n" "$ADMIN_FIRST_NAME" "$ADMIN_LAST_NAME"
printf "App URL: %s\n" "$APP_URL"
printf "reCAPTCHA: %s\n" "$([[ "$RECAPTCHA_ENABLED" == true ]] && printf 'enabled' || printf 'disabled')"
printf "Outgoing email: %s\n" "$([[ "$EMAIL_ENABLED" == true ]] && printf 'Gmail SMTP' || printf 'OFF (log only)')"
printf '%s\n' '----------------------------------------'
read -r -p "Continue installation? (Y/n): " CONFIRM
CONFIRM="${CONFIRM:-Y}"
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
printf "\n"
warn "Installation cancelled."
exit 0
fi
fi
step "Updating package lists"
apt-get update
ok "Package lists updated."
step "Installing system dependencies"
if [[ "$IS_RAILWAY" == true ]]; then
apt-get install -y \
ca-certificates \
curl \
unzip \
git \
openssl \
python3 \
python3-venv \
cron \
sqlite3
else
apt-get install -y \
ca-certificates \
curl \
unzip \
git \
openssl \
python3 \
python3-venv \
cron \
default-jre-headless \
golang-go \
nftables \
quota \
e2fsprogs \
sqlite3
fi
ok "System dependencies installed."
step "Checking PHP"
if [[ "$IS_RAILWAY" == true ]]; then
info "Railway detected. Using the PHP runtime provided by Railpack."
PHP_BIN="$(command -v php || true)"
if [[ -z "$PHP_BIN" ]]; then
fail "Railway PHP runtime was not found."
fi
else
PHP_PACKAGES=(
php
php-cli
php-fpm
php-sqlite3
php-mysql
php-mbstring
php-xml
php-curl
php-zip
php-bcmath
php-gd
php-intl
php-opcache
)
info "Installing/refreshing the Debian/Ubuntu PHP package set."
apt-get install -y "${PHP_PACKAGES[@]}"
if [[ -x "/usr/bin/php" ]]; then
PHP_BIN="/usr/bin/php"
else
for candidate in /usr/bin/php8.4 /usr/bin/php8.3 /usr/bin/php8.2; do
if [[ -x "$candidate" ]]; then
PHP_BIN="$candidate"
break
fi
done
fi
if [[ -z "$PHP_BIN" ]]; then
fail "Could not locate a package-managed PHP binary in /usr/bin."
fi
fi
PHP_VERSION="$("$PHP_BIN" -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || true)"
if [[ ! "$PHP_VERSION" =~ ^8\.[2-4]$ ]]; then
fail "PHP ${PHP_VERSION:-unknown} is unsupported. Requires PHP 8.2 through 8.4."
fi
export PATH="$(dirname "$PHP_BIN"):/usr/bin:/bin:${PATH}"
hash -r 2>/dev/null || true
ok "Using PHP ${PHP_VERSION} (${PHP_BIN})"
step "Checking PHP extensions"
if [[ "$IS_RAILWAY" == true ]]; then
REQUIRED_EXTENSIONS=(zip pdo pdo_sqlite sodium bcmath mbstring xml curl dom)
else
REQUIRED_EXTENSIONS=(zip pdo pdo_sqlite pdo_mysql sodium bcmath mbstring xml curl dom gd intl)
fi
MISSING_EXTENSIONS=()
for ext in "${REQUIRED_EXTENSIONS[@]}"; do
if ! "$PHP_BIN" -m 2>/dev/null | grep -Eiq "^${ext}$"; then
MISSING_EXTENSIONS+=("$ext")
fi
done
if ! "$PHP_BIN" -m 2>/dev/null | grep -Eiq "^Zend OPcache$"; then
if [[ "$IS_RAILWAY" == false ]]; then
MISSING_EXTENSIONS+=("opcache")
fi
fi
if [[ "${#MISSING_EXTENSIONS[@]}" -gt 0 ]]; then
if [[ "$IS_RAILWAY" == true ]]; then
fail "Railpack PHP is missing extensions: ${MISSING_EXTENSIONS[*]}"
else
fail "PHP ${PHP_VERSION} is missing extensions: ${MISSING_EXTENSIONS[*]}"
fi
fi
PHPV="$PHP_VERSION"
ok "PHP ${PHPV} and required extensions are ready."
step "Checking Composer"
if ! command -v composer >/dev/null 2>&1; then
info "Installing Composer."
EXPECTED_SIGNATURE="$(curl -fsSL https://composer.github.io/installer.sig)"
"$PHP_BIN" -r "copy('https://getcomposer.org/installer','/tmp/composer-setup.php');"
ACTUAL_SIGNATURE="$("$PHP_BIN" -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
if [[ "$EXPECTED_SIGNATURE" != "$ACTUAL_SIGNATURE" ]]; then
rm -f /tmp/composer-setup.php
fail "Composer installer signature verification failed."
fi
"$PHP_BIN" /tmp/composer-setup.php \
--install-dir=/usr/local/bin \
--filename=composer
rm -f /tmp/composer-setup.php
ok "Composer installed."
else
ok "Composer already installed."
fi
step "Checking Node.js"
NODE_OK=false
if command -v node >/dev/null 2>&1; then
NODE_MAJOR="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
if [[ "$IS_RAILWAY" == true ]]; then
if [[ "$NODE_MAJOR" -ge 22 ]]; then
NODE_OK=true
ok "Railpack Node.js $(node --version) already installed."
else
warn "Node.js $(node --version) is older than 22."
fi
else
if [[ "$NODE_MAJOR" -ge 26 ]]; then
NODE_OK=true
ok "Node.js $(node --version) already installed."
else
warn "Node.js $(node --version) is older than 26."
fi
fi
fi
if [[ "$NODE_OK" != true ]]; then
if [[ "$IS_RAILWAY" == true ]]; then
fail "Railpack Node.js is missing or too old. Requires Node.js 22+."
fi
info "Installing Node.js 26."
curl -fsSL https://deb.nodesource.com/setup_26.x | bash -
apt-get install -y nodejs
ok "Node.js $(node --version) installed."
fi
if ! command -v npm >/dev/null 2>&1; then
fail "npm was not installed with Node.js."
fi
ok "npm $(npm --version)"
step "Checking Python"
if ! command -v python3 >/dev/null 2>&1; then
fail "Python 3 is not available."
fi
if ! python3 -m venv --help >/dev/null 2>&1; then
fail "Python virtual environment support is unavailable."
fi
ok "Python $(python3 --version)"
step "Preparing SQLite"
mkdir -p "$ROOT/database"
DB_FILE="$ROOT/database/database.sqlite"
USE_EXISTING_DB=false
if [[ -f "$DB_FILE" ]]; then
if [[ "$AUTOMATIC_SETUP" == true ]]; then
info "Automatic setup enabled: replacing the existing database with a fresh one."
rm -f "$DB_FILE"
else
printf "\n"
warn "An existing SQLite database was found:"
printf "  %s\n" "$DB_FILE"
printf "\n"
read -r -p "Use existing database? (Y/n): " USE_DB_CONFIRM
USE_DB_CONFIRM="${USE_DB_CONFIRM:-Y}"
if [[ "$USE_DB_CONFIRM" =~ ^[Yy]$ ]]; then
USE_EXISTING_DB=true
ok "Using existing database."
else
info "Replacing existing database with a fresh one."
rm -f "$DB_FILE"
fi
fi
fi
if [[ "$USE_EXISTING_DB" != true ]]; then
touch "$DB_FILE"
chmod 664 "$DB_FILE"
ok "Fresh SQLite database ready."
else
chmod 664 "$DB_FILE"
fi
step "Configuring environment"
if [[ ! -f "$ROOT/.env" ]]; then
if [[ -f "$ROOT/.env.example" ]]; then
cp "$ROOT/.env.example" "$ROOT/.env"
ok ".env created from .env.example."
else
info ".env.example not found. Creating a default .env file."
cat > "$ROOT/.env" <<EOF2
APP_NAME=Pteroless
APP_ENV=production
APP_KEY=
APP_DEBUG=false
APP_URL=${APP_URL}
LOG_CHANNEL=stack
LOG_LEVEL=warning
DB_CONNECTION=sqlite
DB_DATABASE=${DB_FILE}
BROADCAST_CONNECTION=log
CACHE_STORE=file
FILESYSTEM_DISK=local
QUEUE_CONNECTION=sync
SESSION_DRIVER=file
SESSION_LIFETIME=120
MAIL_MAILER=log
APP_ENVIRONMENT_ONLY=false
CACHE_DRIVER=file
RECAPTCHA_ENABLED=${RECAPTCHA_ENABLED}
RECAPTCHA_WEBSITE_KEY=
RECAPTCHA_SECRET_KEY=
EOF2
ok ".env created with default settings."
fi
else
info ".env already exists. Keeping existing file."
fi
set_env() {
local key="$1"
local value="$2"
if grep -qE "^${key}=" "$ROOT/.env"; then
sed -i "s|^${key}=.*|${key}=${value}|" "$ROOT/.env"
else
printf "%s=%s\n" "$key" "$value" >> "$ROOT/.env"
fi
}
set_env "APP_ENV" "production"
set_env "APP_DEBUG" "false"
set_env "APP_ENVIRONMENT_ONLY" "false"
set_env "APP_URL" "$APP_URL"
if [[ "${CODESPACES:-false}" == "true" ]] && ! grep -qE '^TRUSTED_PROXIES=.+' "$ROOT/.env"; then
set_env "TRUSTED_PROXIES" "${TRUSTED_PROXIES:-**}"
fi
set_env "DB_CONNECTION" "sqlite"
set_env "DB_DATABASE" "$DB_FILE"
set_env "CACHE_DRIVER" "file"
set_env "CACHE_STORE" "file"
set_env "SESSION_DRIVER" "file"
set_env "QUEUE_CONNECTION" "sync"
if [[ "$EMAIL_ENABLED" == true ]]; then
set_env "MAIL_MAILER" "smtp"
set_env "MAIL_HOST" "smtp.gmail.com"
set_env "MAIL_PORT" "587"
set_env "MAIL_ENCRYPTION" "tls"
set_env "MAIL_USERNAME" "$EMAIL_ADDRESS"
set_env "MAIL_PASSWORD" "$EMAIL_APP_PASSWORD"
set_env "MAIL_FROM_ADDRESS" "$EMAIL_ADDRESS"
set_env "MAIL_FROM_NAME" "Pteroless"
else
set_env "MAIL_MAILER" "log"
fi
set_env "RECAPTCHA_ENABLED" "$RECAPTCHA_ENABLED"
if [[ "$RECAPTCHA_ENABLED" == true ]]; then
set_env "RECAPTCHA_WEBSITE_KEY" "$RECAPTCHA_WEBSITE_KEY"
set_env "RECAPTCHA_SECRET_KEY" "$RECAPTCHA_SECRET_KEY"
else
set_env "RECAPTCHA_WEBSITE_KEY" ""
set_env "RECAPTCHA_SECRET_KEY" ""
fi
ok "Environment configured."
step "Generating application key"
CURRENT_APP_KEY="$(grep -E '^APP_KEY=' "$ROOT/.env" | head -n1 | cut -d'=' -f2- || true)"
if [[ -n "$CURRENT_APP_KEY" && "$CURRENT_APP_KEY" != "null" ]]; then
ok "Application key already exists."
else
APP_KEY_VALUE="$("$PHP_BIN" -r 'echo "base64:".base64_encode(random_bytes(32));')"
if [[ -z "$APP_KEY_VALUE" ]]; then
fail "Could not generate an application encryption key."
fi
set_env "APP_KEY" "$APP_KEY_VALUE"
ok "Application key generated."
fi
CURRENT_HASHIDS_SALT="$(grep -E '^HASHIDS_SALT=' "$ROOT/.env" | head -n1 | cut -d'=' -f2- || true)"
if [[ -z "$CURRENT_HASHIDS_SALT" ]]; then
HASHIDS_SALT_VALUE="$("$PHP_BIN" -r 'echo bin2hex(random_bytes(32));')"
if [[ -z "$HASHIDS_SALT_VALUE" ]]; then
fail "Could not generate a Hashids salt."
fi
set_env "HASHIDS_SALT" "$HASHIDS_SALT_VALUE"
ok "Hashids salt generated."
fi
step "Preparing Laravel storage"
mkdir -p \
"$ROOT/storage/framework/cache/data" \
"$ROOT/storage/framework/sessions" \
"$ROOT/storage/framework/views" \
"$ROOT/storage/logs" \
"$ROOT/bootstrap/cache"
chmod -R 775 \
"$ROOT/storage" \
"$ROOT/bootstrap/cache"
ok "Laravel storage directories prepared."
step "Installing PHP dependencies"
composer install \
--no-dev \
--optimize-autoloader \
--no-interaction \
--prefer-dist
ok "PHP dependencies installed."
step "Preparing Laravel"
"$PHP_BIN" artisan config:clear
"$PHP_BIN" artisan cache:clear || true
"$PHP_BIN" artisan view:clear || true
ok "Laravel prepared."
step "Running database migrations"
"$PHP_BIN" artisan migrate \
--force \
--no-interaction
ok "Database migrations completed."
step "Checking administrator account"
if [[ "$USE_EXISTING_DB" == true ]]; then
ADMIN_EXISTS="0"
if sqlite3 "$DB_FILE" "SELECT name FROM sqlite_master WHERE type='table' AND name='users';" | grep -qx "users"; then
ADMIN_EXISTS="$(sqlite3 "$DB_FILE" \
"SELECT COUNT(*) FROM users WHERE CAST(root_admin AS TEXT) IN ('1','true');" \
2>/dev/null || echo 0)"
fi
if [[ "$ADMIN_EXISTS" =~ ^[0-9]+$ ]] && [[ "$ADMIN_EXISTS" -gt 0 ]]; then
ok "An administrator already exists in the existing database. Skipping account creation."
else
EMAIL_SQL="$(printf '%s' "$ADMIN_EMAIL" | sed "s/'/''/g")"
USERNAME_SQL="$(printf '%s' "$ADMIN_USERNAME" | sed "s/'/''/g")"
EMAIL_TAKEN="$(sqlite3 "$DB_FILE" \
"SELECT COUNT(*) FROM users WHERE email = '${EMAIL_SQL}';" 2>/dev/null || echo 0)"
USERNAME_TAKEN="$(sqlite3 "$DB_FILE" \
"SELECT COUNT(*) FROM users WHERE username = '${USERNAME_SQL}';" 2>/dev/null || echo 0)"
if [[ "$EMAIL_TAKEN" =~ ^[0-9]+$ ]] && [[ "$EMAIL_TAKEN" -gt 0 ]] || \
[[ "$USERNAME_TAKEN" =~ ^[0-9]+$ ]] && [[ "$USERNAME_TAKEN" -gt 0 ]]; then
warn "Requested administrator username/email is already in use in the existing database."
info "Skipping administrator creation to avoid changing the existing user."
else
info "Creating administrator account."
"$PHP_BIN" artisan p:user:make \
--email="$ADMIN_EMAIL" \
--username="$ADMIN_USERNAME" \
--password="$ADMIN_PASSWORD" \
--name-first="$ADMIN_FIRST_NAME" \
--name-last="$ADMIN_LAST_NAME" \
--admin=1 \
--no-interaction
ok "Administrator account created."
fi
fi
else
info "Creating administrator account."
"$PHP_BIN" artisan p:user:make \
--email="$ADMIN_EMAIL" \
--username="$ADMIN_USERNAME" \
--password="$ADMIN_PASSWORD" \
--name-first="$ADMIN_FIRST_NAME" \
--name-last="$ADMIN_LAST_NAME" \
--admin=1 \
--no-interaction
ok "Administrator account created."
fi
step "Preparing Yarn"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
if command -v corepack >/dev/null 2>&1; then
corepack disable >/dev/null 2>&1 || true
fi
hash -r 2>/dev/null || true
if ! command -v yarn >/dev/null 2>&1; then
info "Yarn not found. Installing Yarn 1.22.22."
npm install --global --no-audit --no-fund --yes yarn@1.22.22
ok "Yarn installed."
else
ok "Yarn already available: $(yarn --version 2>/dev/null || true)"
fi
hash -r 2>/dev/null || true
if ! command -v yarn >/dev/null 2>&1; then
fail "Yarn is unavailable after installation."
fi
YARN_VERSION="$(yarn --version 2>/dev/null || true)"
if [[ -z "$YARN_VERSION" ]]; then
fail "Could not determine Yarn version."
fi
ok "Using Yarn ${YARN_VERSION}."
step "Installing frontend dependencies"
if [[ -f "$ROOT/package.json" ]]; then
if ! node -e 'const p=require("./package.json"); const d={...(p.dependencies||{}), ...(p.devDependencies||{})}; process.exit(d["@preact/signals-react"] ? 0 : 1);' 2>/dev/null; then
info "Missing @preact/signals-react dependency. Adding compatible version."
yarn add "@preact/signals-react@^1.2.1" --ignore-scripts --non-interactive
ok "@preact/signals-react dependency added."
fi
fi
if [[ -f "$ROOT/yarn.lock" ]]; then
yarn install \
--frozen-lockfile \
--non-interactive
ok "Frontend dependencies installed with Yarn."
else
if [[ -f "$ROOT/package-lock.json" ]]; then
npm ci --no-audit --no-fund --yes
else
npm install --no-audit --no-fund --yes
fi
ok "Frontend dependencies installed with npm."
fi
step "Building frontend"
mkdir -p "$ROOT/public/assets"
ok "Frontend asset directory ready."
if [[ -f "$ROOT/yarn.lock" ]]; then
yarn run build:production
else
npm run build:production
fi
ok "Frontend build completed."
step "Optimizing Laravel"
"$PHP_BIN" artisan config:cache
"$PHP_BIN" artisan route:cache || true
"$PHP_BIN" artisan view:cache || true
ok "Laravel optimized."
step "Setting permissions"
mkdir -p \
"$ROOT/storage" \
"$ROOT/storage/framework" \
"$ROOT/storage/framework/cache/data" \
"$ROOT/storage/framework/sessions" \
"$ROOT/storage/framework/views" \
"$ROOT/storage/logs" \
"$ROOT/storage/app" \
"$ROOT/storage/app/servers" \
"$ROOT/bootstrap/cache"
if [[ "$IS_RAILWAY" == true ]]; then
warn "Railway detected. Skipping local system ownership/group changes."
warn "Railway runtime permissions are managed by the container environment."
else
if ! getent group pteroless >/dev/null 2>&1; then
groupadd --system pteroless
fi
INSTALL_USER="${SUDO_USER:-${USER:-}}"
if [[ -z "$INSTALL_USER" || "$INSTALL_USER" == "root" ]]; then
INSTALL_USER="$(logname 2>/dev/null || true)"
fi
if [[ -z "$INSTALL_USER" || "$INSTALL_USER" == "root" ]]; then
warn "Could not determine the non-root installer user. Leaving ownership unchanged."
else
APP_GROUP=pteroless
chown -R "${INSTALL_USER}:${APP_GROUP}" \
"$ROOT/storage" \
"$ROOT/bootstrap/cache"
chown "${INSTALL_USER}:${APP_GROUP}" "$ROOT/database" "$DB_FILE" 2>/dev/null || true
chown "${INSTALL_USER}:${APP_GROUP}" "$ROOT/.env" 2>/dev/null || true
chmod -R u+rwX,g+rwX \
"$ROOT/storage" \
"$ROOT/bootstrap/cache"
find "$ROOT/storage" "$ROOT/bootstrap/cache" -type d -exec chmod g+s {} +
chmod g+rwX,g+s "$ROOT/database"
chmod 664 "$DB_FILE"
chmod 640 "$ROOT/.env"
ok "Writable permissions configured for ${INSTALL_USER} and ${APP_GROUP}."
fi
fi
step "Installing the privileged resource agent"
RESOURCE_AGENT_READY=false
if [[ "$IS_RAILWAY" == true ]]; then
warn "Railway does not provide the same host-level cgroup/systemd access as a normal server."
warn "Skipping the privileged Pteroless resource agent on Railway."
else
if ! getent group pteroless >/dev/null 2>&1; then
groupadd --system pteroless
fi
ALLOWED_UIDS=""
for AGENT_USER in www-data "${INSTALL_USER:-}"; do
if [[ -z "$AGENT_USER" ]] || ! id "$AGENT_USER" >/dev/null 2>&1; then
continue
fi
usermod -aG pteroless "$AGENT_USER"
AGENT_UID="$(id -u "$AGENT_USER")"
if [[ ",${ALLOWED_UIDS}," != *",${AGENT_UID},"* ]]; then
ALLOWED_UIDS="${ALLOWED_UIDS:+${ALLOWED_UIDS},}${AGENT_UID}"
fi
done
if [[ -z "$ALLOWED_UIDS" ]]; then
fail "Could not determine a panel user allowed to access the resource agent."
fi
if [[ -x /usr/local/sbin/pteroless-resource-agent && -r /etc/default/pteroless-resource-agent ]]; then
/usr/local/sbin/pteroless-resource-agent stop
fi
install -d -o root -g root -m 0755 /usr/local/lib/pteroless
install -o root -g root -m 0644 "$ROOT/resources/local/resource_agent.py" /usr/local/lib/pteroless/resource_agent.py
install -o root -g root -m 0755 "$ROOT/resources/local/resource_agent_launcher.sh" /usr/local/sbin/pteroless-resource-agent
install -d -o root -g pteroless -m 0750 /run/pteroless-resource-agent
install -d -o root -g root -m 0750 /var/lib/pteroless-resource-agent
install -d -o root -g adm -m 0750 /var/log/pteroless
CGROUP_ROOT="/sys/fs/cgroup/pteroless"
if [[ -r /sys/fs/cgroup/cgroup.controllers ]] && \
grep -qw cpu /sys/fs/cgroup/cgroup.subtree_control && \
grep -qw memory /sys/fs/cgroup/cgroup.subtree_control; then
if mkdir -p "$CGROUP_ROOT"; then
ok "A dedicated cgroup directory is available without systemd."
else
warn "The host does not allow creating a delegated Pteroless cgroup."
fi
else
warn "The host has not delegated CPU/memory controllers at the cgroup root."
fi
cat > /etc/default/pteroless-resource-agent <<EOF2
PTEROLESS_ALLOWED_UIDS=${ALLOWED_UIDS}
PTEROLESS_STORAGE_ROOT=${ROOT}/storage/app/servers
PTEROLESS_CGROUP_ROOT=${CGROUP_ROOT}
EOF2
chmod 0644 /etc/default/pteroless-resource-agent
cat > /etc/cron.d/pteroless-resource-agent <<'EOF2'
@reboot root /usr/local/sbin/pteroless-resource-agent start
EOF2
chmod 0644 /etc/cron.d/pteroless-resource-agent
if /usr/local/sbin/pteroless-resource-agent start; then
RESOURCE_AGENT_READY=true
ok "Privileged resource agent is running without Wings or systemd."
else
warn "Resource agent could not start. Check /var/log/pteroless/resource-agent.log."
fi
if [[ -x /etc/init.d/cron ]]; then
if /etc/init.d/cron start >/dev/null 2>&1; then
ok "Cron is available for starting the agent after reboot."
else
warn "Cron could not be started. Start it with your init system to enable agent autostart."
fi
else
warn "Cron is unavailable; the resource agent will need to be started manually after reboot."
fi
if [[ -r /sys/fs/cgroup/cgroup.controllers ]] && \
grep -qw cpu /sys/fs/cgroup/cgroup.controllers && \
grep -qw memory /sys/fs/cgroup/cgroup.controllers; then
ok "cgroup v2 CPU and memory controllers are present."
else
warn "cgroup v2 CPU/memory controllers are unavailable; hard CPU and memory limits cannot be enforced."
fi
if [[ "$RESOURCE_AGENT_READY" != true ]]; then
warn "Local servers remain in best-effort mode until the privileged resource agent is running and cgroup controllers are delegated."
fi
fi
step "Writing installation information"
cat > "$ROOT/.Pteroless-installed" <<EOF2
Pteroless installation completed.
APP_URL=${APP_URL}
DB_CONNECTION=sqlite
DB_DATABASE=${DB_FILE}
RECAPTCHA_ENABLED=${RECAPTCHA_ENABLED}
RAILWAY_MODE=${IS_RAILWAY}
INSTALLED_AT=$(date '+%Y-%m-%d %H:%M:%S %Z')
EOF2
chmod 600 "$ROOT/.Pteroless-installed"
ok "Installation information saved."
printf "\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "${GREEN} Pteroless installation completed successfully${RESET}\n"
printf "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}\n"
printf "\n"
printf "Panel URL: ${CYAN}%s${RESET}\n" "$APP_URL"
printf "Username : ${CYAN}%s${RESET}\n" "$ADMIN_USERNAME"
printf "Email: ${CYAN}%s${RESET}\n" "$ADMIN_EMAIL"
if [[ "$AUTOMATIC_SETUP" == true ]]; then
printf "Password : ${CYAN}%s${RESET}\n" "$ADMIN_PASSWORD"
printf "\n"
printf "${YELLOW}Automatic setup credentials:${RESET}\n"
printf "Username : %s\n" "$ADMIN_USERNAME"
printf "Password : %s\n" "$ADMIN_PASSWORD"
printf "Email: %s\n" "$ADMIN_EMAIL"
else
printf "Password : ${CYAN}(configured during setup)${RESET}\n"
fi
printf "\n"
printf "reCAPTCHA: "
if [[ "$RECAPTCHA_ENABLED" == true ]]; then
printf "${CYAN}enabled${RESET}\n"
else
printf "${CYAN}disabled${RESET}\n"
fi
printf "\n"
printf "Start with:\n"
printf "${WHITE}bash ./start.sh${RESET}\n"
printf "\n"
if [[ "$IS_RAILWAY" == true ]]; then
printf "${YELLOW}Railway mode: PHP/Node are provided by Railpack; no second PHP/Node stack was installed.${RESET}\n"
printf "\n"
fi
if [[ "$AUTOMATIC_SETUP" == true ]]; then
printf "${YELLOW}Keep the credentials above somewhere safe.${RESET}\n"
printf "\n"
fi
