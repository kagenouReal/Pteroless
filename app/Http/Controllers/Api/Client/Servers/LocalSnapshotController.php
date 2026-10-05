<?php
namespace Pterodactyl\Http\Controllers\Api\Client\Servers;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Models\Server;
use Pterodactyl\Transformers\Api\Client\StatsTransformer;
use Pterodactyl\Services\Local\LocalProcessManager;
use Pterodactyl\Http\Controllers\Api\Client\ClientApiController;
use Pterodactyl\Http\Requests\Api\Client\Servers\GetServerRequest;
class LocalSnapshotController extends ClientApiController
{
public function __construct(private LocalProcessManager $processes)
{
parent::__construct();
}
public function __invoke(GetServerRequest $request, Server $server): JsonResponse
{
$resources = $this->fractal->item($this->processes->stats($server))
->transformWith($this->getTransformer(StatsTransformer::class))
->toArray();
return response()->json([
'resources' => $resources,
'logs' => [
'running' => ($resources['attributes']['current_state'] ?? 'offline') === 'running',
'logs' => $this->processes->logs($server),
],
]);
}
}
