# Pteroless

Pteroless is a Pterodactyl-derived panel with a built-in local process runner.
Instead of sending a server to Wings or Docker, Pteroless can start the app
straight on the Linux host.

This project is still experimental. It is mainly aimed at personal use,
local hosting, and development. It is not a drop-in replacement for a normal
Pterodactyl + Wings setup and the local runner is not a security boundary.

## What Pteroless does

The main flow is simple:

```text
Browser -> Laravel Panel -> LocalProcessManager -> Linux process
                                      |
                                      +-> optional resource agent
```

The project keeps a lot of the original Pterodactyl panel, API, models, and
client UI, then adds a local execution path on top of it.

The local runner currently handles:

- creating local server records and server directories
- starting, stopping, and restarting applications
- console input through a local FIFO and log output per server
- local file operations such as read, write, upload, download, copy, rename,
  delete, compress, extract, create folder, and chmod
- runtime presets for Node.js, Next.js, Python, Java/JAR, PHP, Go, and custom
  commands
- optional CPU, memory, and disk control through a privileged resource agent
- a client/admin UI that still follows the Pterodactyl-style panel flow

The app is still running as a normal host process. Presets do not create
containers, VM-style isolation, or pinned runtime images.

## Runtime presets

The defaults live in `app/Services/Local/LocalServerService.php`.

| Preset | Default command |
| --- | --- |
| Node.js | `npm install && npm start` when `package.json` exists, otherwise `node index.js` |
| Next.js | `npm install && npm run build && npm run start` |
| Python | creates `.venv`, installs `requirements.txt`, then runs `main.py` |
| Java | `java -jar server.jar` |
| PHP | runs `composer install` when needed, then serves `artisan` or `index.php` with PHP's built-in server |
| Go | `go mod download && go run .`, or `go run main.go` |
| Custom | whatever startup command the admin provides |

These are convenience defaults, not curated runtime images. The host controls
which versions are installed, and some presets can hit the network during
startup.

Every local server gets its own working directory under:

```text
storage/app/servers/<server-uuid>/
```

Pteroless also gives the process a private `HOME` directory under `.local/`
for runtime metadata and keeps its output at `.local/logs/output.log`.

## Process and console

`LocalProcessManager` starts the configured command as a detached Linux
process group. The panel stores the main PID, captures stdout/stderr, and uses
Linux process data to track state.

The console is not a full terminal emulator. Commands are sent through a FIFO.
For the client UI, the local API exposes resources, logs, and a combined
snapshot endpoint. The browser polls while the server page is visible and
stops polling when the tab is hidden.

## Resource agent

The resource agent is an optional privileged helper shipped in
`resources/local/`.

It talks to the panel over a restricted Unix socket and can create a cgroup
for a local server. CPU and memory controls depend on cgroup v2 delegation on
the host. Network counters also depend on compatible nftables support.

Disk limits are soft limits. The agent checks directory usage periodically and
can stop an over-limit process, but the limit can still be exceeded between
checks. This is not a project quota and it is not hard disk enforcement.

`install.sh` installs the helper and creates a cron entry so the agent can be
started again after reboot. The panel itself is still started by `start.sh`.

## Known limits

Pteroless intentionally does not pretend to support every inherited
Pterodactyl feature on the local runner.

- Local applications run under the host account. There is no per-server UID
  or container isolation.
- The supported local path is one Linux host. Remote node scheduling is not
  provided by the local runner.
- Some inherited admin/API paths still use Wings repositories and may not be
  usable for local servers.
- Local backup and some scheduled-task paths are incomplete because inherited
  code still expects Wings.
- The local runner does not provide a per-server SFTP daemon.
- Disk limits are best-effort soft limits.
- Application network exposure is host-managed. The default local allocation
  binds to `127.0.0.1`.
- `start.sh` uses Laravel's built-in `artisan serve`, so it is a convenient
  launcher, not a production web-server stack.

Because server processes share the panel's Unix identity, only run code you
trust. Do not treat panel permissions, Egg/Nest records, resource limits, or
allocation settings as a security boundary.

## Requirements

The bundled installer targets Debian/Ubuntu with APT and root access.

You need:

- PHP 8.2 through 8.4 with the required Laravel extensions
- Composer
- Node.js 22 or newer
- Yarn
- a Linux host for the local runner

The installer also sets up host runtimes used by the presets, including
Node.js, Python 3 with `venv`, Java, and Go.

For the privileged resource agent, the host should provide cgroup v2 with CPU
and memory controllers delegated where the installer expects them.

## Install

Run the installer from the project directory:

```bash
sudo bash ./install.sh
```

The installer handles the main system packages, environment setup, database
initialization, frontend dependencies, permissions, and the optional resource
agent.

To see the installer modes and options:

```bash
sudo bash ./install.sh --help
```

Review `install.sh` before running it on a machine that already hosts
important workloads. It changes system packages, users/groups, permissions,
and resource-agent files.

## Start

Start the panel without `sudo`:

```bash
./start.sh
```

By default the development launcher uses port `8080`. The host is
`0.0.0.0` outside Codespaces and `localhost` inside Codespaces. You can
override the host and port with `HOST` and `PORT`.

```bash
HOST=127.0.0.1 PORT=8080 ./start.sh
```

`start.sh` also checks for the resource-agent socket and warns when the agent
is unavailable.

## Data and configuration

The important runtime paths are:

| Path | Purpose |
| --- | --- |
| `.env` | panel configuration and secrets |
| `database/database.sqlite` | default panel database |
| `storage/app/servers/<server-uuid>/` | application files for a local server |
| `storage/app/servers/<server-uuid>/.local/` | local process metadata, FIFO, HOME, and logs |
| `/run/pteroless-resource-agent/agent.sock` | resource-agent socket |
| `/var/log/pteroless/resource-agent.log` | resource-agent log |

Back up the SQLite database and the server directories separately. Stop active
applications before taking a filesystem snapshot when consistency matters.

Never commit `.env`, database files, server data, runtime logs, or credentials.

## Email and CAPTCHA

Email is optional. The default mailer writes mail to the Laravel log instead of
sending it. The installer can configure Gmail SMTP, and other SMTP providers
can be configured through the panel environment settings.

Login CAPTCHA is also optional and uses Google reCAPTCHA v2 Invisible when
enabled. Keep the secret key out of the repository and make sure the configured
hostname matches `APP_URL`.

## Database

Pteroless uses SQLite for its own panel database by default.

Per-server database support is separate from the panel database. It expects a
reachable MySQL-compatible database host and PHP's `pdo_mysql` extension.
Pteroless does not ship an embedded MySQL server.

## Development

Install the project dependencies first:

```bash
composer install
yarn install
```

Build the frontend with:

```bash
yarn run build:production
```

Useful local checks are:

```bash
yarn tsc
yarn test
```

The existing frontend test setup is based on Jest. It is separate from the
local-runner runtime itself.

## Troubleshooting

### HTTP 500 after install

Check `storage/logs/laravel.log` and verify that the user running the panel can
write to `storage/`, `bootstrap/cache/`, and the SQLite database.

### Resource-agent socket is missing

Check the agent status and log:

```bash
sudo /usr/local/sbin/pteroless-resource-agent status
sudo tail -n 40 /var/log/pteroless/resource-agent.log
```

Also check whether the host has the required cgroup v2 CPU and memory
controllers delegated.

### Server will not start

Check the startup command, runtime installed on the host, assigned port, and
`storage/app/servers/<server-uuid>/.local/logs/output.log`.

If the resource agent is enabled, also check the agent log and cgroup setup.

### Port is not reachable

The default local allocation is `127.0.0.1`. Check the allocation address,
the application's own listen address, firewall rules, reverse proxy, and the
hosting environment.

## Project layout

The parts you will touch most often are:

| Path | What it handles |
| --- | --- |
| `app/Services/Local/LocalServerService.php` | local node/server creation, storage paths, runtime presets |
| `app/Services/Local/LocalProcessManager.php` | process lifecycle, FIFO console, logs, and local stats |
| `app/Services/Local/ResourceAgentClient.php` | panel-side resource-agent client |
| `resources/local/` | privileged resource-agent source and launcher |
| `app/Http/Controllers/Api/Client/Servers/` | local server API controllers |
| `routes/api-client.php` | client routes for local resources, console, power, and file operations |
| `resources/scripts/` | React client frontend |
| `resources/views/` | Blade views and admin pages |
| `install.sh` | Debian/Ubuntu installer and resource-agent setup |
| `start.sh` | local panel launcher |

## Project status

Pteroless is still an experimental local-host panel. The local runner is useful,
but the inherited Pterodactyl surface is much larger than the local feature set.
Expect some pages and services to still be tied to Wings behavior.

Before treating it as production infrastructure, the big missing pieces are
stronger per-server isolation, a complete local backup/scheduling path,
working SFTP, proper service supervision, a real production web-server setup,
and a full security review.

## License

Pteroless is derived from the Pterodactyl Panel codebase.

- Upstream project: https://github.com/pterodactyl/panel
- Upstream license: https://github.com/pterodactyl/panel/blob/develop/LICENSE.md

The repository metadata declares MIT, but this checkout does not contain a
root `LICENSE` file. Keep the upstream license and required notices when
redistributing modified code.
