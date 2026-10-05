<?php
namespace Pterodactyl\Services\Local;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use RuntimeException;
class LocalProcessManager
{
private const SIGNAL_CONT = 18;
private const SIGNAL_KILL = 9;
private const SIGNAL_TERM = 15;
private const STATS_TTL_SECONDS = 1.0;
private const LOGS_TTL_SECONDS = 0.5;
private array $statsCache = [];
private array $logsCache = [];
public function __construct(private LocalServerService $local, private ResourceAgentClient $agent)
{
}
private function pidFile(Server $server): string { return $this->local->metaPath($server) . '/pid'; }
private function logFile(Server $server): string { return $this->local->metaPath($server) . '/logs/output.log'; }
private function fifo(Server $server): string { return $this->local->metaPath($server) . '/stdin.fifo'; }
private function invalidateCache(Server $server): void
{
unset($this->statsCache[$server->uuid], $this->logsCache[$server->uuid]);
}
public function pid(Server $server): int
{
$this->local->ensureDirectory($server);
if (!is_file($this->pidFile($server))) return 0;
$pid = (int) trim((string) file_get_contents($this->pidFile($server)));
if ($pid < 1 || !$this->alive($pid)) {
@unlink($this->pidFile($server));
return 0;
}
return $pid;
}
private function processGroups(Server $server): array
{
$root = realpath($this->local->path($server));
$startup = trim($server->startup);
if ($root === false || $startup === '') return [];
$commands = preg_split('/\s*(?:&&|\|\||;)\s*/', $startup) ?: [];
$groups = [];
foreach (glob('/proc/[0-9]*/cwd') ?: [] as $cwd) {
if (@readlink($cwd) !== $root) continue;
$pid = (int) basename(dirname($cwd));
$cmdline = str_replace("\0", ' ', (string) @file_get_contents('/proc/' . $pid . '/cmdline'));
if ($cmdline === '') continue;
$matches = str_contains($cmdline, $startup);
foreach ($commands as $command) {
$command = trim(preg_replace('/^(?:(?:else|exec)\s+)+/', '', trim($command)) ?? $command);
if ($command !== '' && str_contains($cmdline, $command)) {
$matches = true;
break;
}
}
if (!$matches) continue;
$stat = @file_get_contents('/proc/' . $pid . '/stat');
$close = $stat === false ? false : strrpos($stat, ')');
if ($close === false) continue;
$fields = preg_split('/\s+/', trim(substr($stat, $close + 1)));
if (($fields[0] ?? '') === 'Z') continue;
$group = (int) ($fields[2] ?? 0);
if ($group > 0) $groups[$group][] = $pid;
}
return $groups;
}
private function processStat(int $pid): ?array
{
$stat = @file_get_contents('/proc/' . $pid . '/stat');
$close = $stat === false ? false : strrpos($stat, ')');
if ($close === false) return null;
$fields = preg_split('/\s+/', trim(substr($stat, $close + 1)));
if (count($fields) < 20) return null;
return [
'state' => $fields[0],
'group' => (int) $fields[2],
'user_ticks' => (int) $fields[11],
'system_ticks' => (int) $fields[12],
'start_ticks' => (int) $fields[19],
];
}
private function cpuUsage(Server $server, array $samples): float
{
$file = @fopen($this->local->metaPath($server) . '/cpu-sample.json', 'c+');
if ($file === false) return 0.0;
try {
if (!flock($file, LOCK_EX)) return 0.0;
rewind($file);
$previous = json_decode((string) stream_get_contents($file), true);
if (!is_array($previous)) $previous = [];
$now = microtime(true);
$elapsed = $now - (float) ($previous['sampled_at'] ?? 0);
$cpu = (float) ($previous['cpu'] ?? 0);
if ($previous === [] || $elapsed >= 0.5 || $samples === []) {
$deltaTicks = 0;
if ($elapsed >= 0.5) {
foreach ($samples as $processId => $sample) {
$old = $previous['processes'][$processId] ?? null;
if (is_array($old) && (int) ($old['start_ticks'] ?? -1) === $sample['start_ticks']) {
$deltaTicks += max(0, $sample['ticks'] - (int) $old['ticks']);
}
}
$ticksPerSecond = max(1, (int) shell_exec('getconf CLK_TCK 2>/dev/null'));
$cpu = round(($deltaTicks / $ticksPerSecond) / $elapsed * 100, 2);
} elseif ($samples === []) {
$cpu = 0.0;
}
ftruncate($file, 0);
rewind($file);
fwrite($file, json_encode([
'sampled_at' => $now,
'cpu' => $cpu,
'processes' => $samples,
]));
}
return $cpu;
} finally {
flock($file, LOCK_UN);
fclose($file);
}
}
private function alive(int $pid): bool
{
if (function_exists('posix_kill')) {
return @posix_kill($pid, 0) || @posix_kill(-$pid, 0);
}
if (is_dir('/proc/' . $pid)) return true;
foreach (glob('/proc/[0-9]*/stat') ?: [] as $statFile) {
$stat = @file_get_contents($statFile);
$close = $stat === false ? false : strrpos($stat, ')');
if ($close === false) continue;
$fields = preg_split('/\s+/', trim(substr($stat, $close + 1)));
if ((int) ($fields[2] ?? 0) === $pid && ($fields[0] ?? '') !== 'Z') return true;
}
return false;
}
private function signalGroup(int $group, int $signal): void
{
if (function_exists('posix_kill')) {
@posix_kill(-$group, $signal);
return;
}
$name = $signal === self::SIGNAL_KILL ? 'KILL' : 'TERM';
@exec('/bin/kill -' . $name . ' -- -' . $group . ' 2>/dev/null');
}
private function clockTicks(): int
{
$ticks = (int) shell_exec('getconf CLK_TCK 2>/dev/null');
return $ticks > 0 ? $ticks : 100;
}
public function isRunning(Server $server): bool
{
return $this->pid($server) > 0 || $this->processGroups($server) !== [];
}
public function start(Server $server): int
{
$this->invalidateCache($server);
$this->local->ensureDirectory($server);
$lock = @fopen($this->local->metaPath($server) . '/start.lock', 'c');
if ($lock === false) throw new RuntimeException('Unable to acquire the process start lock.');
try {
if (!flock($lock, LOCK_EX)) throw new RuntimeException('Unable to acquire the process start lock.');
return $this->startLocked($server);
} finally {
flock($lock, LOCK_UN);
fclose($lock);
}
}
private function startLocked(Server $server): int
{
$this->local->ensureDirectory($server);
$agentEnabled = $this->agent->isAvailable();
if ($agentEnabled) {
$limits = $this->agent->ensure($server);
if ($limits['disk_limit_exceeded'] ?? false) {
throw new RuntimeException('This server is over its disk limit. Delete files or increase the limit before starting it.');
}
}
if ($this->isRunning($server)) {
$pid = $this->pid($server);
if ($agentEnabled && !($this->agent->stats($server)['cgroup_populated'] ?? false)) {
throw new RuntimeException('This server is already running without resource controls. Stop it, then start it again to apply the configured limits.');
}
if ($pid > 0) return $pid;
$groups = $this->processGroups($server);
return $groups === [] ? 0 : (int) array_key_first($groups);
}
$command = trim($server->startup);
if ($command === '') throw new RuntimeException('Startup command is empty.');
$fifo = $this->fifo($server);
if (file_exists($fifo)) @unlink($fifo);
if (!function_exists('posix_mkfifo') || !@posix_mkfifo($fifo, 0600)) {
throw new RuntimeException('Unable to create the local command pipe.');
}
$root = escapeshellarg($this->local->path($server));
$log = escapeshellarg($this->logFile($server));
$pipe = escapeshellarg($fifo);
$memory = (int) $server->memory;
$port = (int) ($server->allocation?->port ?? 0);
$portEnvironment = $port > 0 ? 'export PORT=' . $port . '; export SERVER_PORT=' . $port . '; ' : '';
$cpuSet = trim((string) $server->threads);
$limits = '';
$usesNode = preg_match('/\b(?:node|nodejs|npm|npx|yarn|pnpm)\b/i', $command) === 1;
$usesJava = preg_match('/\bjava\b/i', $command) === 1;
$usesGo = preg_match('/\bgo\b/i', $command) === 1;
if ($memory > 0 && $usesNode) {
$heapLimit = max(64, min(4096, (int) floor($memory * 0.7)));
$nodeOptions = trim((string) getenv('NODE_OPTIONS') . ' --max-old-space-size=' . $heapLimit);
$limits .= 'export NODE_OPTIONS=' . escapeshellarg($nodeOptions) . '; ';
} elseif ($memory > 0 && $usesJava) {
$heapLimit = max(64, min(4096, (int) floor($memory * 0.7)));
$javaOptions = trim((string) getenv('JAVA_TOOL_OPTIONS') . ' -Xmx' . $heapLimit . 'm');
$limits .= 'export JAVA_TOOL_OPTIONS=' . escapeshellarg($javaOptions) . '; ';
} elseif ($memory > 0 && $usesGo) {
$memoryLimit = max(64, (int) floor($memory * 0.7));
$limits .= 'export GOMEMLIMIT=' . escapeshellarg($memoryLimit . 'MiB') . '; ';
} elseif ($memory > 0) {
$limits .= 'ulimit -v ' . ($memory * 1024) . '; ';
}
$limits .= 'ulimit -n 4096; ';
$taskset = $cpuSet !== '' && preg_match('/^[0-9,-]+$/', $cpuSet) ? 'taskset -c ' . escapeshellarg($cpuSet) . ' ' : '';
$quoted = escapeshellarg($command);
$home = escapeshellarg($this->local->metaPath($server) . '/home');
$pauseForCgroup = $agentEnabled ? 'kill -STOP "$$"; ' : '';
$shell = "cd {$root}; mkdir -p {$home}; export HOME={$home}; {$pauseForCgroup}{$portEnvironment}{$limits} exec {$taskset}bash -lc {$quoted} <>{$pipe} >>{$log} 2>&1";
$launch = 'nohup setsid bash -lc ' . escapeshellarg($shell) . ' </dev/null >/dev/null 2>&1 & echo $!';
$output = [];
$exit = 0;
exec($launch, $output, $exit);
$pid = isset($output[0]) ? (int) trim($output[0]) : 0;
if ($exit !== 0 || $pid < 1) {
@unlink($fifo);
throw new RuntimeException('Unable to start the local process.');
}
file_put_contents($this->pidFile($server), (string) $pid, LOCK_EX);
file_put_contents($this->logFile($server), "\n===== START " . date(DATE_ATOM) . " =====\n", FILE_APPEND | LOCK_EX);
if ($agentEnabled) {
$deadline = microtime(true) + 5;
$stopped = false;
do {
$stat = $this->processStat($pid);
if ($stat !== null && in_array($stat['state'], ['T', 't'], true)) {
$stopped = true;
break;
}
usleep(10000);
} while (microtime(true) < $deadline);
if (!$stopped) {
$this->signalGroup($pid, self::SIGNAL_KILL);
@unlink($this->pidFile($server));
@unlink($this->fifo($server));
throw new RuntimeException('The local process did not pause for resource control.');
}
try {
$this->agent->attach($server, $pid);
if (function_exists('posix_kill')) {
if (!@posix_kill($pid, self::SIGNAL_CONT)) {
throw new RuntimeException('Unable to resume the process after resource control was applied.');
}
} else {
exec('/bin/kill -CONT ' . $pid . ' 2>/dev/null', $output, $exit);
if ($exit !== 0) {
throw new RuntimeException('Unable to resume the process after resource control was applied.');
}
}
} catch (\Throwable $exception) {
$this->signalGroup($pid, self::SIGNAL_KILL);
@unlink($this->pidFile($server));
@unlink($this->fifo($server));
throw new RuntimeException('Unable to attach the local process to its resource cgroup: ' . $exception->getMessage(), 0, $exception);
}
}
return $pid;
}
public function stop(Server $server, bool $force = false): void
{
$this->invalidateCache($server);
$agentEnabled = $this->agent->isAvailable();
$pid = $this->pid($server);
$groups = $this->processGroups($server);
if ($pid > 0) $groups[$pid] = $pid;
if ($groups === []) {
if ($agentEnabled) {
$this->agent->kill($server);
}
@unlink($this->pidFile($server));
@unlink($this->fifo($server));
return;
}
$signal = $force ? self::SIGNAL_KILL : self::SIGNAL_TERM;
foreach (array_keys($groups) as $group) {
$this->signalGroup((int) $group, $signal);
}
if (!$force) usleep(300000);
if ($agentEnabled) {
$this->agent->kill($server);
}
if (!$force) {
foreach (array_keys($this->processGroups($server)) as $group) {
$this->signalGroup((int) $group, self::SIGNAL_KILL);
}
if ($pid > 0 && $this->alive($pid)) $this->signalGroup($pid, self::SIGNAL_KILL);
}
@unlink($this->pidFile($server));
@unlink($this->fifo($server));
}
public function restart(Server $server): int
{
$this->stop($server);
return $this->start($server);
}
public function command(Server $server, string $command): void
{
$this->invalidateCache($server);
if (!$this->isRunning($server)) throw new RuntimeException('Server must be running.');
$fifo = $this->fifo($server);
if (!file_exists($fifo) || @filetype($fifo) !== 'fifo') throw new RuntimeException('Command pipe is unavailable.');
$handle = @fopen($fifo, 'wb');
if (!$handle) throw new RuntimeException('Unable to send command to the process.');
fwrite($handle, $command . PHP_EOL);
fclose($handle);
}
public function logs(Server $server, int $bytes = 50000): string
{
$this->local->ensureDirectory($server);
$file = $this->logFile($server);
$key = $server->uuid;
if (!is_file($file)) {
$this->logsCache[$key] = ['expires_at' => microtime(true) + self::LOGS_TTL_SECONDS, 'size' => 0, 'mtime' => 0, 'value' => ''];
return '';
}
$state = @stat($file);
$size = $state['size'] ?? filesize($file);
$mtime = $state['mtime'] ?? filemtime($file);
$cached = $this->logsCache[$key] ?? null;
if (is_array($cached)
&& ($cached['expires_at'] ?? 0) > microtime(true)
&& ($cached['size'] ?? null) === $size
&& ($cached['mtime'] ?? null) === $mtime
) {
return $cached['value'];
}
if ($size === false || $size <= $bytes) {
$value = (string) file_get_contents($file);
} else {
$handle = fopen($file, 'rb');
if (!$handle) return '';
fseek($handle, -$bytes, SEEK_END);
$value = stream_get_contents($handle);
fclose($handle);
$value = $value === false ? '' : $value;
}
$this->logsCache[$key] = [
'expires_at' => microtime(true) + self::LOGS_TTL_SECONDS,
'size' => $size,
'mtime' => $mtime,
'value' => $value,
];
return $value;
}
public function stats(Server $server): array
{
$key = $server->uuid;
$now = microtime(true);
$cached = $this->statsCache[$key] ?? null;
if (is_array($cached) && ($cached['expires_at'] ?? 0) > $now) {
return $cached['value'];
}
$pid = $this->pid($server);
$groups = $this->processGroups($server);
$processIds = $pid > 0 ? [$pid] : [];
foreach ($groups as $members) $processIds = array_merge($processIds, $members);
$processIds = array_values(array_unique($processIds));
$pidStat = $pid > 0 ? $this->processStat($pid) : null;
$running = $groups !== [] || ($pidStat !== null && $pidStat['state'] !== 'Z');
$memory = 0;
$uptime = 0;
$samples = [];
foreach ($processIds as $processId) {
$stat = $this->processStat((int) $processId);
if ($stat === null || $stat['state'] === 'Z') continue;
$status = @file_get_contents('/proc/' . $processId . '/status') ?: '';
if (preg_match('/^VmRSS:\s+(\d+)\s+kB/m', $status, $m)) $memory += (int) $m[1] * 1024;
$samples[$processId] = [
'ticks' => $stat['user_ticks'] + $stat['system_ticks'],
'start_ticks' => $stat['start_ticks'],
];
}
$agentEnabled = $this->agent->isAvailable();
$cpu = $running ? $this->cpuUsage($server, $samples) : 0.0;
$uptimePid = $pid > 0 && isset($samples[$pid]) ? $pid : 0;
if ($uptimePid < 1) {
foreach ($groups as $group => $members) {
if (isset($samples[$group])) {
$uptimePid = (int) $group;
break;
}
foreach ($members as $member) {
if (isset($samples[$member])) {
$uptimePid = $member;
break 2;
}
}
}
}
if ($uptimePid > 0) {
$boot = (float) @file_get_contents('/proc/uptime');
if ($boot > 0) $uptime = (int) max(0, $boot - ($samples[$uptimePid]['start_ticks'] / $this->clockTicks())) * 1000;
}
$disk = $agentEnabled ? 0 : $this->diskUsage($server);
$networkAvailable = false;
$networkRx = null;
$networkTx = null;
$diskLimitExceeded = false;
$diskLimitMode = 'display';
if ($agentEnabled) {
try {
$resources = $this->agent->stats($server);
} catch (\Throwable $exception) {
Log::warning($exception, ['server_id' => $server->id, 'operation' => 'resource-agent-stats']);
$agentEnabled = false;
$disk = $this->diskUsage($server);
}
}
if ($agentEnabled) {
$managed = !$running || (bool) ($resources['cgroup_populated'] ?? false);
if ($managed) {
$memory = (int) $resources['memory_bytes'];
$cpu = $running ? (float) $resources['cpu_absolute'] : 0.0;
} else {
$networkAvailable = false;
}
$disk = (int) $resources['disk_bytes'];
$diskLimitExceeded = (bool) ($resources['disk_limit_exceeded'] ?? false);
$diskLimitMode = (string) ($resources['disk_limit_mode'] ?? ($server->disk > 0 ? 'soft' : 'unlimited'));
if ($managed) {
$networkAvailable = (bool) $resources['network_available'];
$networkRx = $resources['network_rx_bytes'];
$networkTx = $resources['network_tx_bytes'];
}
}
$stats = [
'state' => $running ? 'running' : 'offline',
'is_suspended' => false,
'utilization' => [
'memory_bytes' => $memory,
'cpu_absolute' => $cpu,
'disk_bytes' => $disk,
'disk_limit_exceeded' => $diskLimitExceeded,
'disk_limit_mode' => $diskLimitMode,
'network_available' => $networkAvailable,
'network' => ['rx_bytes' => $networkRx, 'tx_bytes' => $networkTx],
'uptime' => $uptime,
],
];
$this->statsCache[$key] = [
'expires_at' => microtime(true) + self::STATS_TTL_SECONDS,
'value' => $stats,
];
return $stats;
}
private function diskUsage(Server $server): int
{
$cacheFile = $this->local->metaPath($server) . '/disk-usage.json';
$cached = json_decode((string) @file_get_contents($cacheFile), true);
if (is_array($cached) && (int) ($cached['updated_at'] ?? 0) > time() - 30) {
return (int) ($cached['bytes'] ?? 0);
}
$path = $this->local->path($server);
$out = [];
exec('du -sb ' . escapeshellarg($path) . ' 2>/dev/null', $out);
$bytes = isset($out[0]) && preg_match('/^(\d+)/', $out[0], $m) ? (int) $m[1] : 0;
@file_put_contents($cacheFile, json_encode(['bytes' => $bytes, 'updated_at' => time()]), LOCK_EX);
return $bytes;
}
}
