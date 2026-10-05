#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"
PHP_BIN="$(command -v php)"
IS_RAILWAY=false
if [[ -n "${RAILWAY_ENVIRONMENT:-}" || -n "${RAILWAY_PROJECT_ID:-}" || -n "${RAILWAY_SERVICE_ID:-}" ]]; then
IS_RAILWAY=true
fi
if ! "$PHP_BIN" -r 'exit(class_exists(ZipArchive::class) ? 0 : 1);' >/dev/null 2>&1; then
if [[ -x "/usr/bin/php" ]] && /usr/bin/php -r 'exit(class_exists(ZipArchive::class) ? 0 : 1);' >/dev/null 2>&1; then
PHP_BIN="/usr/bin/php"
printf '[Pteroless] The default PHP is missing ext-zip; using %s instead.\n' "$PHP_BIN"
else
printf '[Pteroless] PHP extension zip is required. Install php-zip and restart the panel.\n' >&2
exit 1
fi
fi
if [[ "$IS_RAILWAY" == true ]]; then
HOST="${HOST:-0.0.0.0}"
else
if [[ "${CODESPACES:-false}" == "true" ]]; then
HOST="${HOST:-localhost}"
else
HOST="${HOST:-0.0.0.0}"
fi
fi
PORT="${PORT:-8080}"
printf '\n'
printf '%s\n' '██████╗ ████████╗███████╗██████╗██████╗ ██╗ ███████╗███████╗███████╗'
printf '%s\n' '██╔══██╗╚══██╔══╝██╔════╝██╔══██╗██═══██╗██║ ██╔════╝██╔════╝██╔════╝'
printf '%s\n' '██████╔╝ ██║ █████╗██████╔╝██║ ██║██║ █████╗███████╗███████╗'
printf '%s\n' '██╔═══╝██║ ██╔══╝██╔══██╗██║ ██║██║ ██╔══╝╚════██║╚════██║'
printf '%s\n' '██║██║ ███████╗██║██║╚██████╔╝███████╗███████╗███████║███████║'
printf '%s\n' '╚═╝╚═╝ ╚══════╝╚═╝╚═╝ ╚═════╝ ╚══════╝╚══════╝╚══════╝'
printf '\n'
printf '%s\n' 'Pteroless Panel - Dev By @kagenouReal Based On Pterodactyl.'
printf '\n'
if [[ ! -f vendor/autoload.php ]]; then
echo "[Pteroless] vendor/autoload.php is missing. Run ./install.sh first." >&2
exit 1
fi
if [[ ! -f .env ]]; then
echo "[Pteroless] .env is missing. Run ./install.sh first." >&2
exit 1
fi
if [[ "$IS_RAILWAY" == false && "${EUID}" -eq 0 && -x /usr/local/sbin/pteroless-resource-agent ]]; then
if ! /usr/local/sbin/pteroless-resource-agent start; then
printf '[Pteroless] Resource agent did not start; soft disk limits will not be enforced. Check /var/log/pteroless/resource-agent.log and cgroup delegation.\n' >&2
fi
fi
if [[ "${EUID}" -eq 0 && "$IS_RAILWAY" == false ]]; then
if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] && command -v runuser >/dev/null 2>&1; then
exec runuser -u "$SUDO_USER" -- "$ROOT/start.sh"
fi
echo "[Pteroless] Run the panel as your regular user, without sudo." >&2
exit 1
fi
umask 0002
if [[ "${CODESPACES:-false}" == "true" ]]; then
printf '[Pteroless] Codespaces detected. Port %s is available at http://localhost:%s\n' "$PORT" "$PORT"
fi
if [[ "$IS_RAILWAY" == true ]]; then
printf '[Pteroless] Railway detected. Starting on 0.0.0.0:%s\n' "$PORT"
exec "$PHP_BIN" artisan serve --host="$HOST" --port="$PORT"
fi
if command -v sg >/dev/null 2>&1 && id -Gn "$(id -un)" | tr ' ' '\n' | grep -qx pteroless; then
printf -v PANEL_COMMAND '%q ' "$PHP_BIN" artisan serve "--host=$HOST" "--port=$PORT"
if ! sg pteroless -c 'test -S /run/pteroless-resource-agent/agent.sock'; then
printf '[Pteroless] Resource agent socket is missing; soft disk limits will not be enforced.\n' >&2
fi
exec sg pteroless -c "$PANEL_COMMAND"
fi
if [[ ! -S /run/pteroless-resource-agent/agent.sock ]]; then
printf '[Pteroless] Resource agent socket is missing; soft disk limits will not be enforced.\n' >&2
fi
exec "$PHP_BIN" artisan serve --host="$HOST" --port="$PORT"
