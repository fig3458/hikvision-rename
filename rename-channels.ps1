# AIGC START
# 海康平台批量改通道名：GET 通道配置 → 改 <name> → PUT 回去
# 用法：
#   1. 浏览器登录 http://192.168.22.252 ，F12 → Application/存储 → Cookies，复制 WebSession_... 的值
#   2. Network 里任意请求 Headers 里复制 SessionTag
#   3. 编辑 names.csv（通道号,新名称）
#   4. 先试跑一条：.\rename-channels.ps1 -WebSessionValue "xxx" -SessionTag "yyy" -DryRun
#   5. 正式执行：.\rename-channels.ps1 -WebSessionValue "xxx" -SessionTag "yyy"

param(
    [Parameter(Mandatory = $true)]
    [string]$WebSessionValue,

    [Parameter(Mandatory = $true)]
    [string]$SessionTag,

    [string]$CookieName = "WebSession_4520699070",
    [string]$BaseUrl = "http://192.168.22.252",
    [string]$CsvPath = "$PSScriptRoot\names.csv",
    [int]$DelayMs = 800,
    [switch]$DryRun,
    [int]$OnlyChannel = 0
)

$ErrorActionPreference = "Stop"

function Get-CookieNameFromBrowser {
    param([string]$Value)
    return $Value
}

if (-not (Test-Path $CsvPath)) {
    throw "找不到名单文件: $CsvPath"
}

$rows = Import-Csv -Path $CsvPath -Encoding UTF8
if (-not $rows) {
    throw "names.csv 为空，请按 通道号,新名称 填写"
}

$session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
$session.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
$session.Cookies.Add((New-Object System.Net.Cookie("updatePlugin", "false", "/", "192.168.22.252")))
$session.Cookies.Add((New-Object System.Net.Cookie("downloadTips", "false", "/", "192.168.22.252")))
$session.Cookies.Add((New-Object System.Net.Cookie($CookieName, $WebSessionValue, "/", "192.168.22.252")))

$commonHeaders = @{
    "Accept"           = "application/json, text/plain, */*"
    "Accept-Language"  = "zh-CN,zh;q=0.9"
    "Origin"           = $BaseUrl
    "Referer"          = "$BaseUrl/doc/index.html"
    "SessionTag"       = $SessionTag
}

function Get-ChannelXml {
    param([int]$Id)
    $uri = "$BaseUrl/ISAPI/ContentMgmt/InputProxy/channels/$Id"
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method GET -WebSession $session -Headers $commonHeaders
    return $resp.Content
}

function Set-ChannelNameInXml {
    param(
        [string]$Xml,
        [string]$NewName
    )
    # 只替换 InputProxyChannel 下第一层 <name>...</name>
    if ($Xml -notmatch "<name>[^<]*</name>") {
        throw "响应里找不到 <name> 节点"
    }
    $safe = [System.Security.SecurityElement]::Escape($NewName)
    return [regex]::Replace($Xml, "<name>[^<]*</name>", "<name>$safe</name>", 1)
}

function Put-ChannelXml {
    param(
        [int]$Id,
        [string]$Xml
    )
    $uri = "$BaseUrl/ISAPI/ContentMgmt/InputProxy/channels/$Id"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Xml)
    return Invoke-WebRequest -UseBasicParsing -Uri $uri -Method PUT -WebSession $session -Headers $commonHeaders `
        -ContentType "application/xml; charset=`"UTF-8`"" `
        -Body $bytes
}

$ok = 0
$fail = 0
$skip = 0

foreach ($row in $rows) {
    $idText = "$($row.'通道号')".Trim()
    $newName = "$($row.'新名称')".Trim()

    if ([string]::IsNullOrWhiteSpace($idText) -or [string]::IsNullOrWhiteSpace($newName)) {
        continue
    }

    # 支持 37 / D37 / d37
    $idText = $idText -replace '^[Dd]', ''
    $id = [int]$idText

    if ($OnlyChannel -gt 0 -and $id -ne $OnlyChannel) {
        continue
    }

    Write-Host "`n==== 通道 $id → $newName ====" -ForegroundColor Cyan

    try {
        $xml = Get-ChannelXml -Id $id
        if ($xml -match "<name>([^<]*)</name>") {
            $oldName = $Matches[1]
            Write-Host "当前名称: $oldName"
            if ($oldName -eq $newName) {
                Write-Host "已是目标名，跳过" -ForegroundColor DarkYellow
                $skip++
                continue
            }
        }

        $newXml = Set-ChannelNameInXml -Xml $xml -NewName $newName

        if ($DryRun) {
            Write-Host "[DryRun] 不会真正 PUT" -ForegroundColor Yellow
            $ok++
        }
        else {
            $putResp = Put-ChannelXml -Id $id -Xml $newXml
            Write-Host "PUT 状态: $($putResp.StatusCode)" -ForegroundColor Green
            $ok++
        }
    }
    catch {
        Write-Host "失败: $($_.Exception.Message)" -ForegroundColor Red
        $fail++
    }

    Start-Sleep -Milliseconds $DelayMs
}

Write-Host "`n完成: 成功/试跑 $ok , 跳过 $skip , 失败 $fail" -ForegroundColor Cyan
if ($fail -gt 0) {
    Write-Host "若大量 401/403：重新从浏览器复制最新 WebSession 和 SessionTag" -ForegroundColor Yellow
}
# AIGC END
