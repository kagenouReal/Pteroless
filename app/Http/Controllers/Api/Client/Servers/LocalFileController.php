<?php
namespace Pterodactyl\Http\Controllers\Api\Client\Servers;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;
use Illuminate\Http\Response;
use Illuminate\Support\Str;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Local\LocalServerService;
use Pterodactyl\Services\Local\ResourceAgentClient;
use Symfony\Component\HttpFoundation\BinaryFileResponse;
use ZipArchive;
class LocalFileController extends ClientApiController
{
public function __construct(private LocalServerService $local, private ResourceAgentClient $resourceAgent) { parent::__construct(); }
private function root(Server $server): string { $this->local->ensureDirectory($server); return realpath($this->local->path($server)); }
private function hasDiskSpace(Server $server, int $additionalBytes = 0): bool
{
return !$this->resourceAgent->isAvailable()
|| $this->resourceAgent->hasDiskSpace($server, $additionalBytes);
}
private function assertUserPath(string $path, Server $server): void
{
$metadata = $this->local->metaPath($server);
abort_if($path === $metadata || str_starts_with($path . DIRECTORY_SEPARATOR, $metadata . DIRECTORY_SEPARATOR), 404, 'Path not found.');
}
private function safe(Server $server, string $path = '/'): string
{
$root = $this->root($server);
$path = '/' . ltrim(str_replace('\\', '/', $path), '/');
$candidate = $root . $path;
if (file_exists($candidate) || is_link($candidate)) {
$real = realpath($candidate);
abort_unless($real !== false && ($real === $root || str_starts_with($real . DIRECTORY_SEPARATOR, $root . DIRECTORY_SEPARATOR)), 422, 'Unsafe path.');
abort_if(is_link($candidate), 422, 'Symbolic links are disabled.');
$this->assertUserPath($real, $server);
return $real;
}
$parent = realpath(dirname($candidate));
abort_unless($parent !== false && ($parent === $root || str_starts_with($parent . DIRECTORY_SEPARATOR, $root . DIRECTORY_SEPARATOR)), 422, 'Unsafe path.');
$target = $parent . DIRECTORY_SEPARATOR . basename($candidate);
$this->assertUserPath($target, $server);
return $target;
}
private function object(string $path, string $name): array
{
$stat = @stat($path);
return [
'name' => $name,
'mode' => $stat ? decoct($stat['mode'] & 0777) : '0644',
'mode_bits' => $stat ? ($stat['mode'] & 0777) : 0644,
'size' => is_file($path) ? (int) filesize($path) : 0,
'is_file' => !is_dir($path),
'is_symlink' => is_link($path),
'mimetype' => is_file($path) ? (mime_content_type($path) ?: 'application/octet-stream') : 'inode/directory',
'created_at' => $stat ? date(DATE_ATOM, $stat['ctime']) : date(DATE_ATOM),
'modified_at' => $stat ? date(DATE_ATOM, $stat['mtime']) : date(DATE_ATOM),
];
}
public function directory(Request $request, Server $server): array
{
$dir = $this->safe($server, (string) $request->get('directory', '/'));
abort_unless(is_dir($dir), 404);
$isRoot = $dir === $this->root($server);
$items = [];
foreach (scandir($dir) ?: [] as $name) {
if ($name === '.' || $name === '..') continue;
if ($isRoot && $name === '.local') continue;
$full = $dir . '/' . $name;
if (is_link($full)) continue;
$items[] = $this->object($full, $name);
}
usort($items, fn ($a, $b) => [$b['is_file'] ? 1 : 0, strtolower($a['name'])] <=> [$a['is_file'] ? 1 : 0, strtolower($b['name'])]);
return ['object' => 'list', 'data' => array_map(fn ($x) => ['object' => 'file_object', 'attributes' => $x], $items)];
}
public function contents(Request $request, Server $server): Response
{
$file = $this->safe($server, (string) $request->get('file'));
abort_unless(is_file($file), 404);
abort_if(filesize($file) > (int) config('pterodactyl.files.max_edit_size', 102400), 413, 'File is too large to edit.');
return response((string) file_get_contents($file), 200)->header('Content-Type', 'text/plain; charset=utf-8');
}
public function download(Request $request, Server $server): BinaryFileResponse|JsonResponse|Response
{
$file = (string) $request->get('file');
$path = $this->safe($server, $file);
abort_unless(is_file($path), 404);
if ($request->boolean('direct')) return response()->download($path, basename($path));
return response()->json(['object' => 'signed_url', 'attributes' => ['url' => url('/api/client/servers/' . $server->uuid . '/files/download?file=' . rawurlencode($file) . '&direct=1')]]);
}
public function write(Request $request, Server $server): JsonResponse
{
$file = $this->safe($server, (string) $request->get('file'));
$dir = dirname($file);
abort_unless(is_dir($dir), 404);
$contents = $request->getContent();
$existingBytes = is_file($file) ? (int) filesize($file) : 0;
abort_if(!$this->hasDiskSpace($server, max(0, strlen($contents) - $existingBytes)), 507, 'Server disk limit reached. Delete files or increase the limit.');
$written = @file_put_contents($file, $contents, LOCK_EX);
abort_if($written === false || $written !== strlen($contents), 507, 'Insufficient storage space to write the file.');
return response()->json([], 204);
}
public function create(Request $request, Server $server): JsonResponse
{
$name = (string) $request->input('name');
abort_if($name === '' || basename($name) !== $name, 422, 'Invalid directory name.');
$path = $this->safe($server, (string) $request->input('root', '/') . '/' . $name);
abort_if(file_exists($path), 409, 'Path already exists.');
abort_if(!$this->hasDiskSpace($server), 507, 'Server disk limit reached. Delete files or increase the limit.');
abort_unless(@mkdir($path, 0750, true), 500, 'Unable to create directory.');
return response()->json([], 204);
}
public function rename(Request $request, Server $server): JsonResponse
{
$root = (string) $request->input('root', '/');
foreach ((array) $request->input('files', []) as $item) {
$from = $this->safe($server, $root . '/' . ($item['from'] ?? ''));
$to = $this->safe($server, $root . '/' . ($item['to'] ?? ''));
abort_if(file_exists($to), 409, 'Destination exists.');
rename($from, $to);
}
return response()->json([], 204);
}
public function copy(Request $request, Server $server): JsonResponse
{
$source = $this->safe($server, (string) $request->input('location'));
$dest = $this->safe($server, (string) $request->input('location') . '.copy');
abort_unless(is_file($source), 422, 'Only file copy is supported.');
$sourceBytes = (int) filesize($source);
$destinationBytes = is_file($dest) ? (int) filesize($dest) : 0;
abort_if(!$this->hasDiskSpace($server, max(0, $sourceBytes - $destinationBytes)), 507, 'Server disk limit reached. Delete files or increase the limit.');
abort_unless(@copy($source, $dest), 507, 'Insufficient storage space to copy the file.');
return response()->json([], 204);
}
public function compress(Request $request, Server $server): array
{
$root = (string) $request->input('root', '/');
$name = 'archive-' . date('Ymd-His') . '-' . Str::uuid() . '.zip';
$target = $this->safe($server, $root . '/' . $name);
$files = (array) $request->input('files', []);
$estimatedBytes = 0;
foreach ($files as $file) {
$rel = (string) $file;
$path = $this->safe($server, $root . '/' . $rel);
if (is_file($path)) {
$entryBytes = (int) filesize($path) + strlen($rel) + 128;
abort_if($entryBytes < 0 || $estimatedBytes > PHP_INT_MAX - $entryBytes, 413, 'Archive exceeds the supported size.');
$estimatedBytes += $entryBytes;
}
}
abort_if(!$this->hasDiskSpace($server, $estimatedBytes), 507, 'Server disk limit reached. Delete files or increase the limit.');
$zip = new ZipArchive();
abort_unless($zip->open($target, ZipArchive::CREATE | ZipArchive::OVERWRITE) === true, 507, 'Unable to create archive within the disk limit.');
foreach ($files as $file) {
$rel = (string) $file;
$path = $this->safe($server, $root . '/' . $rel);
if (is_file($path)) abort_unless($zip->addFile($path, $rel), 500, 'Unable to add file to archive.');
}
abort_unless($zip->close(), 507, 'Insufficient storage space to finish the archive.');
if (!$this->hasDiskSpace($server)) {
@unlink($target);
abort(507, 'Server disk limit reached. Delete files or increase the limit.');
}
return ['object' => 'file_object', 'attributes' => $this->object($target, $name)];
}
public function decompress(Request $request, Server $server): JsonResponse
{
$file = $this->safe($server, (string) $request->input('root', '/') . '/' . (string) $request->input('file'));
$zip = new ZipArchive();
abort_unless($zip->open($file) === true, 422, 'Invalid archive.');
$root = dirname($file);
$uncompressedBytes = 0;
for ($i = 0; $i < $zip->numFiles; $i++) {
$name = str_replace('\\', '/', (string) $zip->getNameIndex($i));
abort_if($name === '' || str_starts_with($name, '/') || preg_match('#(^|/)\.\.(/|$)#', $name), 422, 'Unsafe archive.');
$entry = $zip->statIndex($i);
abort_unless(is_array($entry) && array_key_exists('size', $entry), 422, 'Invalid archive entry.');
$entryBytes = (int) $entry['size'] + strlen($name) + 4096;
abort_if($entryBytes < 0 || $uncompressedBytes > PHP_INT_MAX - $entryBytes, 413, 'Archive expands beyond the supported size.');
$uncompressedBytes += $entryBytes;
}
if (!$this->hasDiskSpace($server, $uncompressedBytes)) {
$zip->close();
abort(507, 'Server disk limit reached. Delete files or increase the limit.');
}
abort_unless($zip->extractTo($root), 507, 'Insufficient storage space to extract the archive.');
$zip->close();
return response()->json([], 204);
}
public function delete(Request $request, Server $server): JsonResponse
{
$root = (string) $request->input('root', '/');
foreach ((array) $request->input('files', []) as $name) {
$path = $this->safe($server, $root . '/' . $name);
abort_if($path === $this->root($server), 422, 'Cannot delete server root.');
$this->remove($path);
}
return response()->json([], 204);
}
public function pull(Request $request, Server $server): JsonResponse
{
abort(501, 'Remote URL pulls are disabled in local mode. Upload the file through the panel instead.');
}
public function chmod(Request $request, Server $server): JsonResponse
{
$root = (string) $request->input('root', '/');
foreach ((array) $request->input('files', []) as $file) {
$path = $this->safe($server, $root . '/' . ($file['file'] ?? ''));
chmod($path, octdec((string) ($file['mode'] ?? '0644')));
}
return response()->json([], 204);
}
private function remove(string $path): void
{
if (is_dir($path)) {
foreach (scandir($path) ?: [] as $name) if ($name !== '.' && $name !== '..') $this->remove($path . '/' . $name);
@rmdir($path);
} else @unlink($path);
}
}
