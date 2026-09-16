#requires -Version 5.1
<#
.SYNOPSIS
    Upload one or more files to 拷入 / 李永超 / HM in the AnyShare shared link.

.DESCRIPTION
    Workspace-local replacement for the external upload-anyshare.ps1.
    The shared-link folder grid virtualizes its rows (only a handful of
    .item-name nodes exist in the DOM at once), so folder/file lookup must
    scroll the grid until the target becomes visible. The old script waited
    for visibility without scrolling, which timed out for folders below the
    first viewport page (e.g. 李永超).

.EXAMPLE
    .\upload_anyshare.ps1 .\dist\HMWorkFlow_1.2.3.zip -Folder '李永超/HM'

.EXAMPLE
    .\upload_anyshare.ps1 C:\Data\report.zip -Folder '李永超/HM' -DryRun

.NOTES
    The extraction code defaults to RMCF. It can be overridden with
    ANYSHARE_CODE or -Code. The script does not persist browser state.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [Alias('File')]
    [string[]] $Path,

    [string] $Folder = '李永超',

    [string] $Link = 'https://pan.sntonly.com/anyshare/zh-cn/link/AA0C8639B7CC8F4108A086190C4ABCC545',

    [string] $Code = $(
        if ([string]::IsNullOrWhiteSpace($env:ANYSHARE_CODE)) { 'RMCF' }
        else { $env:ANYSHARE_CODE }
    ),

    [switch] $ShowBrowser,

    [switch] $DryRun,

    [ValidateRange(1, 1440)]
    [int] $TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Get-PlainTextFromSecureString {
    param([Parameter(Mandatory = $true)][Security.SecureString] $SecureValue)
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
    }
}

if ([string]::IsNullOrWhiteSpace($Code)) {
    $Code = Get-PlainTextFromSecureString (Read-Host '请输入网盘提取码' -AsSecureString)
}

$resolvedFiles = @()
foreach ($item in $Path) {
    $candidate = (Resolve-Path -LiteralPath $item -ErrorAction Stop).Path
    if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
        throw "只支持上传文件，当前路径不是文件：$candidate"
    }
    $resolvedFiles += $candidate
}

if ($resolvedFiles.Count -eq 0) {
    throw '至少需要提供一个文件路径。'
}

$bundledRoot = Join-Path $env:USERPROFILE '.cache\codex-runtimes\codex-primary-runtime\dependencies'
$bundledNode = Join-Path $bundledRoot 'node\bin\node.exe'
$bundledPlaywright = Join-Path $bundledRoot 'node\node_modules\playwright\index.mjs'
$localPlaywright = Join-Path $PSScriptRoot 'node_modules\playwright\index.mjs'

if ((Test-Path -LiteralPath $bundledNode) -and (Test-Path -LiteralPath $bundledPlaywright)) {
    $nodeExe = $bundledNode
    $playwrightModule = $bundledPlaywright
}
elseif (Test-Path -LiteralPath $localPlaywright) {
    $nodeExe = (Get-Command node -ErrorAction Stop).Source
    $playwrightModule = $localPlaywright
}
else {
    throw @'
未找到 Playwright。请在脚本所在目录执行以下命令后重试：
  npm install playwright
本机需要已安装 Microsoft Edge 或 Google Chrome。
'@
}

$payload = @{
    link = $Link
    code = $Code
    folder = $Folder
    files = $resolvedFiles
    showBrowser = [bool]$ShowBrowser
    dryRun = [bool]$DryRun
    timeoutMs = $TimeoutMinutes * 60 * 1000
    playwrightModule = $playwrightModule
} | ConvertTo-Json -Compress

$payloadBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payload))
$tempScript = Join-Path ([IO.Path]::GetTempPath()) ("anyshare-upload-{0}.mjs" -f [Guid]::NewGuid().ToString('N'))

$nodeSource = @'
import { pathToFileURL } from 'node:url';
import path from 'node:path';

const config = JSON.parse(Buffer.from(process.argv[2], 'base64').toString('utf8'));
const { chromium } = await import(pathToFileURL(config.playwrightModule).href);
const folderPath = config.folder.split(/[\\/]/).map(value => value.trim()).filter(Boolean);

if (folderPath.length === 0) {
  throw new Error('目标文件夹路径不能为空。');
}

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

async function launchBrowser() {
  const options = { headless: !config.showBrowser };
  let lastError;
  for (const channel of ['msedge', 'chrome']) {
    try {
      return await chromium.launch({ ...options, channel });
    } catch (error) {
      lastError = error;
    }
  }
  try {
    return await chromium.launch(options);
  } catch (error) {
    throw new Error(`无法启动 Edge/Chrome：${error.message || lastError?.message || error}`);
  }
}

// The shared-link grid virtualizes its rows: only a small window of
// .item-name nodes exists in the DOM. findGridItem scrolls the scrollable
// grid body step by step until an item whose text matches `name` is visible,
// or returns null once the grid can no longer advance.
async function findGridItem(page, name) {
  const exactName = new RegExp(`^${escapeRegExp(name)}$`);
  const item = page.locator('.item-name').filter({ hasText: exactName }).first();
  const container = page.locator('.as-controls-data-grid-body').first();
  const maxScrolls = 120;
  await container.waitFor({ state: 'attached', timeout: 30000 }).catch(() => {});
  for (let i = 0; i < maxScrolls; i++) {
    if (await item.isVisible().catch(() => false)) {
      await item.scrollIntoViewIfNeeded().catch(() => {});
      return item;
    }
    const before = await container.evaluate(el => el.scrollTop).catch(() => 0);
    await container.evaluate(el => { el.scrollTop += Math.max(300, el.clientHeight * 0.9); }).catch(() => {});
    await page.waitForTimeout(200);
    const after = await container.evaluate(el => el.scrollTop).catch(() => 0);
    if (after <= before) break;
  }
  return null;
}

async function openFolder(page, name) {
  const item = await findGridItem(page, name);
  if (!item) throw new Error(`无法定位文件夹：${name}`);
  const oldUrl = page.url();
  try {
    await item.dblclick({ timeout: 10000 });
  } catch {
    const box = await item.boundingBox();
    if (!box) throw new Error(`无法定位文件夹：${name}`);
    await page.mouse.dblclick(box.x + Math.min(box.width / 2, 50), box.y + box.height / 2);
  }
  try {
    await page.waitForURL(url => url.toString() !== oldUrl, { timeout: 15000 });
  } catch {
    // Navigation may keep the same URL; rely on the item wait below.
  }
  await page.locator('.item-name').first().waitFor({ state: 'visible', timeout: 30000 });
  await page.waitForTimeout(1200);
}

let browser;
try {
  browser = await launchBrowser();
  const context = await browser.newContext({ acceptDownloads: false });
  const page = await context.newPage();
  page.setDefaultTimeout(30000);

  console.log('1/4 正在打开共享链接…');
  await page.goto(config.link, { waitUntil: 'domcontentloaded', timeout: 60000 });

  const codeInput = page.getByPlaceholder('此共享已加密，请输入提取码');
  await codeInput.waitFor({ state: 'visible', timeout: 15000 }).catch(() => {});
  if (await codeInput.isVisible().catch(() => false)) {
    console.log('2/4 正在验证提取码…');
    await codeInput.fill(config.code);
    await page.getByRole('button', { name: '确定', exact: true }).click();
  }

  await page.locator('.item-name').first().waitFor({ state: 'visible', timeout: 30000 });
  console.log('3/4 正在进入 拷入 / ' + folderPath.join(' / ') + '…');
  await openFolder(page, '拷入');
  for (const folder of folderPath) {
    await openFolder(page, folder);
  }

  const fileInput = page.locator('input[type="file"]').first();
  await fileInput.waitFor({ state: 'attached', timeout: 30000 });

  if (config.dryRun) {
    console.log(`检查成功：已进入“拷入 / ${folderPath.join(' / ')}”，上传控件可用。`);
    process.exitCode = 0;
  } else {
    console.log(`4/4 开始上传 ${config.files.length} 个文件…`);
    const failures = [];
    const badResponses = [];
    const pendingWrites = new Set();
    let trackWrites = false;
    let writeCount = 0;
    const isWriteRequest = request => !['GET', 'HEAD', 'OPTIONS'].includes(request.method().toUpperCase());

    page.on('request', request => {
      if (trackWrites && isWriteRequest(request)) {
        writeCount += 1;
        pendingWrites.add(request);
      }
    });
    page.on('requestfinished', request => pendingWrites.delete(request));
    page.on('requestfailed', request => {
      pendingWrites.delete(request);
      if (trackWrites && isWriteRequest(request)) {
        failures.push(`${request.method()} ${request.url()} - ${request.failure()?.errorText || 'request failed'}`);
      }
    });
    page.on('response', response => {
      const request = response.request();
      if (trackWrites && isWriteRequest(request) && response.status() >= 400) {
        badResponses.push(`${request.method()} ${response.url()} - HTTP ${response.status()}`);
      }
    });

    trackWrites = true;
    await fileInput.setInputFiles(config.files, { timeout: 30000 });
    const deadline = Date.now() + config.timeoutMs;
    let idleSince = null;
    while (Date.now() < deadline) {
      if (writeCount > 0 && pendingWrites.size === 0) {
        if (idleSince === null) idleSince = Date.now();
        if (Date.now() - idleSince >= 1500) break;
      } else {
        idleSince = null;
      }
      await page.waitForTimeout(250);
    }
    trackWrites = false;

    if (writeCount === 0) {
      throw new Error('选择文件后未检测到上传请求。');
    }
    if (pendingWrites.size > 0) {
      throw new Error(`等待上传请求结束超时，仍有 ${pendingWrites.size} 个请求未完成。`);
    }
    if (failures.length || badResponses.length) {
      throw new Error(`上传请求失败：\n${[...failures, ...badResponses].join('\n')}`);
    }

    // The filename appears in the page as soon as it enters the client-side
    // upload queue. Reload the folder before checking so only server-persisted
    // files can satisfy the completion condition.
    await page.reload({ waitUntil: 'domcontentloaded', timeout: 60000 });
    await page.locator('.item-name').first().waitFor({ state: 'visible', timeout: 30000 });
    for (const file of config.files) {
      const name = path.basename(file);
      const item = await findGridItem(page, name);
      if (!item) {
        throw new Error(`上传请求已结束，但刷新服务器目录后未找到文件：${name}`);
      }
      console.log(`  ✓ ${name}`);
    }
    console.log(`上传完成：${config.files.length} 个文件已进入“拷入 / ${folderPath.join(' / ')}”。`);
  }
} catch (error) {
  console.error(`上传失败：${error.message || error}`);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close();
}
'@

try {
    [IO.File]::WriteAllText($tempScript, $nodeSource, [Text.UTF8Encoding]::new($false))
    & $nodeExe $tempScript $payloadBase64
    $nodeExitCode = $LASTEXITCODE
    if ($nodeExitCode -ne 0) {
        exit $nodeExitCode
    }
}
finally {
    $Code = $null
    $payload = $null
    $payloadBase64 = $null
    if (Test-Path -LiteralPath $tempScript) {
        Remove-Item -LiteralPath $tempScript -Force
    }
}