import React, { useEffect } from 'react';
import { ServerContext, ServerStatus } from '@/state/server';
import http from '@/api/http';
import { SocketEvent, SocketRequest } from '@/components/server/events';
// Local runner compatibility layer. The original Pterodactyl UI expects a Wings websocket;
// local mode keeps the exact same UI contract but feeds it from the panel HTTP API instead.
class LocalSocket {
constructor(private uuid: string, private setServerStatus: (status: ServerStatus) => void) {}
private listeners = new Map<string, Set<(value: any) => void>>();
private lastLog = '';
private lastStatus: string | null = null;
private closed = false;
private pollRequest: Promise<void> | null = null;
addListener(event: string, callback: (value: any) => void) {
if (!this.listeners.has(event)) this.listeners.set(event, new Set());
this.listeners.get(event)!.add(callback);
}
removeListener(event: string, callback: (value: any) => void) {
this.listeners.get(event)?.delete(callback);
}
private emit(event: string, value: any) {
this.listeners.get(event)?.forEach((callback) => callback(value));
}
private emitStats(attributes: any) {
const resources = attributes.resources ?? {};
this.emit(SocketEvent.STATS, JSON.stringify({
memory_bytes: resources.memory_bytes ?? 0,
cpu_absolute: resources.cpu_absolute ?? 0,
disk_bytes: resources.disk_bytes ?? 0,
disk_limit_exceeded: resources.disk_limit_exceeded ?? false,
disk_limit_mode: resources.disk_limit_mode ?? 'display',
network_available: resources.network_available ?? false,
network: {
rx_bytes: resources.network_rx_bytes ?? 0,
tx_bytes: resources.network_tx_bytes ?? 0,
},
uptime: resources.uptime ?? 0,
}));
}
async send(event: string, value?: any) {
const uuid = this.uuid;
if (event === SocketRequest.SEND_LOGS) {
await this.poll(uuid);
} else if (event === SocketRequest.SEND_STATS) {
await this.poll(uuid);
} else if (event === 'send command') {
await http.post(`/api/client/servers/${uuid}/command`, { command: value });
} else if (event === SocketRequest.SET_STATE) {
await http.post(`/api/client/servers/${uuid}/power`, { signal: value });
await this.poll(uuid);
}
}
async poll(uuid: string): Promise<number> {
if (this.closed) return 0;
if (this.pollRequest) {
await this.pollRequest;
return this.closed ? 0 : 1500;
}
this.pollRequest = (async () => {
const { data } = await http.get(`/api/client/servers/${uuid}/snapshot`);
if (this.closed) return;
const payload = data ?? {};
const resources = payload.resources?.attributes ?? {};
const status = (resources.current_state ?? 'offline') as ServerStatus;
if (status !== this.lastStatus) {
this.lastStatus = status;
this.setServerStatus(status);
this.emit(SocketEvent.STATUS, status);
}
this.emitStats(resources);
const next = typeof payload.logs?.logs === 'string' ? payload.logs.logs : '';
if (next.length > this.lastLog.length && next.startsWith(this.lastLog)) {
this.emit(SocketEvent.CONSOLE_OUTPUT, next.slice(this.lastLog.length));
} else if (next !== this.lastLog) {
this.emit(SocketEvent.CONSOLE_OUTPUT, next);
}
this.lastLog = next;
})();
try {
await this.pollRequest;
} catch (error) {
console.error(error);
} finally {
this.pollRequest = null;
}
return this.closed ? 0 : 1500;
}
removeAllListeners() { this.listeners.clear(); }
close() { this.closed = true; }
}
export default () => {
const uuid = ServerContext.useStoreState((state) => state.server.data?.uuid);
const { setInstance, setConnectionState } = ServerContext.useStoreActions((actions) => actions.socket);
const setServerStatus = ServerContext.useStoreActions((actions) => actions.status.setServerStatus);
useEffect(() => {
if (!uuid) return;
const socket = new LocalSocket(uuid, setServerStatus);
setInstance(socket as any);
setConnectionState(true);
let active = true;
let timer: number | undefined;
let requestRunning = false;
const poll = async () => {
if (!active || document.visibilityState !== 'visible' || requestRunning) return;
requestRunning = true;
const interval = await socket.poll(uuid);
requestRunning = false;
if (active && interval > 0 && document.visibilityState === 'visible') {
timer = window.setTimeout(poll, interval);
}
};
const onVisibilityChange = () => {
if (document.visibilityState === 'hidden') {
if (timer !== undefined) window.clearTimeout(timer);
timer = undefined;
return;
}
if (timer !== undefined) window.clearTimeout(timer);
timer = undefined;
void poll();
};
document.addEventListener('visibilitychange', onVisibilityChange);
void poll();
return () => {
active = false;
if (timer !== undefined) window.clearTimeout(timer);
document.removeEventListener('visibilitychange', onVisibilityChange);
socket.close();
setConnectionState(false);
setInstance(null);
};
}, [uuid]);
return null;
};
