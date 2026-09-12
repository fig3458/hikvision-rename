# AIGC START
# 海康通道批量改名 - 图形界面
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$BaseUrl = "http://192.168.22.252"
$script:running = $false

function New-Label($text, $x, $y, $w = 560, $h = 22) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
    return $l
}

function New-TextBox($x, $y, $w, $h, $multiline = $false) {
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object System.Drawing.Point($x, $y)
    $t.Size = New-Object System.Drawing.Size($w, $h)
    $t.Font = New-Object System.Drawing.Font("Consolas", 9)
    if ($multiline) {
        $t.Multiline = $true
        $t.ScrollBars = "Vertical"
        $t.AcceptsReturn = $true
        $t.WordWrap = $false
    }
    return $t
}

$form = New-Object System.Windows.Forms.Form
$form.Text = "海康监控通道批量改名"
$form.Size = New-Object System.Drawing.Size(720, 720)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = New-Object System.Drawing.Size(640, 600)

$form.Controls.Add((New-Label "① 先在浏览器打开并登录：http://192.168.22.252", 16, 12))
$form.Controls.Add((New-Label "② 按 F12 → 应用程序 → Cookies → 找到 WebSession_ 开头的项，把「名称」和「值」填下面", 16, 34, 680, 22))
$form.Controls.Add((New-Label "③ Network 里点任意请求，在右侧 Request Headers 复制 SessionTag", 16, 56, 680, 22))

$form.Controls.Add((New-Label "Cookie 名称（例如 WebSession_4520699070）", 16, 90))
$txtCookieName = New-TextBox 16 112 670 26
$txtCookieName.Text = "WebSession_4520699070"
$form.Controls.Add($txtCookieName)

$form.Controls.Add((New-Label "Cookie 值（一长串字符）", 16, 146))
$txtCookieValue = New-TextBox 16 168 670 26
$form.Controls.Add($txtCookieValue)

$form.Controls.Add((New-Label "SessionTag", 16, 202))
$txtSessionTag = New-TextBox 16 224 670 26
$form.Controls.Add($txtSessionTag)

$form.Controls.Add((New-Label "④ 名单：每行一条，格式  通道号,新名称   例如  37,负2楼10号电梯口   （也支持 D37）", 16, 260, 680, 22))
$txtNames = New-TextBox 16 284 670 160 $true
$txtNames.Text = "37,负2楼10号电梯口"
$form.Controls.Add($txtNames)

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "从 names.csv 加载"
$btnLoad.Location = New-Object System.Drawing.Point(16, 454)
$btnLoad.Size = New-Object System.Drawing.Size(140, 32)
$btnLoad.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$form.Controls.Add($btnLoad)

$chkDryRun = New-Object System.Windows.Forms.CheckBox
$chkDryRun.Text = "只演练不真正改名"
$chkDryRun.Location = New-Object System.Drawing.Point(170, 458)
$chkDryRun.Size = New-Object System.Drawing.Size(160, 28)
$chkDryRun.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 9)
$chkDryRun.Checked = $true
$form.Controls.Add($chkDryRun)

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "开始改名"
$btnStart.Location = New-Object System.Drawing.Point(500, 452)
$btnStart.Size = New-Object System.Drawing.Size(186, 36)
$btnStart.Font = New-Object System.Drawing.Font("Microsoft YaHei UI", 11, [System.Drawing.FontStyle]::Bold)
$btnStart.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnStart.ForeColor = [System.Drawing.Color]::White
$btnStart.FlatStyle = "Flat"
$form.Controls.Add($btnStart)

$form.Controls.Add((New-Label "运行日志", 16, 498))
$txtLog = New-TextBox 16 520 670 140 $true
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(220, 220, 220)
$form.Controls.Add($txtLog)

function Write-UiLog([string]$msg) {
    if ($txtLog.InvokeRequired) {
        $txtLog.Invoke([Action[string]] { param($m) Write-UiLog $m }, $msg) | Out-Null
        return
    }
    $txtLog.AppendText(("[{0}] {1}`r`n" -f (Get-Date -Format "HH:mm:ss"), $msg))
}

function Parse-NameList([string]$text) {
    $list = @()
    foreach ($line in ($text -split "`r?`n")) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#") -or $line -match '^通道号') { continue }
        $parts = $line -split "[,，\t]", 2
        if ($parts.Count -lt 2) { continue }
        $idText = $parts[0].Trim() -replace '^[Dd]', ''
        $name = $parts[1].Trim()
        if (-not $idText -or -not $name) { continue }
        $list += [pscustomobject]@{ Id = [int]$idText; Name = $name }
    }
    return $list
}

function Get-ChannelXml($session, $headers, $id) {
    $uri = "$BaseUrl/ISAPI/ContentMgmt/InputProxy/channels/$id"
    $resp = Invoke-WebRequest -UseBasicParsing -Uri $uri -Method GET -WebSession $session -Headers $headers
    return $resp.Content
}

function Set-NameInXml([string]$xml, [string]$newName) {
    if ($xml -notmatch "<name>[^<]*</name>") { throw "找不到 name 节点" }
    $safe = [System.Security.SecurityElement]::Escape($newName)
    return [regex]::Replace($xml, "<name>[^<]*</name>", "<name>$safe</name>", 1)
}

function Put-ChannelXml($session, $headers, $id, $xml) {
    $uri = "$BaseUrl/ISAPI/ContentMgmt/InputProxy/channels/$id"
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($xml)
    return Invoke-WebRequest -UseBasicParsing -Uri $uri -Method PUT -WebSession $session -Headers $headers `
        -ContentType "application/xml; charset=`"UTF-8`"" -Body $bytes
}

$btnLoad.Add_Click({
    $csv = Join-Path $PSScriptRoot "names.csv"
    if (-not (Test-Path $csv)) {
        [System.Windows.Forms.MessageBox]::Show("桌面 hikvision-rename 文件夹里没有 names.csv", "提示") | Out-Null
        return
    }
    $rows = Import-Csv -Path $csv -Encoding UTF8
    $lines = foreach ($r in $rows) {
        $a = "$($r.'通道号')".Trim()
        $b = "$($r.'新名称')".Trim()
        if ($a -and $b) { "$a,$b" }
    }
    $txtNames.Text = ($lines -join "`r`n")
    Write-UiLog "已从 names.csv 加载 $($lines.Count) 条"
})

$btnStart.Add_Click({
    if ($script:running) { return }

    $cookieName = $txtCookieName.Text.Trim()
    $cookieValue = $txtCookieValue.Text.Trim()
    $sessionTag = $txtSessionTag.Text.Trim()
    $dryRun = $chkDryRun.Checked
    $items = @(Parse-NameList $txtNames.Text)

    if (-not $cookieName -or -not $cookieValue -or -not $sessionTag) {
        [System.Windows.Forms.MessageBox]::Show("请先填写 Cookie 名称、Cookie 值、SessionTag", "缺少信息") | Out-Null
        return
    }
    if ($items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("名单是空的。每行写成：37,新名称", "缺少名单") | Out-Null
        return
    }

    $script:running = $true
    $btnStart.Enabled = $false
    $txtLog.Clear()
    Write-UiLog ("准备处理 {0} 条，模式：{1}" -f $items.Count, ($(if ($dryRun) { "只演练" } else { "真正改名" })))

    $runspace = [powershell]::Create().AddScript({
        param($BaseUrl, $cookieName, $cookieValue, $sessionTag, $items, $dryRun, $logCb, $doneCb)

        $ok = 0; $skip = 0; $fail = 0
        try {
            $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession
            $session.UserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/152.0.0.0 Safari/537.36"
            $session.Cookies.Add((New-Object System.Net.Cookie("updatePlugin", "false", "/", "192.168.22.252")))
            $session.Cookies.Add((New-Object System.Net.Cookie("downloadTips", "false", "/", "192.168.22.252")))
            $session.Cookies.Add((New-Object System.Net.Cookie($cookieName, $cookieValue, "/", "192.168.22.252")))

            $headers = @{
                "Accept"          = "application/json, text/plain, */*"
                "Accept-Language" = "zh-CN,zh;q=0.9"
                "Origin"          = $BaseUrl
                "Referer"         = "$BaseUrl/doc/index.html"
                "SessionTag"      = $sessionTag
            }

            foreach ($item in $items) {
                $id = $item.Id
                $newName = $item.Name
                & $logCb "通道 $id → $newName"
                try {
                    $uriGet = "$BaseUrl/ISAPI/ContentMgmt/InputProxy/channels/$id"
                    $resp = Invoke-WebRequest -UseBasicParsing -Uri $uriGet -Method GET -WebSession $session -Headers $headers
                    $xml = $resp.Content
                    $oldName = $null
                    if ($xml -match "<name>([^<]*)</name>") { $oldName = $Matches[1] }
                    & $logCb "  当前：$oldName"
                    if ($oldName -eq $newName) {
                        & $logCb "  已是目标名，跳过"
                        $skip++
                        Start-Sleep -Milliseconds 400
                        continue
                    }
                    $safe = [System.Security.SecurityElement]::Escape($newName)
                    $newXml = [regex]::Replace($xml, "<name>[^<]*</name>", "<name>$safe</name>", 1)
                    if ($dryRun) {
                        & $logCb "  [演练] 不会写入"
                        $ok++
                    }
                    else {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($newXml)
                        $put = Invoke-WebRequest -UseBasicParsing -Uri $uriGet -Method PUT -WebSession $session -Headers $headers `
                            -ContentType "application/xml; charset=`"UTF-8`"" -Body $bytes
                        & $logCb "  成功 HTTP $($put.StatusCode)"
                        $ok++
                    }
                }
                catch {
                    & $logCb ("  失败：" + $_.Exception.Message)
                    $fail++
                }
                Start-Sleep -Milliseconds 800
            }
            & $logCb "完成：成功/演练 $ok，跳过 $skip，失败 $fail"
            if ($fail -gt 0) {
                & $logCb "若大量失败：重新从浏览器复制最新 Cookie 值和 SessionTag"
            }
        }
        catch {
            & $logCb ("出错：" + $_.Exception.Message)
        }
        finally {
            & $doneCb
        }
    }).AddArgument($BaseUrl).AddArgument($cookieName).AddArgument($cookieValue).AddArgument($sessionTag).AddArgument($items).AddArgument($dryRun).AddArgument(
        [Action[string]] { param($m) Write-UiLog $m }
    ).AddArgument(
        [Action] {
            $script:running = $false
            if ($btnStart.InvokeRequired) {
                $btnStart.Invoke([Action] { $btnStart.Enabled = $true }) | Out-Null
            }
            else {
                $btnStart.Enabled = $true
            }
        }
    )

    $handle = $runspace.BeginInvoke()
    $null = $handle
})

[void]$form.ShowDialog()
# AIGC END
