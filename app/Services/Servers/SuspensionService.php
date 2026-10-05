<?php
namespace Pterodactyl\Services\Servers;
use Webmozart\Assert\Assert;
use Pterodactyl\Models\Server;
use Pterodactyl\Repositories\Wings\DaemonServerRepository;
use Pterodactyl\Services\Local\LocalProcessManager;
use Pterodactyl\Services\Local\LocalServerService;
use Symfony\Component\HttpKernel\Exception\ConflictHttpException;
class SuspensionService
{
public const ACTION_SUSPEND = 'suspend';
public const ACTION_UNSUSPEND = 'unsuspend';
/**
* SuspensionService constructor.
*/
public function __construct(
private DaemonServerRepository $daemonServerRepository,
private LocalProcessManager $localProcessManager,
) {
}
/**
* Suspends a server on the system.
*
* @throws \Throwable
*/
public function toggle(Server $server, string $action = self::ACTION_SUSPEND): void
{
Assert::oneOf($action, [self::ACTION_SUSPEND, self::ACTION_UNSUSPEND]);
$isSuspending = $action === self::ACTION_SUSPEND;
// Nothing needs to happen if we're suspending the server, and it is already
// suspended in the database. Additionally, nothing needs to happen if the server
// is not suspended, and we try to un-suspend the instance.
if ($isSuspending === $server->isSuspended()) {
return;
}
// Check if the server is currently being transferred.
if (!is_null($server->transfer)) {
throw new ConflictHttpException('Cannot toggle suspension status on a server that is currently being transferred.');
}
// Update the server's suspension status.
$server->update([
'status' => $isSuspending ? Server::STATUS_SUSPENDED : null,
]);
if (LocalServerService::isLocalRunner($server)) {
try {
if ($isSuspending) {
$this->localProcessManager->stop($server);
}
} catch (\Throwable $exception) {
$server->update([
'status' => $isSuspending ? null : Server::STATUS_SUSPENDED,
]);
throw $exception;
}
return;
}
try {
// Tell wings to re-sync the server state.
$this->daemonServerRepository->setServer($server)->sync();
} catch (\Exception $exception) {
// Rollback the server's suspension status if wings fails to sync the server.
$server->update([
'status' => $isSuspending ? null : Server::STATUS_SUSPENDED,
]);
throw $exception;
}
}
}
