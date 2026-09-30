# Flutter がビルド時に集めたライセンス全文（flutter_assets/NOTICES.Z、gzip）を平文に展開する
param([Parameter(Mandatory)] [string] $Source, [Parameter(Mandatory)] [string] $Destination)
$ErrorActionPreference = "Stop"
$compressed = [IO.File]::OpenRead($Source)
try {
  $gzip = New-Object IO.Compression.GZipStream($compressed, [IO.Compression.CompressionMode]::Decompress)
  $output = [IO.File]::Create($Destination)
  try { $gzip.CopyTo($output) } finally { $output.Dispose(); $gzip.Dispose() }
} finally { $compressed.Dispose() }
