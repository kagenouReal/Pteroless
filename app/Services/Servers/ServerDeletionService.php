<?php
namespace Pterodactyl\Services\Servers;
use Illuminate\Http\Response;
use Pterodactyl\Models\Server;
use Illuminate\Support\Facades\Log;
use Illuminate\Database\ConnectionInterface;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Databases\DatabaseManagementService;
use Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException;
use Pterodactyl\Services\Local\LocalProcessManager;
use Pterodactyl\Services\Local\LocalServerService;
use Pterodactyl\Services\Local\ResourceAgentClient;
class ServerDeletionService
{
protected bool $force = false;
/**
* ServerDeletionService constructor.
*/
public function __construct(
private ConnectionInterface $connection,
private DaemonServerRepository $daemonServerRepository,
private DatabaseManagementService $databaseManagementService,
private LocalProcessManager $localProcesses,
private LocalServerService $localServers,
private ResourceAgentClient $resourceAgent,
) {
}
/**
 * Set if the server should be forcibly deleted from the panel despite remote cleanup errors.
*/
public function withForce(bool $bool = true): self
{
$this->force = $bool;
return $this;
}
/**
* Delete a server from the panel, clear any allocation notes, and remove any associated databases from hosts.
*
* @throws \Throwable
* @throws \Pterodactyl\Exceptions\DisplayException
*/
public function handle(Server $server): void
{
$isLocalRunner = LocalServerService::isLocalRunner($server);
if ($isLocalRunner) {
$this->localProcesses->stop($server, true);
if ($this->resourceAgent->isAvailable()) {
try {
$this->resourceAgent->remove($server);
} catch (\Throwable $exception) {
Log::warning($exception, ['server_id' => $server->id]);
}
}
$this->localServers->deleteDirectory($server);
} else {
try {
$this->daemonServerRepository->setServer($server)->delete();
} catch (DaemonConnectionException $exception) {
// If there is an error not caused a 404 error and this isn't a forced delete,
// go ahead and bail out. We specifically ignore a 404 since that can be assumed
// to be a safe error, meaning the server doesn't exist at all on Wings so there
// is no reason we need to bail out from that.
if (!$this->force && $exception->getStatusCode() !== Response::HTTP_NOT_FOUND) {
throw $exception;
}
Log::warning($exception);
}
}
$this->connection->transaction(function () use ($server, $isLocalRunner) {
foreach ($server->databases as $database) {
try {
$this->databaseManagementService->delete($database);
} catch (\Exception $exception) {
if (!$this->force && !$isLocalRunner) {
throw $exception;
}
// Oh well, just try to delete the database entry we have from the database
// so that the server itself can be deleted. This will leave it dangling on
// the host instance, but we couldn't delete it anyways so not sure how we would
// handle this better anyways.
//
// @see https://github.com/pterodactyl/panel/issues/2085
$database->delete();
Log::warning($exception);
}
}
// clear any allocation notes for the server
$server->allocations()->update(['notes' => null]);
$server->delete();
});
}
}
