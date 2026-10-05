<?php
namespace Pterodactyl\Http\Controllers\Api\Client\Servers;
use Illuminate\Http\Request;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Models\Server;
use Pterodactyl\Services\Local\LocalServerService;
use Pterodactyl\Services\Local\ResourceAgentClient;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
class LocalFileUploadController extends ClientApiController
{
public function __construct(private LocalServerService $local, private ResourceAgentClient $resourceAgent) { parent::__construct(); }
public function __invoke(Request $request, Server $server): JsonResponse
{
if ($request->isMethod('GET')) {
return response()->json(['attributes' => ['url' => url()->current()]]);
}
$this->local->ensureDirectory($server);
$directory = '/' . ltrim(str_replace('\\', '/', (string) $request->input('directory', '/')), '/');
abort_if(str_contains($directory, '..'), 422, 'Unsafe directory.');
$root = realpath($this->local->path($server));
$targetDir = realpath($this->local->path($server) . $directory);
abort_unless($targetDir !== false && ($targetDir === $root || str_starts_with($targetDir . DIRECTORY_SEPARATOR, $root . DIRECTORY_SEPARATOR)), 422, 'Unsafe directory.');
$file = $request->file('files');
abort_unless($file && $file->isValid(), 422, 'Upload failed.');
$name = basename((string) $file->getClientOriginalName());
abort_if($name === '' || $name === '.' || $name === '..', 422, 'Invalid filename.');
if ($this->resourceAgent->isAvailable()) {
$target = $targetDir . DIRECTORY_SEPARATOR . $name;
$existingBytes = is_file($target) ? (int) filesize($target) : 0;
$additionalBytes = max(0, (int) $file->getSize() - $existingBytes);
abort_if(!$this->resourceAgent->hasDiskSpace($server, $additionalBytes), 507, 'Server disk limit reached. Delete files or increase the limit.');
}
$file->move($targetDir, $name);
return response()->json([], 200);
}
}
