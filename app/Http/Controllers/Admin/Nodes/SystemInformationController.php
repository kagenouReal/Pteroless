<?php
namespace Pterodactyl\Http\Controllers\Admin\Nodes;
use Illuminate\Support\Str;
use Illuminate\Http\Request;
use Pterodactyl\Models\Node;
use Illuminate\Http\JsonResponse;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Local\LocalServerService;
use Pterodactyl\Repositories\Wings\DaemonConfigurationRepository;
class SystemInformationController extends Controller
{
/**
* SystemInformationController constructor.
*/
public function __construct(private DaemonConfigurationRepository $repository)
{
}
/**
* Returns system information from the Daemon.
*
* @throws \Pterodactyl\Exceptions\Http\Connection\DaemonConnectionException
*/
public function __invoke(Request $request, Node $node): JsonResponse
{
if (LocalServerService::isLocalNode($node)) {
$processors = 0;
if (is_readable('/proc/cpuinfo')) {
preg_match_all('/^processor\s*:/m', file_get_contents('/proc/cpuinfo'), $matches);
$processors = count($matches[0]);
}
return new JsonResponse([
'version' => 'Pteroless Local Runner',
'system' => [
'type' => Str::title(PHP_OS_FAMILY),
'arch' => php_uname('m'),
'release' => php_uname('r'),
'cpus' => $processors,
],
]);
}
$data = $this->repository->setNode($node)->getSystemInformation();
return new JsonResponse([
'version' => $data['version'] ?? '',
'system' => [
'type' => Str::title($data['os'] ?? 'Unknown'),
'arch' => $data['architecture'] ?? '--',
'release' => $data['kernel_version'] ?? '--',
'cpus' => (int) ($data['cpu_count'] ?? 0),
],
]);
}
}
