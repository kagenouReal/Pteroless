<?php
namespace Pterodactyl\Services\Local;
use JsonException;
use Pterodactyl\Models\Server;
use RuntimeException;
class ResourceAgentClient
{
public function isAvailable(): bool
{
return @filetype($this->socketPath()) === 'socket';
}
public function ensure(Server $server): array
{
return $this->request($this->serverPayload($server) + ['action' => 'ensure']);
}
public function ensureDiskLimit(Server $server): array
{
return $this->request($this->serverPayload($server) + ['action' => 'disk']);
}
public function hasDiskSpace(Server $server, int $additionalBytes = 0): bool
{
if ($additionalBytes < 0 || $additionalBytes > PHP_INT_MAX - 4096) {
return false;
}
$resources = $this->ensureDiskLimit($server);
$diskBytes = $resources['disk_bytes'] ?? null;
$limitExceeded = $resources['disk_limit_exceeded'] ?? null;
if (!is_int($diskBytes) || $diskBytes < 0 || !is_bool($limitExceeded)) {
throw new RuntimeException('The local resource agent returned invalid disk-limit data.');
}
$limit = (int) $server->disk * 1024 * 1024;
if ($limit <= 0) {
return true;
}
$additionalBytes += 4096;
$usage = $diskBytes;
return !$limitExceeded
&& $usage <= PHP_INT_MAX - $additionalBytes
&& $usage + $additionalBytes < $limit;
}
public function attach(Server $server, int $pid): array
{
return $this->request($this->serverPayload($server) + [
'action' => 'attach',
'pid' => $pid,
]);
}
public function stats(Server $server): array
{
return $this->request($this->serverPayload($server) + ['action' => 'stats']);
}
public function kill(Server $server): array
{
return $this->request($this->serverPayload($server) + ['action' => 'kill']);
}
public function remove(Server $server): array
{
return $this->request($this->serverPayload($server) + ['action' => 'remove']);
}
private function serverPayload(Server $server): array
{
return [
'uuid' => $server->uuid,
'cpu' => (int) $server->cpu,
'memory' => (int) $server->memory,
'disk' => (int) $server->disk,
];
}
private function socketPath(): string
{
return (string) config('pterodactyl.local.resource_agent_socket');
}
private function request(array $payload): array
{
$path = $this->socketPath();
$socket = @stream_socket_client('unix://' . $path, $errno, $error, 2);
if ($socket === false) {
throw new RuntimeException("Unable to connect to the local resource agent: {$error} ({$errno}).");
}
try {
stream_set_timeout($socket, 3);
$request = json_encode($payload, JSON_THROW_ON_ERROR) . "\n";
if (fwrite($socket, $request) !== strlen($request)) {
throw new RuntimeException('Unable to send a complete request to the local resource agent.');
}
$line = fgets($socket, 65537);
if ($line === false || strlen($line) > 65536) {
throw new RuntimeException('The local resource agent returned an empty or oversized response.');
}
$response = json_decode($line, true, 512, JSON_THROW_ON_ERROR);
if (!is_array($response) || !($response['ok'] ?? false)) {
$detail = is_array($response) ? (string) ($response['error'] ?? 'Unknown agent error.') : 'Invalid agent response.';
throw new RuntimeException("The local resource agent rejected the request: {$detail}");
}
$data = $response['data'] ?? null;
if (!is_array($data)) {
throw new RuntimeException('The local resource agent returned an invalid data payload.');
}
return $data;
} catch (JsonException $exception) {
throw new RuntimeException('The local resource agent returned invalid JSON.', 0, $exception);
} finally {
fclose($socket);
}
}
}
