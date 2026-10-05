<?php

namespace Pterodactyl\Http\Controllers\Auth;

use Illuminate\Http\Request;
use Illuminate\Http\JsonResponse;
use Illuminate\Support\Facades\Password;
use Pterodactyl\Http\Controllers\Controller;
use Illuminate\Foundation\Auth\SendsPasswordResetEmails;

class ForgotPasswordController extends Controller
{
    use SendsPasswordResetEmails;

    protected function sendResetLinkFailedResponse(Request $request, $response): JsonResponse
    {
        return $this->sendResetLinkResponse($request, Password::RESET_LINK_SENT);
    }

    protected function sendResetLinkResponse(Request $request, $response): JsonResponse
    {
        return response()->json([
            'status' => trans($response),
        ]);
    }
}