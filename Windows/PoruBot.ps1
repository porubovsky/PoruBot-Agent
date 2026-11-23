#requires -Version 5.1
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()
$providers = @(
    @{Name='Antigravity'; Bin='agy'; Key='GEMINI_API_KEY'; URL='https://antigravity.google/cli/install.cmd'; Ext='cmd'; Models=@('gemini-3.8-flash','gemini-3.7-flash','gemini-3.6-flash')},
    @{Name='Claude Code'; Bin='claude'; Key='ANTHROPIC_API_KEY'; URL='https://claude.ai/install.cmd'; Ext='cmd'; Models=@('sonnet','haiku','opus')},
    @{Name='Codex'; Bin='codex'; Key='CODEX_API_KEY'; URL='https://chatgpt.com/codex/install.ps1'; Ext='ps1'; Models=@('gpt-5.4-mini','gpt-5.4')},
    @{Name='OpenRouter'; Bin='claude'; Key='OPENROUTER_API_KEY'; URL='https://claude.ai/install.cmd'; Ext='cmd'; Models=@('~anthropic/claude-sonnet-latest','~anthropic/claude-haiku-latest','~anthropic/claude-opus-latest')}
)
$secrets = @{}
$script:job = $null
$script:catalog = @{}
$script:selected = 0
$script:timeout = $null
$utf8 = New-Object Text.UTF8Encoding($false)

function Find-Cli($p) {
    $candidates = @(
        (Join-Path $env:USERPROFILE ".local\bin\$($p.Bin).exe"),
        (Join-Path $env:USERPROFILE ".local\bin\agy\$($p.Bin).exe"),
        (Join-Path $env:LOCALAPPDATA "Programs\OpenAI\Codex\bin\$($p.Bin).exe")
    )
    $installed = Get-Command "$($p.Bin).exe" -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($installed) { $candidates += $installed.Source }
    foreach ($candidate in $candidates) { if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate } }
}

# Windows passes a command line to CreateProcess. Quote each argument as Windows argv expects.
function Quote-Arg([string]$arg) {
    if ($arg -ne '' -and $arg -notmatch '[\s"]') { return $arg }
    $escaped = [regex]::Replace($arg, '(\\*)"', '$1$1\"')
    $escaped = [regex]::Replace($escaped, '(\\+)$', '$1$1')
    return '"' + $escaped + '"'
}

function Start-Child($exe, $arguments, $directory, $inputText, $kind, $config, $environment, $seconds) {
    $process = New-Object Diagnostics.Process
    $info = $process.StartInfo
    $info.FileName = $exe
    $info.Arguments = (($arguments | ForEach-Object { Quote-Arg $_ }) -join ' ')
    $info.WorkingDirectory = $directory
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    $info.StandardOutputEncoding = $utf8
    $info.StandardErrorEncoding = $utf8
    foreach ($name in @('GEMINI_API_KEY','GOOGLE_API_KEY','OPENAI_API_KEY','CODEX_API_KEY','CODEX_ACCESS_TOKEN',
        'ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN','CLAUDE_CODE_OAUTH_TOKEN','OPENROUTER_API_KEY',
        'ANTHROPIC_BASE_URL','OPENAI_BASE_URL','GOOGLE_GEMINI_BASE_URL','CLAUDE_CODE_USE_BEDROCK',
        'CLAUDE_CODE_USE_VERTEX','CLAUDE_CODE_USE_FOUNDRY')) { $info.EnvironmentVariables.Remove($name) }
    foreach ($name in $environment.Keys) { $info.EnvironmentVariables[$name] = $environment[$name] }
    [void]$process.Start()
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $inputTask = $null
    if ($inputText) {
        $bytes = $utf8.GetBytes($inputText)
        $inputTask = $process.StandardInput.BaseStream.WriteAsync($bytes, 0, $bytes.Length)
    } else {
        $process.StandardInput.Close()
    }
    $script:job = @{Process=$process; Out=$stdout; Err=$stderr; Input=$inputTask; Kind=$kind; Config=$config; Stopped=$false}
    $script:timeout = [DateTime]::UtcNow.AddSeconds($seconds)
    Set-Busy $true
}

function Set-Busy($busy) {
    $controls.Enabled = -not $busy
    $run.Enabled = -not $busy
    $stop.Enabled = $busy
}

function Start-Agent($config) {
    $p = $config.Provider
    $exe = Find-Cli $p
    if (-not $exe) {
        if ($config.Installed) { throw 'CLI не найден после установки.' }
        $status.Text = "Загружаю официальный установщик $($p.Bin)…"
        $config.Temp = Join-Path ([IO.Path]::GetTempPath()) ("porubot-" + [guid]::NewGuid() + "." + $p.Ext)
        $curl = Get-Command curl.exe -CommandType Application -ErrorAction Stop
        Start-Child $curl.Source @('-fsSL','--proto','=https','--proto-redir','=https',$p.URL,'-o',$config.Temp) $env:USERPROFILE '' 'download' $config @{} 90
        return
    }
    $vars = @{}
    $vars[$p.Key] = $config.Key
    $payload = $config.Prompt
    $selection = @()
    if ($config.Model) { $selection = @('--model',$config.Model) }
    $level = @()
    if ($config.Effort) { $level = @('--effort',$config.Effort) }
    if ($p.Bin -eq 'agy') {
        $args = @('--settings','{"modelProvider":"gemini"}')
        if ($config.Catalog) {
            $status.Text = 'Читаю каталог Antigravity…'
            Start-Child $exe ($args + @('models')) $env:USERPROFILE '' 'catalog' $config $vars 35
            return
        }
        $mode = if ($config.Plan) { 'plan' } else { 'accept-edits' }
        $lookup = "$($config.Model)|$($config.Effort)"
        if ($script:catalog.ContainsKey($lookup)) {
            $selection = @('--model', $script:catalog[$lookup])
            $level = @()
        } elseif ($config.Model -match '^gemini-.*-(low|medium|high|xhigh|max|minimal)$') {
            $level = @()
        } elseif ($config.Effort -and $config.Model -in $providers[0].Models) {
            $selection = @('--model',"$($config.Model)-$($config.Effort)")
            $level = @()
        }
        $args += @('--input-format','stream-json','--output-format','stream-json','--disable-slash-commands','--sandbox','--mode',$mode) + $selection + $level
        $payload = (@{event='user';message=@{content=$payload}} | ConvertTo-Json -Compress -Depth 3) + "`n"
    } elseif ($p.Bin -eq 'codex') {
        $sandbox = if ($config.Plan) { 'read-only' } else { 'workspace-write' }
        $args = @('exec','--json','--ephemeral','--skip-git-repo-check','--sandbox',$sandbox,'-c','model_provider="openai"',
            '-c','shell_environment_policy.exclude=["CODEX_API_KEY","OPENAI_API_KEY"]') + $selection
        if ($config.Effort) { $args += @('-c',('model_reasoning_effort="' + $config.Effort + '"')) }
        $args += '-'
    } else {
        if ($p.Name -eq 'OpenRouter') {
            $vars = @{ANTHROPIC_BASE_URL='https://openrouter.ai/api';ANTHROPIC_AUTH_TOKEN=$config.Key;ANTHROPIC_API_KEY=''}
        }
        $mode = if ($config.Plan) { 'plan' } else { 'acceptEdits' }
        $args = @('-p','--verbose','--output-format','stream-json','--no-session-persistence','--permission-mode',$mode,
            '--disallowedTools','Bash,PowerShell,Monitor') + $selection + $level
    }
    $status.Text = "Запускаю $($p.Name)…"
    Start-Child $exe $args $config.Folder $payload 'run' $config $vars $config.Seconds
}

function Stop-Child {
    if (-not $script:job) { return }
    $script:job.Stopped = $true
    if (-not $script:job.Process.HasExited) {
        & "$env:SystemRoot\System32\taskkill.exe" /PID $script:job.Process.Id /T /F 2>&1 | Out-Null
    }
}

function Finish-Child($job, $stdout, $stderr) {
    $config = $job.Config
    $code = $job.Process.ExitCode
    if ($config.Key) {
        $stdout = $stdout.Replace($config.Key,'[ключ скрыт]')
        $stderr = $stderr.Replace($config.Key,'[ключ скрыт]')
    }
    if ($job.Stopped) {
        $status.Text = 'Запуск остановлен.'
        $result.Text = $stderr
    } elseif ($job.Kind -eq 'download' -and $code -eq 0) {
        $status.Text = "Устанавливаю $($config.Provider.Bin)…"
        if ($config.Provider.Ext -eq 'cmd') {
            Start-Child "$env:SystemRoot\System32\cmd.exe" @('/d','/c', $config.Temp) $env:USERPROFILE '' 'install' $config @{} 300
        } else {
            Start-Child "$PSHOME\powershell.exe" @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$config.Temp) $env:USERPROFILE '' 'install' $config @{CODEX_NON_INTERACTIVE='1'} 300
        }
        return
    } elseif ($job.Kind -eq 'install' -and $code -eq 0) {
        Remove-Item -LiteralPath $config.Temp -Force -ErrorAction SilentlyContinue
        $config.Installed = $true
        Start-Agent $config
        return
    } elseif ($job.Kind -eq 'catalog' -and $code -eq 0) {
        $script:catalog = @{}
        $names = @()
        foreach ($line in ($stdout -split "\r?\n")) {
            if ($line -match '^([^\t]+)\t(.+) \((Low|Medium|High|XHigh|Max|Minimal)\)$') {
                $script:catalog["$($Matches[2])|$($Matches[3].ToLowerInvariant())"] = $Matches[1]
                $names += $Matches[2]
            } elseif ($line -match '^([^\t]+)\t(.+)$') {
                $script:catalog["$($Matches[2])|"] = $Matches[1]
                $names += $Matches[2]
            }
        }
        if ($names.Count) {
            $model.Items.Clear()
            $model.Items.AddRange([object[]]@($names | Select-Object -Unique))
            if ($names -contains 'Gemini 3.8 Flash') { $model.Text = 'Gemini 3.8 Flash' } else { $model.SelectedIndex = 0 }
        }
        $status.Text = if ($names.Count) { 'Каталог обновлён.' } else { 'Каталог пуст. Можно ввести ID вручную.' }
        $result.Text = $stdout + $stderr
    } elseif ($job.Kind -eq 'run') {
        $answer = ''; $usage = $null; $errorText = ''; $success = $false
        foreach ($line in ($stdout -split "\r?\n")) {
            if (-not $line.StartsWith('{')) { continue }
            try { $event = ConvertFrom-Json -InputObject $line -ErrorAction Stop } catch { continue }
            if ($config.Provider.Bin -eq 'agy' -and $event.event -eq 'result') {
                $answer = $event.result.response; $usage = $event.result.usage
                $errorText = $event.result.error; $success = $event.result.status -eq 'SUCCESS'
            } elseif ($config.Provider.Bin -eq 'codex') {
                if ($event.type -eq 'item.completed' -and $event.item.type -eq 'agent_message') { $answer = $event.item.text }
                if ($event.type -eq 'turn.completed') { $usage = $event.usage; $success = $true }
                if ($event.type -eq 'turn.failed') { $errorText = $event.error.message; $success = $false }
            } elseif ($event.type -eq 'result') {
                $answer = $event.result; $usage = $event.usage
                $success = -not $event.is_error
                if ($event.errors) { $errorText = $event.errors -join "`r`n" }
            }
        }
        $status.Text = if ($code -eq 0 -and $success) { 'Завершено.' } else { "CLI завершился с ошибкой (код $code)." }
        if ($usage) {
            $cache = @($usage.cache_read_tokens,$usage.cached_input_tokens,$usage.cache_read_input_tokens) |
                Where-Object { $null -ne $_ } | Select-Object -First 1
            $metrics.Text = "Вход: $($usage.input_tokens)   Выход: $($usage.output_tokens)   Thinking: $($usage.thinking_tokens)   Кэш: $cache"
        }
        $result.Text = (@($answer,$errorText,$stderr) | Where-Object { $_ }) -join "`r`n`r`n"
        if (-not $result.Text -and -not $success) { $result.Text = $stdout }
    } else {
        $status.Text = "CLI или установка завершились с ошибкой (код $code)."
        $result.Text = $stdout + "`r`n" + $stderr
    }
    if ($config.Temp) { Remove-Item -LiteralPath $config.Temp -Force -ErrorAction SilentlyContinue }
}

$form = New-Object Windows.Forms.Form
$form.Text = 'PoruBot Agent'
$form.ClientSize = New-Object Drawing.Size(800,620)
$form.MinimumSize = New-Object Drawing.Size(816,659)
$form.StartPosition = 'CenterScreen'
$form.Font = New-Object Drawing.Font('Segoe UI',10)
$iconPath = Join-Path $PSScriptRoot 'PoruBot.ico'
if (Test-Path $iconPath) { $form.Icon = New-Object Drawing.Icon($iconPath) }

function Add-Control($parent,$type,$caption,$x,$y,$w,$h) {
    $control = New-Object "Windows.Forms.$type"
    $control.Text = $caption
    $control.SetBounds($x,$y,$w,$h)
    $parent.Controls.Add($control)
    return $control
}
$controls = Add-Control $form Panel '' 0 0 800 375
$controls.Anchor = 'Top,Left,Right'
[void](Add-Control $controls Label 'Движок' 18 20 95 24)
$engine = Add-Control $controls ComboBox '' 118 17 205 28
$engine.DropDownStyle = 'DropDownList'
$engine.Items.AddRange([object[]]@($providers | ForEach-Object { $_.Name }))
$keyLabel = Add-Control $controls Label 'API-ключ' 341 20 150 24
$key = Add-Control $controls TextBox '' 497 17 280 28
$key.UseSystemPasswordChar = $true; $key.Anchor = 'Top,Left,Right'
[void](Add-Control $controls Label 'Рабочая папка' 18 57 100 24)
$folder = Add-Control $controls TextBox '' 118 54 548 28
$folder.Anchor = 'Top,Left,Right'
$browse = Add-Control $controls Button 'Выбрать…' 674 53 103 29
$browse.Anchor = 'Top,Right'
[void](Add-Control $controls Label 'Модель' 18 94 96 24)
$model = Add-Control $controls ComboBox '' 118 91 315 28
$catalog = Add-Control $controls Button 'Каталог' 442 90 86 29
[void](Add-Control $controls Label 'Thinking' 543 95 68 24)
$effort = Add-Control $controls ComboBox '' 616 91 161 28
$effort.DropDownStyle = 'DropDownList'
[void](Add-Control $controls Label 'Профиль' 18 133 98 24)
$taskProfile = Add-Control $controls ComboBox '' 118 129 130 28
$taskProfile.DropDownStyle = 'DropDownList'
$taskProfile.Items.AddRange(@('Код','Данные','Вопрос'))
$taskProfile.SelectedIndex = 0
$shorten = Add-Control $controls CheckBox 'Короткий контекст' 268 129 168 27
$shorten.Checked = $true
$plan = Add-Control $controls CheckBox 'Только план' 442 129 110 27
[void](Add-Control $controls Label 'Таймер, с' 557 133 78 25)
$seconds = Add-Control $controls NumericUpDown '' 648 129 129 28
$seconds.Minimum = 30; $seconds.Maximum = 900; $seconds.Value = 180
[void](Add-Control $controls Label 'Задача' 18 172 99 24)
$request = Add-Control $controls TextBox '' 118 169 659 115
$request.Multiline = $true; $request.ScrollBars = 'Vertical'; $request.Anchor = 'Top,Left,Right'
[void](Add-Control $controls Label 'Границы' 18 300 96 24)
$scope = Add-Control $controls TextBox '' 118 296 659 29
$scope.Anchor = 'Top,Left,Right'
$preview = Add-Control $controls Button 'Показать промпт' 118 332 166 30
$run = Add-Control $form Button 'Запустить' 587 380 92 31
$run.Anchor = 'Top,Right'
$stop = Add-Control $form Button 'Стоп' 687 380 90 31
$stop.Anchor = 'Top,Right'; $stop.Enabled = $false
$status = Add-Control $form Label 'Готово к запуску' 18 385 557 24
$status.Anchor = 'Top,Left,Right'
$metrics = Add-Control $form Label '' 18 421 759 24
$metrics.Anchor = 'Top,Left,Right'
$result = Add-Control $form TextBox '' 18 449 759 151
$result.Multiline = $true; $result.ReadOnly = $true; $result.ScrollBars = 'Vertical'
$result.Anchor = 'Top,Bottom,Left,Right'

function Get-Prompt {
    $value = $request.Text.Trim()
    if ($scope.Text.Trim()) { $value += "`r`n`r`nГраницы задачи и критерий готовности:`r`n" + $scope.Text.Trim() }
    if ($shorten.Checked) {
        $hints = @(
            'Читай только нужные файлы и фрагменты. Сделай минимальное изменение и одну целевую проверку. Сокращай логи.',
            'Обработай данные локально. Изучи схему и до пяти строк. Верни агрегаты, выводы и ограничения.',
            'Ответь кратко. Используй файлы и инструменты только при необходимости.'
        )
        $value += "`r`n`r`n" + $hints[$taskProfile.SelectedIndex] + ' Не расширяй задачу.'
    }
    return $value
}
function Submit($catalogOnly) {
    $provider = $providers[$engine.SelectedIndex]
    if (-not $key.Text.Trim()) { $status.Text = "Вставь ключ $($provider.Key)."; return }
    if (-not $catalogOnly -and (-not $request.Text.Trim() -or -not (Test-Path -LiteralPath $folder.Text -PathType Container))) {
        $status.Text = 'Выбери рабочую папку и введи задачу.'
        return
    }
    $result.Clear(); $metrics.Text = ''
    $config = @{Provider=$provider;Key=$key.Text.Trim();Model=$model.Text.Trim();Effort=$effort.Text;
        Plan=$plan.Checked;Folder=$folder.Text;Seconds=[int]$seconds.Value;Prompt=(Get-Prompt);Catalog=$catalogOnly;Installed=$false}
    try { Start-Agent $config } catch { $status.Text = 'Ошибка запуска.'; $result.Text = $_.Exception.Message }
}

$engine.add_SelectedIndexChanged({
    $secrets[$script:selected] = $key.Text
    $script:selected = $engine.SelectedIndex
    $p = $providers[$script:selected]
    $keyLabel.Text = $p.Key
    $value = $secrets[$script:selected]
    if ($null -eq $value) { $value = [Environment]::GetEnvironmentVariable($p.Key) }
    $key.Text = [string]$value
    $model.Items.Clear()
    $model.Items.AddRange([object[]]$p.Models)
    $model.SelectedIndex = 0
    $catalog.Enabled = $p.Bin -eq 'agy'
    $effort.Items.Clear()
    $levels = @('','low','medium','high','xhigh')
    if ($p.Bin -ne 'codex') { $levels += 'max' }
    if ($p.Bin -ne 'claude') { $levels += 'minimal' }
    $effort.Items.AddRange([object[]]$levels)
    $effort.SelectedIndex = if ($p.Bin -eq 'claude') { 0 } else { 1 }
})
$engine.SelectedIndex = 0
$browse.add_Click({
    $dialog = New-Object Windows.Forms.FolderBrowserDialog
    try { if ($dialog.ShowDialog($form) -eq 'OK') { $folder.Text = $dialog.SelectedPath } } finally { $dialog.Dispose() }
})
$preview.add_Click({ [void][Windows.Forms.MessageBox]::Show((Get-Prompt),'Промпт для CLI') })
$run.add_Click({ Submit $false })
$catalog.add_Click({ Submit $true })
$stop.add_Click({ Stop-Child })
$form.add_FormClosing({ Stop-Child })

$timer = New-Object Windows.Forms.Timer
$timer.Interval = 200
$timer.add_Tick({
    if (-not $script:job) { return }
    $job = $script:job
    if ($job.Input -and $job.Input.IsCompleted) {
        try { $job.Process.StandardInput.Close() } catch {}
        $job.Input = $null
    }
    if (-not $job.Stopped -and [DateTime]::UtcNow -ge $script:timeout -and -not $job.Process.HasExited) { Stop-Child }
    if (-not $job.Process.HasExited -or -not $job.Out.IsCompleted -or -not $job.Err.IsCompleted) { return }
    $script:job = $null
    Set-Busy $false
    try { Finish-Child $job ($job.Out.GetAwaiter().GetResult()) ($job.Err.GetAwaiter().GetResult()) }
    catch {
        if ($job.Config.Temp) { Remove-Item -LiteralPath $job.Config.Temp -Force -ErrorAction SilentlyContinue }
        $status.Text = 'Ошибка CLI.'
        $result.Text = $_.Exception.Message
    } finally { $job.Process.Dispose() }
})
$timer.Start()
try { [void]$form.ShowDialog() } finally { $timer.Dispose(); $form.Dispose() }
