#!/usr/bin/env python3

import argparse
import grp
import json
import logging
import os
import signal
import shutil
import socket
import socketserver
import subprocess
import struct
import threading
import time
import uuid
from pathlib import Path


class AgentError(RuntimeError):
    pass


class ResourceAgent:
    def __init__(self, args):
        self.socket_path = Path(args.socket)
        self.storage_root = Path(args.storage_root).resolve(strict=True)
        self.cgroup_root = Path(args.cgroup_root).resolve(strict=True)
        self.state_root = Path(args.state_root)
        self.allowed_uids = {int(value) for value in args.allowed_uids.split(",") if value}
        self._locks_guard = threading.Lock()
        self._server_locks = {}
        self._network_lock = threading.Lock()

    def _run(self, command, *, input_text=None):
        try:
            result = subprocess.run(
                command,
                input=input_text,
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
        except subprocess.TimeoutExpired as error:
            raise AgentError(f"Command timed out: {command[0]}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "command failed"
            raise AgentError(detail[:500])
        return result.stdout

    def _server(self, message):
        try:
            server_uuid = str(uuid.UUID(message["uuid"]))
        except (KeyError, TypeError, ValueError, AttributeError) as error:
            raise AgentError("Invalid server identity.") from error

        original_path = self.storage_root / server_uuid
        if original_path.is_symlink():
            raise AgentError("Server storage path must not be a symbolic link.")
        path = original_path.resolve(strict=True)
        if path.parent != self.storage_root or path.name != server_uuid or not path.is_dir():
            raise AgentError("Server storage path is invalid.")
        return server_uuid, path

    def _limits(self, message):
        try:
            cpu = int(message.get("cpu", 0))
            memory = int(message.get("memory", 0))
            disk = int(message.get("disk", 0))
        except (TypeError, ValueError) as error:
            raise AgentError("Resource limits must be integers.") from error
        if cpu < 0 or cpu > 100000 or memory < 0 or memory > 1048576 or disk < 0 or disk > 1048576:
            raise AgentError("Resource limits are outside the supported range.")
        return cpu, memory, disk

    def _cgroup_path(self, server_uuid):
        return self.cgroup_root / "servers" / server_uuid

    def _ensure_cgroup(self, server_uuid, cpu, memory):
        available = set((self.cgroup_root / "cgroup.controllers").read_text().split())
        required = {"cpu", "memory"}
        if not required.issubset(available):
            missing = ", ".join(sorted(required - available))
            raise AgentError(f"Host cgroup v2 controllers are unavailable: {missing}.")

        subtree = self.cgroup_root / "cgroup.subtree_control"
        enabled = set(subtree.read_text().split())
        missing = required - enabled
        if missing:
            subtree.write_text(" ".join(f"+{name}" for name in sorted(missing)))

        servers = self.cgroup_root / "servers"
        servers.mkdir(mode=0o755, exist_ok=True)
        available = set((servers / "cgroup.controllers").read_text().split())
        if not required.issubset(available):
            missing = ", ".join(sorted(required - available))
            raise AgentError(f"Server cgroup controllers are unavailable: {missing}.")
        subtree = servers / "cgroup.subtree_control"
        enabled = set(subtree.read_text().split())
        missing = required - enabled
        if missing:
            subtree.write_text(" ".join(f"+{name}" for name in sorted(missing)))

        path = self._cgroup_path(server_uuid)
        path.mkdir(mode=0o755, exist_ok=True)

        period = 100000
        quota = "max" if cpu == 0 else str(cpu * 1000)
        (path / "cpu.max").write_text(f"{quota} {period}")
        (path / "memory.max").write_text("max" if memory == 0 else str(memory * 1024 * 1024))
        return path

    def _disk_state(self, server_uuid):
        state_file = self.state_root / f"{server_uuid}.json"
        try:
            return json.loads(state_file.read_text())
        except (FileNotFoundError, json.JSONDecodeError, OSError):
            return {}

    def _lock_for_server(self, server_uuid):
        with self._locks_guard:
            return self._server_locks.setdefault(server_uuid, threading.RLock())

    def _write_state(self, server_uuid, state):
        self.state_root.mkdir(mode=0o750, parents=True, exist_ok=True)
        state_file = self.state_root / f"{server_uuid}.json"
        temporary = state_file.with_suffix(".tmp")
        temporary.write_text(json.dumps(state))
        os.chmod(temporary, 0o640)
        os.replace(temporary, state_file)

    def _set_disk_limit(self, server_uuid, disk_mib):
        with self._lock_for_server(server_uuid):
            state = self._disk_state(server_uuid)
            state["disk_mib"] = disk_mib
            state["disk_limit_exceeded"] = False
            self._write_state(server_uuid, state)

    def _nft(self, text):
        return self._run(["nft", "-f", "-"], input_text=text)

    def _network_rule(self, server_uuid, direction):
        relative_cgroup = self._cgroup_path(server_uuid).relative_to("/sys/fs/cgroup").as_posix()
        level = len(Path(relative_cgroup).parts)
        comment = f"pteroless:{server_uuid}:{direction}"
        return (
            f'socket cgroupv2 level {level} "{relative_cgroup}" '
            f'counter comment "{comment}"'
        )

    def _ensure_network(self, server_uuid):
        with self._network_lock:
            return self._ensure_network_locked(server_uuid)

    def _ensure_network_locked(self, server_uuid):
        if shutil.which("nft") is None:
            return False

        try:
            relative_cgroup = self._cgroup_path(server_uuid).relative_to("/sys/fs/cgroup").as_posix()
        except ValueError:
            return False
        if not relative_cgroup or ".." in Path(relative_cgroup).parts:
            return False

        table = self._run(["nft", "list", "table", "inet", "pteroless_local"]) if self._table_exists() else ""
        if not table:
            self._nft(
                "add table inet pteroless_local\n"
                "add chain inet pteroless_local input { type filter hook input priority filter; policy accept; }\n"
                "add chain inet pteroless_local output { type filter hook output priority filter; policy accept; }\n"
            )

        ruleset = json.loads(self._run(["nft", "-j", "list", "table", "inet", "pteroless_local"]))
        comments = set()
        for item in ruleset.get("nftables", []):
            rule = item.get("rule", {})
            comment = rule.get("comment")
            if comment:
                comments.add(comment)
            for expression in rule.get("expr", []):
                if isinstance(expression, dict) and expression.get("comment"):
                    comments.add(expression["comment"])

        additions = []
        for direction in ("rx", "tx"):
            comment = f"pteroless:{server_uuid}:{direction}"
            if comment not in comments:
                chain = "input" if direction == "rx" else "output"
                additions.append(
                    f"add rule inet pteroless_local {chain} {self._network_rule(server_uuid, direction)}"
                )
        if additions:
            self._nft("\n".join(additions) + "\n")
        return True

    def _table_exists(self):
        try:
            result = subprocess.run(
                ["nft", "list", "table", "inet", "pteroless_local"],
                text=True,
                capture_output=True,
                check=False,
                timeout=10,
            )
        except subprocess.TimeoutExpired as error:
            raise AgentError("Timed out checking the nftables resource table.") from error
        if result.returncode == 0:
            return True
        if "No such file or directory" in result.stderr:
            return False
        raise AgentError((result.stderr.strip() or "Unable to inspect nftables.").strip()[:500])

    def _network_stats(self, server_uuid):
        try:
            try:
                ruleset = json.loads(self._run(["nft", "-j", "list", "table", "inet", "pteroless_local"]))
            except json.JSONDecodeError as error:
                raise AgentError("nftables returned invalid JSON.") from error
        except (AgentError, json.JSONDecodeError):
            return False, None, None

        values = {"rx": None, "tx": None}
        for item in ruleset.get("nftables", []):
            rule = item.get("rule", {})
            comment = rule.get("comment")
            expressions = rule.get("expr", [])
            if not comment:
                comment = next(
                    (
                        expression["comment"]
                        for expression in expressions
                        if isinstance(expression, dict) and expression.get("comment")
                    ),
                    None,
                )
            if not comment or not comment.startswith(f"pteroless:{server_uuid}:"):
                continue
            direction = comment.rsplit(":", 1)[-1]
            counter = next(
                (
                    expression["counter"]
                    for expression in expressions
                    if isinstance(expression, dict) and "counter" in expression
                ),
                None,
            )
            if direction in values and counter:
                values[direction] = int(counter.get("bytes", 0))

        if values["rx"] is None or values["tx"] is None:
            return False, None, None
        return True, values["rx"], values["tx"]

    def _remove_network(self, server_uuid):
        with self._network_lock:
            self._remove_network_locked(server_uuid)

    def _remove_network_locked(self, server_uuid):
        if shutil.which("nft") is None or not self._table_exists():
            return
        ruleset = json.loads(self._run(["nft", "-j", "list", "table", "inet", "pteroless_local"]))
        commands = []
        for item in ruleset.get("nftables", []):
            rule = item.get("rule", {})
            comment = rule.get("comment")
            if not comment:
                comment = next(
                    (
                        expression["comment"]
                        for expression in rule.get("expr", [])
                        if isinstance(expression, dict) and expression.get("comment")
                    ),
                    None,
                )
            if comment and comment.startswith(f"pteroless:{server_uuid}:"):
                commands.append(
                    f"delete rule inet pteroless_local {rule['chain']} handle {int(rule['handle'])}"
                )
        if commands:
            self._nft("\n".join(commands) + "\n")

    def _disk_usage(self, server_uuid, path, force=False):
        with self._lock_for_server(server_uuid):
            state = self._disk_state(server_uuid)
            now = time.time()
            sampled_at = float(state.get("disk_sampled_at", 0))
            if not force and 0 <= now - sampled_at < 5 and "disk_bytes" in state:
                return int(state["disk_bytes"])

            output = self._run(["du", "-s", "--block-size=1", "--", str(path)])
            try:
                usage = int(output.split(None, 1)[0])
            except (IndexError, ValueError) as error:
                raise AgentError("Unable to measure server disk usage.") from error
            state["disk_sampled_at"] = now
            state["disk_bytes"] = usage
            self._write_state(server_uuid, state)
            return usage

    def _check_disk_limit(self, server_uuid, path, cgroup, disk_mib, populated, force=False):
        disk_bytes = self._disk_usage(server_uuid, path, force=force)
        exceeded = disk_mib > 0 and disk_bytes >= disk_mib * 1024 * 1024
        with self._lock_for_server(server_uuid):
            state = self._disk_state(server_uuid)
            state["disk_limit_exceeded"] = exceeded
            if exceeded and populated:
                self._kill_cgroup(cgroup)
            self._write_state(server_uuid, state)
            return disk_bytes, exceeded

    def _kill_cgroup(self, cgroup):
        if not cgroup.is_dir():
            return
        kill_file = cgroup / "cgroup.kill"
        if kill_file.is_file():
            kill_file.write_text("1")
            return

        deadline = time.monotonic() + 1
        while time.monotonic() < deadline:
            pids = []
            for value in (cgroup / "cgroup.procs").read_text().splitlines():
                try:
                    pids.append(int(value))
                except ValueError as error:
                    raise AgentError("The server cgroup contains an invalid process ID.") from error
            if not pids:
                return
            for pid in pids:
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    continue
            time.sleep(0.05)
        raise AgentError("Unable to stop all processes in the server cgroup.")

    def monitor_disk_limits(self, stop_event):
        servers_root = self.cgroup_root / "servers"
        while not stop_event.wait(5):
            try:
                if not servers_root.is_dir():
                    continue
                for cgroup in servers_root.iterdir():
                    if cgroup.is_symlink() or not cgroup.is_dir():
                        continue
                    try:
                        server_uuid = str(uuid.UUID(cgroup.name))
                        with self._lock_for_server(server_uuid):
                            state = self._disk_state(server_uuid)
                            disk_mib = int(state.get("disk_mib", 0))
                            if disk_mib <= 0:
                                continue
                            events = (cgroup / "cgroup.events").read_text().splitlines()
                            populated = any(line == "populated 1" for line in events)
                            if not populated:
                                continue
                            path = self.storage_root / server_uuid
                            if path.is_symlink():
                                raise AgentError("Server storage path must not be a symbolic link.")
                            path = path.resolve(strict=True)
                            if path.parent != self.storage_root or path.name != server_uuid or not path.is_dir():
                                raise AgentError("Server storage path is invalid.")
                            self._check_disk_limit(server_uuid, path, cgroup, disk_mib, populated, force=True)
                    except FileNotFoundError:
                        continue
                    except (AgentError, OSError, ValueError):
                        logging.exception("Unable to enforce the soft disk limit for cgroup %s.", cgroup.name)
            except OSError:
                logging.exception("Unable to scan local server cgroups for disk-limit enforcement.")

    def _cpu_percent(self, server_uuid, usage_usec):
        self.state_root.mkdir(mode=0o750, parents=True, exist_ok=True)
        with self._lock_for_server(server_uuid):
            now = time.monotonic()
            previous = self._disk_state(server_uuid)
            elapsed = now - float(previous.get("sampled_at", now))
            old_usage = int(previous.get("usage_usec", usage_usec))
            percent = 0.0
            if elapsed >= 0.1:
                percent = max(0.0, (usage_usec - old_usage) / (elapsed * 10000))
            previous["sampled_at"] = now
            previous["usage_usec"] = usage_usec
            self._write_state(server_uuid, previous)
            return round(percent, 2)

    def _peer_cgroup(self, peer_pid):
        for line in Path(f"/proc/{peer_pid}/cgroup").read_text().splitlines():
            if line.startswith("0::"):
                return line[3:]
        raise AgentError("Unable to verify the requesting process cgroup.")

    def handle(self, message, peer_uid, peer_pid):
        if peer_uid not in self.allowed_uids:
            raise AgentError("The requesting process is not authorized.")
        try:
            delegated_path = self.cgroup_root.relative_to("/sys/fs/cgroup").as_posix()
        except ValueError:
            delegated_path = ""
        if delegated_path:
            server_cgroup = f"/{delegated_path}/servers"
            peer_cgroup = self._peer_cgroup(peer_pid)
            if peer_cgroup == server_cgroup or peer_cgroup.startswith(server_cgroup + "/"):
                raise AgentError("Processes inside managed server cgroups cannot access the resource agent.")
        action = message.get("action")
        if action == "capabilities":
            return {
                "cgroup_v2": (self.cgroup_root / "cgroup.controllers").is_file(),
                "network_accounting": shutil.which("nft") is not None,
            }

        server_uuid, path = self._server(message)
        if action == "disk":
            _, _, disk = self._limits(message)
            self._set_disk_limit(server_uuid, disk)
            cgroup = self._cgroup_path(server_uuid)
            events_file = cgroup / "cgroup.events"
            populated = events_file.is_file() and any(
                line == "populated 1" for line in events_file.read_text().splitlines()
            )
            disk_bytes, disk_limit_exceeded = self._check_disk_limit(
                server_uuid, path, cgroup, disk, populated, force=True
            )
            return {
                "disk_bytes": disk_bytes,
                "disk_limit_exceeded": disk_limit_exceeded,
                "disk_limit_mode": "soft" if disk > 0 else "unlimited",
            }

        if action in {"ensure", "stats"}:
            cpu, memory, disk = self._limits(message)
            if action == "ensure":
                self._set_disk_limit(server_uuid, disk)
            cgroup = self._ensure_cgroup(server_uuid, cpu, memory)
            if action == "ensure":
                events = (cgroup / "cgroup.events").read_text().splitlines()
                populated = any(line == "populated 1" for line in events)
                disk_bytes, disk_limit_exceeded = self._check_disk_limit(
                    server_uuid, path, cgroup, disk, populated, force=True
                )
                try:
                    network_available = self._ensure_network(server_uuid)
                except AgentError:
                    network_available = False
                return {
                    "cgroup_v2": True,
                    "disk_bytes": disk_bytes,
                    "disk_limit_exceeded": disk_limit_exceeded,
                    "disk_limit_mode": "soft" if disk > 0 else "unlimited",
                    "network_accounting": network_available,
                }

            cpu_stat = {}
            for line in (cgroup / "cpu.stat").read_text().splitlines():
                key, value = line.split(None, 1)
                cpu_stat[key] = int(value)
            memory_bytes = int((cgroup / "memory.current").read_text())
            events = (cgroup / "cgroup.events").read_text().splitlines()
            populated = any(line == "populated 1" for line in events)
            available, rx, tx = self._network_stats(server_uuid)
            disk_bytes, disk_limit_exceeded = self._check_disk_limit(
                server_uuid, path, cgroup, disk, populated
            )
            return {
                "memory_bytes": memory_bytes,
                "cgroup_populated": populated,
                "cpu_absolute": self._cpu_percent(server_uuid, cpu_stat.get("usage_usec", 0)),
                "disk_bytes": disk_bytes,
                "disk_limit_exceeded": disk_limit_exceeded,
                "disk_limit_mode": "soft" if disk > 0 else "unlimited",
                "network_available": available,
                "network_rx_bytes": rx,
                "network_tx_bytes": tx,
            }

        if action == "attach":
            pid = int(message.get("pid", 0))
            if pid < 1 or not Path(f"/proc/{pid}/status").is_file():
                raise AgentError("The process to attach does not exist.")
            status = Path(f"/proc/{pid}/status").read_text()
            uid_line = next((line for line in status.splitlines() if line.startswith("Uid:")), "")
            state_line = next((line for line in status.splitlines() if line.startswith("State:")), "")
            if not uid_line or int(uid_line.split()[1]) not in self.allowed_uids:
                raise AgentError("The process to attach has an unauthorized owner.")
            if not state_line or state_line.split()[1] not in {"T", "t"}:
                raise AgentError("The process must be paused before it is attached.")
            process_path = Path(f"/proc/{pid}/cwd").resolve(strict=True)
            if process_path != path and path not in process_path.parents:
                raise AgentError("The process is outside its server directory.")
            cpu, memory, _ = self._limits(message)
            cgroup = self._ensure_cgroup(server_uuid, cpu, memory)
            (cgroup / "cgroup.procs").write_text(str(pid))
            return {"attached": True}

        if action == "kill":
            cgroup = self._cgroup_path(server_uuid)
            self._kill_cgroup(cgroup)
            return {"stopped": True}

        if action == "remove":
            cgroup = self._cgroup_path(server_uuid)
            self._kill_cgroup(cgroup)
            deadline = time.monotonic() + 5
            while (cgroup / "cgroup.events").is_file():
                events = (cgroup / "cgroup.events").read_text()
                populated = next((line.split()[1] for line in events.splitlines() if line.startswith("populated ")), "0")
                if populated == "0" or time.monotonic() >= deadline:
                    break
                time.sleep(0.05)
            with self._lock_for_server(server_uuid):
                try:
                    cgroup.rmdir()
                except FileNotFoundError:
                    pass
                except OSError as error:
                    raise AgentError("The server cgroup is not empty.") from error
                self._remove_network(server_uuid)
                (self.state_root / f"{server_uuid}.json").unlink(missing_ok=True)
            return {"removed": True}

        raise AgentError("Unsupported resource agent action.")


class RequestHandler(socketserver.StreamRequestHandler):
    def setup(self):
        self.request.settimeout(5)
        super().setup()

    def handle(self):
        try:
            raw = self.rfile.readline(16385)
            if len(raw) > 16384 or not raw.endswith(b"\n"):
                raise AgentError("Request is too large or incomplete.")
            message = json.loads(raw)
            credentials = self.request.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
            peer_pid, peer_uid, _ = struct.unpack("3i", credentials)
            if not isinstance(message, dict):
                raise AgentError("Request must be a JSON object.")
            result = self.server.agent.handle(message, peer_uid, peer_pid)
            response = {"ok": True, "data": result}
        except (AgentError, AttributeError, KeyError, TypeError, ValueError, OSError, json.JSONDecodeError) as error:
            response = {"ok": False, "error": str(error)[:500]}
        self.wfile.write(json.dumps(response, separators=(",", ":")).encode() + b"\n")


class UnixServer(socketserver.ThreadingUnixStreamServer):
    allow_reuse_address = True
    daemon_threads = True
    request_queue_size = 32

    def __init__(self, path, agent):
        self.agent = agent
        self._request_limit = threading.BoundedSemaphore(16)
        super().__init__(str(path), RequestHandler)

    def process_request(self, request, client_address):
        if not self._request_limit.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self._request_limit.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._request_limit.release()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--socket", required=True)
    parser.add_argument("--socket-group", required=True)
    parser.add_argument("--allowed-uids", required=True)
    parser.add_argument("--storage-root", required=True)
    parser.add_argument("--cgroup-root", required=True)
    parser.add_argument("--state-root", default="/var/lib/pteroless-resource-agent")
    args = parser.parse_args()

    socket_path = Path(args.socket)
    socket_path.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
    try:
        if socket_path.is_socket():
            socket_path.unlink()
    except OSError:
        raise

    agent = ResourceAgent(args)
    server = UnixServer(socket_path, agent)
    os.chown(socket_path, 0, grp.getgrnam(args.socket_group).gr_gid)
    os.chmod(socket_path, 0o660)
    monitor_stop = threading.Event()
    monitor_thread = threading.Thread(
        target=agent.monitor_disk_limits,
        args=(monitor_stop,),
        name="disk-limit-monitor",
        daemon=True,
    )
    monitor_thread.start()
    try:
        server.serve_forever()
    finally:
        monitor_stop.set()
        monitor_thread.join(timeout=6)
        server.server_close()
        socket_path.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
