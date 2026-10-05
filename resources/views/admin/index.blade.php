@extends('layouts.admin')
@section('title')
Administration
@endsection
@section('content-header')
<h1>Administrative Overview<small>A quick glance at your system.</small></h1>
<ol class="breadcrumb">
<li><a href="{{ route('admin.index') }}">Admin</a></li>
<li class="active">Index</li>
</ol>
@endsection
@section('content')
<div class="row">
<div class="col-xs-12">
<div class="box box-primary">
<div class="box-header with-border">
<h3 class="box-title">System Information</h3>
</div>
<div class="box-body">
Pteroless is running version <code>{{ config('app.version') }}</code>.
</div>
</div>
</div>
</div>
<div class="row">
<div class="col-xs-12 col-sm-4 text-center">
<a href="https://github.com/kagenouReal/Pteroless" target="_blank" rel="noopener noreferrer"><button class="btn btn-primary" style="width:100%;"><i class="fa fa-fw fa-github"></i> GitHub</button></a>
</div>
<div class="col-xs-12 col-sm-4 text-center">
<a href="https://wa.me/kagenouReal" target="_blank" rel="noopener noreferrer"><button class="btn btn-success" style="width:100%;"><i class="fa fa-fw fa-whatsapp"></i> WhatsApp</button></a>
</div>
<div class="col-xs-12 col-sm-4 text-center">
<a href="https://www.tiktok.com/@veryy_lazyy" target="_blank" rel="noopener noreferrer"><button class="btn btn-info" style="width:100%;"><i class="fa fa-fw fa-music"></i> TikTok</button></a>
</div>
</div>
@endsection
