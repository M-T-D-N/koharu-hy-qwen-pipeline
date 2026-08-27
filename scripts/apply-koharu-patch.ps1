[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$KoharuCheckout
)

$ErrorActionPreference = 'Stop'
$expectedCommit = 'a81c5829ea99a45e04580ff97fd6affa81b2db34'
$root = Split-Path -Parent $PSScriptRoot
$patch = Join-Path $root 'patches\koharu-a81c5829-headless-api-mcp.patch'
$checkout = (Resolve-Path -LiteralPath $KoharuCheckout).Path

if (-not (Test-Path -LiteralPath (Join-Path $checkout '.git'))) {
    throw "Not a Koharu Git checkout: $checkout"
}
if (-not (Test-Path -LiteralPath $patch -PathType Leaf)) {
    throw "Patch is missing: $patch"
}

$headOutput = & git -C $checkout rev-parse HEAD
if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect the Koharu checkout: $checkout"
}
$head = ($headOutput | Out-String).Trim()
if ($head -ne $expectedCommit) {
    throw "Patch requires Koharu commit $expectedCommit; observed $head"
}
$dirty = & git -C $checkout status --porcelain
if ($LASTEXITCODE -ne 0) {
    throw "Failed to inspect Koharu working-tree state: $checkout"
}
if ($dirty) {
    throw 'Koharu checkout must be clean before applying the patch.'
}

& git -C $checkout apply --check $patch
if ($LASTEXITCODE -ne 0) {
    throw 'Koharu patch preflight failed.'
}
& git -C $checkout apply $patch
if ($LASTEXITCODE -ne 0) {
    throw 'Koharu patch application failed.'
}

[pscustomobject]@{
    status = 'applied'
    checkout = $checkout
    base_commit = $expectedCommit
    patch = $patch
} | ConvertTo-Json
