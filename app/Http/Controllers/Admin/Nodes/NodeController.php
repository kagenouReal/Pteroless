<?php
namespace Pterodactyl\Http\Controllers\Admin\Nodes;
use Illuminate\View\View;
use Illuminate\Http\Request;
use Pterodactyl\Models\Node;
use Spatie\QueryBuilder\QueryBuilder;
use Pterodactyl\Http\Controllers\Controller;
use Pterodactyl\Services\Local\LocalServerService;
class NodeController extends Controller
{
/**
* Returns a listing of nodes on the system.
*/
public function index(Request $request): View
{
$nodes = QueryBuilder::for(
Node::query()->with('location')->withCount('servers')
)
->allowedFilters(['uuid', 'name'])
->allowedSorts(['id'])
->paginate(25);
$hasLocalNode = Node::query()->get()->contains(fn (Node $node) => LocalServerService::isLocalNode($node));
return view('admin.nodes.index', ['nodes' => $nodes, 'hasLocalNode' => $hasLocalNode]);
}
}
