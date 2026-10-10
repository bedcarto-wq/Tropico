# ============================================================================
#  Hardball Politics («Политика без поблажек») — PowerShell-ядро (payload).
#  Полный конвейер сборки мода для Tropico 6 БЕЗ Python:
#    extract -> patch -> package -> verify -> install
#  Совместимо с Windows PowerShell 5.1 и PowerShell 7+.
# ============================================================================
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$script:AppDir = $global:HardballAppDir
if (-not $script:AppDir) { $script:AppDir = $PSScriptRoot }
if (-not $script:AppDir) { $script:AppDir = (Get-Location).Path }

$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:IsWin = ($null -eq $PSVersionTable.Platform) -or ($PSVersionTable.Platform -eq 'Win32')

$script:ModId = 'HardballPolitics'
$script:ModTitle = 'Hardball Politics — Политика без поблажек'
# Версия видна в меню, статусе и каждом отчёте: по ней сразу понятно,
# что запущен свежий файл bat, а не старая копия из загрузок.
$script:ScriptVersion = 'v1.12 (10.10.2026)'
$script:ModPakName = 'z_HardballPolitics.pak'
$script:WorkDir = Join-Path $script:AppDir 'work'
$script:ToolsDir = Join-Path $script:AppDir 'tools'
$script:ConfigPath = Join-Path $script:AppDir 'hardball_config.json'
$script:DirOrig = 'orig'; $script:DirJson = 'json'; $script:DirMod = 'modfiles'
$script:DirOut = 'output'; $script:DirReports = 'reports'

$script:ExtractFilters = @(
    '*T6SingletonData*', '*FactionUltimatum*', '*FactionDemand*',
    '*T6Escalation*', '*GuerillaRebel*')

$script:PatchTargets = @(
    'Blueprints/GameData/BP_T6SingletonData.uasset',
    'Blueprints/Ultimatums/Factions/',
    'Blueprints/Demands/Factions/')

# ---------------------------------------------------------------------------
# Встроенный рецепт правок (идентичен recipe/hardball_recipe.json)
# ---------------------------------------------------------------------------
$script:RecipeJson = @'
{
  "mod": {
    "id": "HardballPolitics",
    "title": "Hardball Politics — Политика без поблажек",
    "version": "1.0.0",
    "target_game": "Tropico 6 (актуальные сборки; заявленная цель — v.23 (1290))",
    "language": "ru"
  },
  "patch_targets": [
    "Blueprints/GameData/BP_T6SingletonData.uasset",
    "Blueprints/Ultimatums/Factions/",
    "Blueprints/Demands/Factions/"
  ],
  "scan_targets": [
    "Blueprints/Escalations/",
    "Blueprints/Politics/Factions/",
    "Blueprints/Military/"
  ],
  "rules": [
    {
      "id": "speech_praise_support",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^StandingModiferFleetingPraise$",
      "action": "scale",
      "value": 0.3,
      "range": [1, 1000],
      "desc": "Предвыборная речь: прямой бонус поддержки от восхваления фракции урезан до ~30% исходного (StandingModiferFleetingPraise)"
    },
    {
      "id": "speech_struct_praise",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "(?i)(praise|flatter|cheer|applause|admiration)",
      "context": "(?i)election.?speech",
      "action": "scale",
      "value": 0.3,
      "if_value": ">0",
      "range": [0.001, 1000],
      "desc": "Предвыборная речь: прочие положительные бонусы «восхваления» внутри структуры ElectionSpeech — до ~30%"
    },
    {
      "id": "speech_struct_promise",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "(?i)promise",
      "exclude": "(?i)(needed|happiness|threshold|duration)",
      "context": "(?i)election.?speech",
      "action": "scale",
      "value": 0.28,
      "if_value": ">0",
      "range": [0.001, 1000],
      "desc": "Предвыборная речь: немедленный эффект обещаний — до ~28% от исходного (цель ТЗ — 25–30%); пороговые критерии выполнения обещаний не затрагиваются"
    },
    {
      "id": "speech_struct_support",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "(?i)(support|approval|sway)",
      "context": "(?i)election.?speech",
      "action": "scale",
      "value": 0.3,
      "if_value": ">0",
      "range": [0.001, 1000],
      "desc": "Предвыборная речь: немедленные бонусы поддержки в структуре ElectionSpeech — до ~30%"
    },
    {
      "id": "dual_demand_frequency",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^DualDemandTriggerChance$",
      "action": "scale",
      "value": 1.25,
      "range": [1, 99.9],
      "clamp": [1, 100],
      "desc": "Политические конфликты: шанс срабатывания требований двух фракций одновременно +25% (DualDemandTriggerChance), штатные задержки сохранены"
    },
    {
      "id": "ultimatum_deadline",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^UltimatumTimeLimitInMonths$",
      "action": "scale",
      "value": 0.8,
      "if_value": ">=1",
      "range": [1, 240],
      "clamp": [1, 240],
      "desc": "Ультиматумы: срок на выполнение сокращён до 80% (нельзя бесконечно откладывать требование)"
    },
    {
      "id": "offer_expiry",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^MonthsTillRejectingNotTouchedOfferedDemands$",
      "action": "scale",
      "value": 0.8,
      "if_value": ">=1",
      "range": [1, 240],
      "clamp": [1, 240],
      "desc": "Требования фракций: неисполненные предложения отклоняются на 20% быстрее"
    },
    {
      "id": "degradation_speed",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^DegradationMonthsToMaxOutTreshhold$",
      "action": "scale",
      "value": 0.7,
      "if_value": ">=1",
      "range": [1, 240],
      "clamp": [1, 240],
      "desc": "Накопление недовольства: игнорируемая проблема достигает максимума за 70% исходного срока — длительное бездействие опаснее кратковременных колебаний"
    },
    {
      "id": "rebel_points_rebel",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^MonthlyRebelPointsPerRebel$",
      "action": "scale",
      "value": 1.25,
      "if_value": ">0",
      "range": [0.001, 1000],
      "desc": "Эскалация восстаний: недовольные копят очки восстания на 25% быстрее (пороги восстаний НЕ меняются — потолок масштаба сохранён)"
    },
    {
      "id": "rebel_points_guerrilla",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^MonthlyRebelPointsPerGuerrilla$",
      "action": "scale",
      "value": 1.25,
      "if_value": ">0",
      "range": [0.001, 1000],
      "desc": "Эскалация восстаний: партизаны копят очки восстания на 25% быстрее"
    },
    {
      "id": "protest_threshold",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^ProtestHappinessThreshold$",
      "action": "scale",
      "value": 1.1,
      "range": [1, 100],
      "clamp": [1, 100],
      "desc": "Ранние стадии кризиса: протесты начинаются при слегка более высоком (×1.1) пороге счастья — предупреждение приходит раньше"
    },
    {
      "id": "standing_gain_mult",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^StandingGainMultiplier$",
      "action": "scale",
      "value": 1.2,
      "if_value": ">0",
      "range": [0.01, 100],
      "desc": "Политика реактивнее: рост поддержки фракций ×1.2 — разовые успехи сильнее сказываются на рейтинге"
    },
    {
      "id": "standing_loss_mult",
      "asset_glob": "Blueprints/GameData/BP_T6SingletonData.uasset",
      "property": "^StandingLossMulitplier$",
      "action": "scale",
      "value": 1.2,
      "if_value": ">0",
      "range": [0.01, 100],
      "desc": "Политика реактивнее: падение поддержки фракций ×1.2 (имя с опечаткой Mulitplier — так в ассете игры)"
    },
    {
      "id": "ultimatum_cooldown",
      "asset_glob": "Blueprints/Ultimatums/Factions/.*",
      "property": "(?i)(cooldown|cool_down)_?months?",
      "action": "scale",
      "value": 0.8,
      "if_value": ">=1",
      "range": [1, 240],
      "clamp": [1, 240],
      "desc": "Ультиматумы фракций: период ожидания между ультиматумами сокращён до 80% (~25% чаще), сам механизм перезарядки полностью сохранён"
    },
    {
      "id": "faction_demand_cooldown",
      "asset_glob": "Blueprints/Demands/Factions/.*",
      "property": "(?i)(cooldown|cool_down)_?months?",
      "action": "scale",
      "value": 0.8,
      "if_value": ">=1",
      "range": [1, 240],
      "clamp": [1, 240],
      "desc": "Требования фракций: период перезарядки сокращён до 80% (~25% чаще), без отмены штатных задержек; требования супердержав не затрагиваются"
    }
  ]
}
'@

# ---------------------------------------------------------------------------
# Сообщения
# ---------------------------------------------------------------------------
function Msg([string]$t = '') { Write-Host $t }
function Warn2([string]$t) { Write-Host ('[ВНИМАНИЕ] ' + $t) -ForegroundColor Yellow }
function Die([string]$t) { throw $t }

# ---------------------------------------------------------------------------
# JSON-движок: Windows PowerShell 5.1 -> JavaScriptSerializer (сохраняет
# одноэлементные массивы; ConvertFrom-Json 5.1 их разворачивает и портит
# структуру UAssetGUI-JSON). PowerShell 7+ -> штатный ConvertFrom/To-Json.
# ---------------------------------------------------------------------------
function Test-WinPs { $PSVersionTable.PSVersion.Major -lt 6 }

function New-JsonNet {
    if (Test-WinPs) {
        Add-Type -AssemblyName System.Web.Extensions | Out-Null
        $jss = New-Object System.Web.Script.Serialization.JavaScriptSerializer
        $jss.MaxJsonLength = 2147483647
        $jss.RecursionLimit = 512
        return $jss
    }
    return $null
}

function ConvertFrom-JsonText([string]$text) {
    if (Test-WinPs) {
        $jss = New-JsonNet
        return $jss.DeserializeObject($text)
    }
    return (ConvertFrom-Json -InputObject $text)
}

function ConvertTo-JsonText($tree) {
    if (Test-WinPs) {
        $jss = New-JsonNet
        return $jss.Serialize($tree)
    }
    return (ConvertTo-Json -InputObject $tree -Depth 100)
}

function Read-Text([string]$p) {
    return [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
}
function Write-Text([string]$p, [string]$s) {
    [System.IO.File]::WriteAllText($p, $s, $Utf8NoBom)
}

# --- унифицированный доступ к узлам (Dictionary из JS-сериализатора или
# --- PSCustomObject из ConvertFrom-Json)
function Test-JDict($o) {
    return ($o -is [System.Collections.IDictionary]) -or
           ($o -is [System.Management.Automation.PSCustomObject])
}

function Get-JProp($o, [string]$k) {
    if ($null -eq $o) { return $null }
    if ($o -is [System.Collections.IDictionary]) {
        if ($o.Contains($k)) { return $o[$k] }
        return $null
    }
    $p = $o.PSObject.Properties[$k]
    if ($null -ne $p) { return $p.Value }
    return $null
}

function Test-JProp($o, [string]$k) {
    if ($null -eq $o) { return $false }
    if ($o -is [System.Collections.IDictionary]) { return $o.Contains($k) }
    return ($null -ne $o.PSObject.Properties[$k])
}

function Set-JProp($o, [string]$k, $v) {
    if ($o -is [System.Collections.IDictionary]) { $o[$k] = $v }
    else { $o.PSObject.Properties[$k].Value = $v }
}

function Get-JEntries($o) {
    if ($o -is [System.Collections.IDictionary]) {
        foreach ($e in $o.GetEnumerator()) { ,@{ Key = $e.Key; Value = $e.Value } }
    } else {
        foreach ($p in $o.PSObject.Properties) { ,@{ Key = $p.Name; Value = $p.Value } }
    }
}


function Join-Sub([string]$base, [string]$rel) {
    $p = $base
    foreach ($part in (($rel -replace '\\', '/') -split '/')) {
        if ($part) { $p = Join-Path $p $part }
    }
    return $p
}

function Test-Number($v) {
    if ($null -eq $v) { return $false }
    if ($v -is [bool]) { return $false }
    return ($v -is [int] -or $v -is [long] -or $v -is [double] -or
            $v -is [decimal] -or $v -is [sbyte] -or $v -is [byte] -or
            $v -is [int16] -or $v -is [uint16] -or $v -is [uint32])
}

# Рекурсивный обход UAssetGUI-JSON (аналог iter_nodes из Python-версии):
# выдаёт пары (узел, путь). Путь включает имя самого узла.
function Get-AllNodes($Obj, $Path = @()) {
    if ($null -eq $Obj) { return }
    if ($Obj -is [System.Array]) {
        foreach ($item in $Obj) { Get-AllNodes $item $Path }
        return
    }
    if (Test-JDict $Obj) {
        $name = Get-JProp $Obj 'Name'
        if ($name -is [string]) {
            $Path = @($Path + $name)
            ,($Obj, $Path)
        }
        foreach ($e in (Get-JEntries $Obj)) { Get-AllNodes $e.Value $Path }
    }
}

# ---------------------------------------------------------------------------
# Конфигурация
# ---------------------------------------------------------------------------
function Get-Config {
    $cfg = @{
        game_root = ''
    }
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try {
            $loaded = ConvertFrom-JsonText (Read-Text $script:ConfigPath)
            foreach ($e in (Get-JEntries $loaded)) { $cfg[$e.Key] = $e.Value }
        } catch { }
    }
    return $cfg
}

function Save-Config([hashtable]$cfg) {
    Write-Text $script:ConfigPath (ConvertTo-JsonText $cfg)
}

# ---------------------------------------------------------------------------
# Поиск игры
# ---------------------------------------------------------------------------
function Test-GameRoot([string]$p) {
    if (-not $p) { return $false }
    # ВАЖНО: Join-Path бросает DriveNotFoundException для несуществующего диска
    # (например 'D:\...' на машине без диска D), а [IO.Directory]::Exists просто
    # вернёт False. Поэтому проверяем через .NET и гасим любые исключения.
    try {
        $d = Join-Sub $p 'Tropico6/Content/Paks'
        return [System.IO.Directory]::Exists($d)
    } catch { return $false }
}

function Find-GameRoot([hashtable]$cfg) {
    if ($cfg['game_root']) { return [string]$cfg['game_root'] }
    $candidates = @(
        'C:\Program Files (x86)\Steam\steamapps\common\Tropico 6',
        'C:\Program Files\Steam\steamapps\common\Tropico 6',
        'D:\SteamLibrary\steamapps\common\Tropico 6',
        'D:\Steam\steamapps\common\Tropico 6',
        'E:\SteamLibrary\steamapps\common\Tropico 6',
        'E:\Steam\steamapps\common\Tropico 6'
    )
    foreach ($c in $candidates) { if (Test-GameRoot $c) { return $c } }
    if ($script:IsWin) {
        # Перебор всех реально существующих дисков: типичные расположения
        # Steam/Epic-библиотек. Безопасно: диск существует по определению.
        try {
            $subs = @(
                'Tropico 6',
                'Games\Tropico 6',
                'SteamLibrary\steamapps\common\Tropico 6',
                'Steam\steamapps\common\Tropico 6',
                'Program Files (x86)\Steam\steamapps\common\Tropico 6',
                'Program Files\Steam\steamapps\common\Tropico 6',
                'Program Files\Epic Games\Tropico 6',
                'Program Files\Epic Games\Tropico6',
                'Epic Games\Tropico 6',
                'Epic Games\Tropico6',
                'Games\Tropico 6',
                'Games\Steam\steamapps\common\Tropico 6'
            )
            foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
                foreach ($sub in $subs) {
                    $g = Join-Path $drv.Root $sub
                    if (Test-GameRoot $g) { return $g }
                }
            }
        } catch { }
        # Steam libraryfolders.vdf — другие библиотеки на других дисках
        try {
            $pf86 = ${env:ProgramFiles(x86)}
            if ($pf86) {
                $vdf = Join-Path $pf86 'Steam\steamapps\libraryfolders.vdf'
                if (Test-Path -LiteralPath $vdf) {
                    $lines = Get-Content -LiteralPath $vdf -ErrorAction SilentlyContinue
                    foreach ($ln in $lines) {
                        if ($ln -match '"path"\s+"([^"]+)"') {
                            $lib = $Matches[1] -replace '\\\\', '\'
                            $g = Join-Path $lib 'steamapps\common\Tropico 6'
                            if (Test-GameRoot $g) { return $g }
                        }
                    }
                }
            }
        } catch { }
        # Реестр: деинсталляторы
        try {
            $keys = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            foreach ($it in (Get-ItemProperty $keys -ErrorAction SilentlyContinue)) {
                $dn = $it.DisplayName
                if ($dn -like '*Tropico 6*' -and $it.InstallLocation) {
                    $loc = [string]$it.InstallLocation
                    if (Test-GameRoot $loc) { return $loc }
                    $parent = Split-Path -Parent $loc
                    if ($parent -and (Test-GameRoot $parent)) { return $parent }
                }
            }
        } catch { }
    }
    return ''
}

function Read-GameRootFromUser {
    Msg ''
    Msg 'Не удалось найти Tropico 6 автоматически.'
    for ($i = 0; $i -lt 5; $i++) {
        $p = Read-Host 'Укажите корневую папку игры (там лежит папка Tropico6), например C:\Program Files (x86)\Steam\steamapps\common\Tropico 6'
        $p = $p.Trim().Trim('"').Trim("'")
        if ($p -and (Test-GameRoot $p)) { return $p }
        Msg ('В папке "' + $p + '" нет Tropico6\Content\Paks. Попробуйте ещё раз.')
    }
    Die 'Не удалось указать путь к игре.'
}

function Get-PaksDir([hashtable]$cfg) {
    $root = Find-GameRoot $cfg
    if (-not $root) { return '' }
    $d = Join-Sub $root 'Tropico6/Content/Paks'
    if (Test-Path -LiteralPath $d -PathType Container) { return $d }
    return ''
}

function Get-GamePaks([hashtable]$cfg) {
    $d = Get-PaksDir $cfg
    if (-not $d) { return @() }
    $paks = @()
    foreach ($f in (Get-ChildItem -LiteralPath $d -File -Filter *.pak | Sort-Object Name)) {
        if ($f.Name.StartsWith('z_') -or $f.Name.StartsWith('ZZZ_')) { continue }
        $paks += $f.FullName
    }
    return $paks
}

# ---------------------------------------------------------------------------
# Внешние инструменты
# ---------------------------------------------------------------------------
# Надёжный запуск внешнего exe через Start-Process + файлы-редиректы.
# В отличие от "& exe 2>&1" (где текст ошибки PowerShell смешивается с выводом
# и маскирует молчание exe) здесь отдельно фиксируются: сам факт запуска,
# текст ошибки запуска (нет DLL / заблокирован антивирусом), код возврата,
# stdout и stderr.
function Invoke-ToolRun([string]$exe, [string[]]$argList) {
    $res = @{ Started = $false; ExitCode = $null; Out = ''; Err = ''; StartError = '' }
    $outFile = [System.IO.Path]::GetTempFileName()
    $errFile = [System.IO.Path]::GetTempFileName()
    try {
        $quoted = @()
        foreach ($a in $argList) { $quoted += ('"' + ([string]$a -replace '"', '\"') + '"') }
        # ВАЖНО: в Windows PowerShell 5.1 пустой массив в -ArgumentList
        # нарушает ValidateNotNullOrEmpty («The argument is null, empty...»),
        # поэтому при пустом списке параметр не передаём вовсе.
        if ($quoted.Count -gt 0) {
            $p = Start-Process -FilePath $exe -ArgumentList $quoted -PassThru -Wait -NoNewWindow `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        } else {
            $p = Start-Process -FilePath $exe -PassThru -Wait -NoNewWindow `
                    -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        }
        $res.Started = $true
        $res.ExitCode = $p.ExitCode
    } catch {
        $res.StartError = [string]$_.Exception.Message
    }
    try { $res.Out = [System.IO.File]::ReadAllText($outFile) } catch {}
    try { $res.Err = [System.IO.File]::ReadAllText($errFile) } catch {}
    try { Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue } catch {}
    return $res
}

function Invoke-Tool([string]$exe, [string[]]$argList, [string]$what = '') {
    if (-not (Test-Path -LiteralPath $exe)) {
        Die ('Инструмент не найден: ' + $exe + ' (выберите пункт 1 — он скачается автоматически)')
    }
    $r = Invoke-ToolRun $exe $argList
    $out = ($r.Out + $r.Err)
    if (-not $r.Started) {
        Msg ''
        Msg ('Не удалось запустить "' + $exe + '": ' + $r.StartError)
        Die ('Проверьте антивирус и установите Microsoft Visual C++ 2015-2019 Redistributable (x64): https://aka.ms/vs/16/release/VC_redist.x64.exe (' + $what + ')')
    }
    if ($null -eq $r.ExitCode -or $r.ExitCode -ne 0) {
        Msg ''
        Msg ('Команда: "' + $exe + '" ' + ($argList -join ' '))
        Msg ('Код возврата: ' + $r.ExitCode)
        if ($out -and $out.Trim()) { Msg ($out.Trim().Substring([Math]::Max(0, $out.Trim().Length - 3000))) }
        Die ('Не удалось выполнить: ' + $what)
    }
    return $out
}

function Download-FileEx([string]$url, [string]$dest) {
    if (Test-WinPs) {
        # В старых сборках Windows .NET Framework не включает TLS 1.2 по умолчанию,
        # без него GitHub отдаёт ошибку соединения.
        try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}
    }
    $iw = @{ Uri = $url; OutFile = $dest; UserAgent = 'Mozilla/5.0'; TimeoutSec = 300 }
    if (Test-WinPs) { $iw.UseBasicParsing = $true }
    Invoke-WebRequest @iw
}

$script:ToolDownloads = @(
    @{
        Key = 'uassetgui'; Label = 'UAssetGUI (конвертер .uasset <-> JSON)';
        Path = Join-Path $script:ToolsDir 'UAssetGUI.exe';
        Urls = @(
            'https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UAssetGUI.exe',
            'https://github.com/atenfyr/UAssetGUI/releases/download/v1.1.0/UAssetGUI.exe'
        )
    },
    @{
        Key = 'unrealpak_extract'; Label = 'UnrealPak 4.25.3 (распаковка игровых .pak)';
        Path = Join-Path $script:ToolsDir 'UnrealPak_4_25_3.exe';
        Urls = @('https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UnrealPakTool/UnrealPak.exe');
        # UnrealPak 4.25.3 — это НЕ одиночный exe: обёртка требует рядом 12 DLL
        # (UnrealPak-Core.dll и др.). Без них процесс не запускается и молчит.
        Deps = @(
           'UnrealPak-Core.dll', 'UnrealPak-CoreUObject.dll', 'UnrealPak-DerivedDataCache.dll',
           'UnrealPak-Json.dll', 'UnrealPak-PakFile.dll', 'UnrealPak-PakFileUtilities.dll',
           'UnrealPak-Projects.dll', 'UnrealPak-Analytics.dll', 'UnrealPak-BuildSettings.dll',
           'UnrealPak-RSA.dll', 'UnrealPak-SSL.dll', 'UnrealPak-TraceLog.dll', 'UnrealPak.modules'
        ) | ForEach-Object {
            @{ Path = Join-Path $script:ToolsDir $_
               MinBytes = $(if ($_ -eq 'UnrealPak.modules') { 100 } else { 50000 })
               Urls = @('https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UnrealPakTool/' + $_) }
        }
    },
    @{
        Key = 'unrealpak_pack'; Label = 'UnrealPak 4.20 (сборка модового .pak)';
        Path = Join-Path $script:ToolsDir 'UnrealPak_UE4_20.exe';
        Urls = @('https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UnrealPakTool/UnrealPak%5Bv5_UE4.20%5D.exe')
    }
)

# Эталонный манифест компонентов UnrealPak (точный размер и SHA256 из источника).
# Раньше проверялось только «файл существует и больше N байт» — из-за этого
# старый/битой набор в папке tools считался годным, и extract молча давал 0 файлов.
# Теперь файл с чужим размером или хешем заменяется на свежий автоматически.
$script:ToolIntegrity = @{
    'UnrealPak_4_25_3.exe'          = @{ Size = 138208;   Sha256 = '83d40eb798a47f411a8d95bf2862eb6ee71eb36712910b0c4271c2b8a2e0a902' }
    'UnrealPak-Core.dll'             = @{ Size = 7380960; Sha256 = '6bdd74115774b383a800937d38e19347546380d0c3ceb5b777ccae8151bb5548' }
    'UnrealPak-CoreUObject.dll'      = @{ Size = 5988832; Sha256 = 'b4eab4e64e9649db9d5ce2a63c65025da1509d71b6ea29c8ec99f0c9db27c98d' }
    'UnrealPak-DerivedDataCache.dll' = @{ Size = 3695584; Sha256 = 'f9549750a73f2ea1bbca7b0afd3d2c6088189d0f12fc5feb820f7905cf1c75e6' }
    'UnrealPak-Json.dll'             = @{ Size = 227808;  Sha256 = '6866cc12fd12df556673c55deb04b7e93d2d48e78a1820601824efe459019a60' }
    'UnrealPak-PakFile.dll'          = @{ Size = 376800;  Sha256 = '0f5999202a3a486ea017144f86e251387eef93192f101ecb42dee441efba32a6' }
    'UnrealPak-PakFileUtilities.dll' = @{ Size = 422880;  Sha256 = '347e22e949c7c9215b329a811229c40992f050fbe13e4bd5660234031a33e754' }
    'UnrealPak-Projects.dll'         = @{ Size = 440800;  Sha256 = 'e8e0d4096f1e4de5d3c833de452329e7ad40c1b950cdccbd7c15f2e7f570637c' }
    'UnrealPak-Analytics.dll'        = @{ Size = 64480;   Sha256 = 'af8569b87fd4131dcc38e773e8108994bf142237aec2b949b0b75203613a227f' }
    'UnrealPak-BuildSettings.dll'    = @{ Size = 52704;   Sha256 = '0b26abc9ba450b447a4349995c6f61001a6c7fe351cf95c954aeff101947dfd0' }
    'UnrealPak-RSA.dll'              = @{ Size = 63968;   Sha256 = '4dc373e0bd3ec594a597b337af20079d7358ed809e59dd107d3710c40abf9cca' }
    'UnrealPak-SSL.dll'              = @{ Size = 2877600; Sha256 = 'ea5deb539208be40c3c8658779cfef5c3a1628d642d0bcdc5f120ba1755a1d6a' }
    'UnrealPak-TraceLog.dll'         = @{ Size = 107168;  Sha256 = '7cb450dae71ce31e627cd7e4beab1bb5054d2bae574da8cf13ac4d9b61567957' }
    'UnrealPak.modules'              = @{ Size = 537;     Sha256 = 'd765228ff12a593bf853400b761e32559c10ae42c4c5606e112a0ff14e644f89' }
    'UnrealPak_UE4_20.exe'           = @{ Size = 11452816; Sha256 = '8cc2322d844f2c59741b1eee4bd50ae2fff91cbc1db055dd9c04132980d9e35c' }
}

function Test-FileOk([string]$p, [int64]$minBytes) {
    return (Test-Path -LiteralPath $p -PathType Leaf) -and ((Get-Item -LiteralPath $p).Length -gt $minBytes)
}

function Test-ToolIntegrity([string]$path, [string]$name) {
    $m = $script:ToolIntegrity[$name]
    if ($null -eq $m) { return $true }   # файла нет в манифесте — обычная проверка его не касается
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $false }
    try {
        if ((Get-Item -LiteralPath $path).Length -ne $m.Size) { return $false }
        $h = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        return ($h -eq $m.Sha256)
    } catch { return $false }
}

function Save-Url([string]$url, [string]$dest, [int64]$minBytes) {
    try {
        Msg ('  скачиваю: ' + $url)
        Download-FileEx $url $dest
        if (Test-FileOk $dest $minBytes) { return $true }
    } catch { }
    return $false
}

# Проверяет один файл инструментов; при несовпадении с эталоном заменяет его.
function Ensure-File([string]$path, [string[]]$urls, [int64]$minBytes, [string]$label) {
    $name = [System.IO.Path]::GetFileName($path)
    $inManifest = ($null -ne $script:ToolIntegrity[$name])
    if ($inManifest) {
        if (Test-ToolIntegrity $path $name) { return $true }
        if (Test-Path -LiteralPath $path) {
            Msg ('  [fix] ' + $name + ' не совпадает с эталоном (размер/хеш) — заменяю')
            Remove-Item -LiteralPath $path -Force
        }
    } elseif (Test-FileOk $path $minBytes) {
        return $true
    }
    foreach ($u in $urls) {
        if (Save-Url $u $path $(if ($inManifest) { 100 } else { $minBytes })) {
            if ($inManifest) {
                if (Test-ToolIntegrity $path $name) { return $true }
                Msg ('  [fix] скачанный ' + $name + ' не совпал с эталоном — удаляю')
                Remove-Item -LiteralPath $path -Force
            } else {
                return $true
            }
        }
    }
    return $false
}

function Ensure-Tools {
    if (-not (Test-Path -LiteralPath $script:ToolsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:ToolsDir -Force | Out-Null
    }
    foreach ($spec in $script:ToolDownloads) {
        $okMain = Ensure-File $spec.Path $spec.Urls 100000 $spec.Label
        $depsOk = $true
        $depCount = 0
        if ($spec.ContainsKey('Deps')) {
            foreach ($d in $spec.Deps) {
                $depCount++
                if (-not (Ensure-File $d.Path $d.Urls $d.MinBytes $d.Path)) {
                    $depsOk = $false
                    Warn2 ('Не удалось получить компонент ' + [System.IO.Path]::GetFileName($d.Path) + '. Положите файл вручную в: ' + $d.Path)
                }
            }
        }
        if ($okMain -and $depsOk) {
            $suffix = ''
            if ($depCount -gt 0) { $suffix = (' (+' + $depCount + ' компонентов, проверены по хешу)') }
            Msg ('  [ok] ' + $spec.Label + ' уже на месте' + $suffix)
            continue
        }
        Warn2 ('Не удалось проверить/скачать ' + $spec.Label + '. Положите файл вручную в: ' + $spec.Path)
    }
    # Проба запуска: раньше она делалась через "& exe 2>&1", и текст ошибки
    # PowerShell сам попадал в «вывод», из-за чего битый exe выглядел рабочим.
    # Теперь запускаем через Start-Process: отказ запуска ловится отдельно.
    $extExe = Join-Path $script:ToolsDir 'UnrealPak_4_25_3.exe'
    if (Test-FileOk $extExe 100000) {
        $r = Invoke-ToolRun $extExe @()
        if (-not $r.Started) {
            Die ('UnrealPak не запускается: ' + $r.StartError + ' Все 13 компонентов уже проверены по хешу, поэтому причина почти наверняка в отсутствии Microsoft Visual C++ 2015-2019 Redistributable (x64) или в антивирусе. Установите https://aka.ms/vs/16/release/VC_redist.x64.exe и запустите пункт 1 заново.')
        }
        if (-not (($r.Out + $r.Err).Trim())) {
            Die ('UnrealPak запустился, но ничего не печатает (код возврата ' + $r.ExitCode + '). Проверьте антивирус (карантин) и сообщите об этом.')
        }
    }
    $packExe = Join-Path $script:ToolsDir 'UnrealPak_UE4_20.exe'
    if (Test-FileOk $packExe 100000) {
        $r2 = Invoke-ToolRun $packExe @()
        if (-not $r2.Started) {
            Die ('UnrealPak 4.20 (упаковщик) не запускается: ' + $r2.StartError + ' Установите https://aka.ms/vs/16/release/VC_redist.x64.exe и запустите пункт 1 заново.')
        }
    }
}

# ---------------------------------------------------------------------------
# setup
# ---------------------------------------------------------------------------
function Invoke-Setup {
    Msg 'Подготовка рабочей папки…'
    foreach ($sub in @($script:DirOrig, $script:DirJson, $script:DirMod, $script:DirOut, $script:DirReports)) {
        $d = Join-Path $script:WorkDir $sub
        if (-not (Test-Path -LiteralPath $d -PathType Container)) {
            New-Item -ItemType Directory -Path $d -Force | Out-Null
        }
    }
    Msg 'Загрузка инструментов (UAssetGUI, UnrealPak)…'
    Ensure-Tools
    Msg ''
    Msg ('Рабочая папка: ' + $script:WorkDir)
}

# ---------------------------------------------------------------------------
# extract
# ---------------------------------------------------------------------------
function Get-ContentSubpath([string]$p) {
    $norm = $p -replace '\\', '/'
    $parts = $norm -split '/'
    for ($i = 0; $i -lt $parts.Count; $i++) {
        if ($parts[$i] -eq 'Content' -and ($i + 1) -lt $parts.Count) {
            return (($parts[($i + 1)..($parts.Count - 1)]) -join '/')
        }
    }
    return $null
}

function Invoke-Extract([hashtable]$cfg) {
    $pakFiles = Get-GamePaks $cfg
    if ($pakFiles.Count -eq 0) {
        Die 'Не найдены .pak файлы игры. Сначала укажите путь к игре.'
    }
    $extractExe = (Join-Path $script:ToolsDir 'UnrealPak_4_25_3.exe')
    if (-not (Test-Path -LiteralPath $extractExe)) { Die 'UnrealPak (распаковщик) не найден. Выберите пункт 1 — он скачается автоматически.' }
    $origDir = Join-Path $script:WorkDir $script:DirOrig
    # orig всегда создаём с нуля: остатки прошлой распаковки (другой версии игры)
    # иначе могли бы попасть в мод и замаскировать сломанный распаковщик.
    if (Test-Path -LiteralPath $origDir -PathType Container) {
        Remove-Item -LiteralPath $origDir -Recurse -Force
    }
    New-Item -ItemType Directory -Path $origDir -Force | Out-Null

    Msg 'Извлечение политических ассетов из игровых .pak…'

    # --- Диагностика: список .pak, проверка IoStore, лог распаковки ---
    $reportsDir = Join-Path $script:WorkDir $script:DirReports
    if (-not (Test-Path -LiteralPath $reportsDir -PathType Container)) {
        New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null
    }
    $dbgPath = Join-Path $reportsDir 'extract_debug.txt'
    if (Test-Path -LiteralPath $dbgPath) { Remove-Item -LiteralPath $dbgPath -Force }
    [System.IO.File]::WriteAllText($dbgPath,
        ('Extract log: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + "`r`n" +
         'Скрипт: ' + $script:ScriptVersion + "`r`n"), $Utf8NoBom)
    $paksDir = Get-PaksDir $cfg
    foreach ($pak in $pakFiles) {
        $sz = [Math]::Round((Get-Item -LiteralPath $pak).Length / 1MB)
        Msg ('  pak: ' + [System.IO.Path]::GetFileName($pak) + ' (' + $sz + ' МБ)')
        [System.IO.File]::AppendAllText($dbgPath, ('pak: ' + $pak + ' (' + $sz + ' MB)' + "`r`n"), $Utf8NoBom)
    }
    if ($paksDir) {
        $iostore = @(Get-ChildItem -LiteralPath $paksDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -eq '.utoc' -or $_.Extension -eq '.ucas' })
        if ($iostore.Count -gt 0) {
            Warn2 ('В папке Paks найдены IoStore-контейнеры (.utoc/.ucas): ' + (($iostore | ForEach-Object { $_.Name }) -join ', '))
            Warn2 'Эта версия игры хранит ассеты в новом формате IoStore, который классический UnrealPak не распаковывает. Пришлите extract_debug.txt из папки reports — подготовлю поддержку.'
        }
    }

    # UnrealPak извлекает файлы с путём монтирования ../../../Tropico6/Content/...,
    # то есть НАД папкой назначения. Поэтому dest делаем на три уровня внутри orig:
    # при любом варианте поведения UnrealPak файлы окажутся внутри orig/ и будут найдены.
    $tmpDir = Join-Sub $origDir 'e1/e2/e3'
    $total = 0
    $seen = @{}
    $runFailures = 0
    foreach ($pattern in $script:ExtractFilters) {
        if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
        New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
        foreach ($pak in $pakFiles) {
            $name = [System.IO.Path]::GetFileName($pak)
            if ($name.Contains('_VO') -or $name.ToLower().Contains('vo_')) { continue }
            $r = Invoke-ToolRun $extractExe @($pak, '-Extract', $tmpDir, ('-Filter=' + $pattern))
            $status = $(if ($r.Started) { ('код возврата ' + $r.ExitCode) } else { ('ОТКАЗ ЗАПУСКА: ' + $r.StartError) })
            [System.IO.File]::AppendAllText($dbgPath, ('=== ' + $name + ' :: ' + $pattern + ' :: ' + $status + ' ===' + "`r`n" + ($r.Out + $r.Err) + "`r`n"), $Utf8NoBom)
            if (-not $r.Started) { $runFailures++ }
            # ненулевой код возврата здесь нормален: фильтр мог ничего не найти в этом паке
        }
        $got = Copy-ExtractedFiles $origDir $seen
        Msg ('  фильтр ' + $pattern.PadRight(22) + ' -> ' + $got + ' файлов')
        $total += $got
    }
    Msg ''
    Msg ('Итого извлечено файлов: ' + $total)
    if ($total -eq 0 -and $runFailures -gt 0) {
        Msg ''
        Msg ('ВНИМАНИЕ: UnrealPak ' + $runFailures + ' раз отказался запускаться при извлечении. Это не «файлы не найдены», а неработающий инструмент — см. extract_debug.txt.')
    }

    if ($total -eq 0) {
        # --- Запасной путь: оглавление pak (-List) и извлечение по точным именам ---
        # Причины нуля бывают разные: сломанный инструмент, изменённые имена ассетов
        # в новой версии игры или несовпадение семантики -Filter. -List отвечает на всё.
        Msg ''
        Msg 'Прямые фильтры ничего не дали. Читаю оглавления pak-ов (-List)...'
        # -List поддерживает не каждая сборка UnrealPak: упаковщик 4.20 умеет,
        # а скачанный распаковщик 4.25.3 — нет («unknown tokens at argument 0:
        # -List»). Поэтому перебираем инструменты в порядке надёжности.
        $packExeList = Join-Path $script:ToolsDir 'UnrealPak_UE4_20.exe'
        $listExes = @()
        if (Test-Path -LiteralPath $packExeList) { $listExes += $packExeList }
        if ($extractExe -and ($listExes -notcontains $extractExe)) { $listExes += $extractExe }
        $plainPatterns = @($script:ExtractFilters | ForEach-Object { $_.Trim('*').ToLowerInvariant() })
        $allMatches = @{}
        foreach ($pak in $pakFiles) {
            $name = [System.IO.Path]::GetFileName($pak)
            if ($name.Contains('_VO') -or $name.ToLower().Contains('vo_')) { continue }
            $r = $null
            foreach ($le in $listExes) {
                $rr = Invoke-ToolRun $le @($pak, '-List')
                $leName = [System.IO.Path]::GetFileName($le)
                if (-not $rr.Started) {
                    [System.IO.File]::AppendAllText($dbgPath, ('--- -List :: ' + $name + ' :: ' + $leName + ' :: ОТКАЗ ЗАПУСКА: ' + $rr.StartError + "`r`n"), $Utf8NoBom)
                    $runFailures++
                    continue
                }
                $probe = 0
                foreach ($m in [regex]::Matches($rr.Out, '\.(?:uasset|uexp|ubulk|umap)(?![A-Za-z])')) { $probe++ }
                $errLine = (($rr.Out + $rr.Err) -split "`r?`n" | Where-Object { $_ -match 'Error|error|unknown tokens' } | Select-Object -First 1)
                [System.IO.File]::AppendAllText($dbgPath, ('--- -List :: ' + $name + ' :: ' + $leName + ' :: код ' + $rr.ExitCode + ' :: записей ассетов: ' + $probe + $(if ($errLine) { ' :: ' + $errLine.Substring(0, [Math]::Min(300, $errLine.Length)) } else { '' }) + "`r`n"), $Utf8NoBom)
                if (-not $r) { $r = $rr }
                if ($probe -gt 0) { $r = $rr; break }
            }
            if (-not $r) { continue }
            $listPath = Join-Path $reportsDir ('pak_list_' + ($name -replace '\.pak$', '') + '.txt')
            [System.IO.File]::WriteAllText($listPath, $r.Out, $Utf8NoBom)
            [System.IO.File]::AppendAllText($dbgPath, ('--- -List :: ' + $name + ' :: код ' + $r.ExitCode + ' :: полная распечатка сохранена: ' + $listPath + "`r`n"), $Utf8NoBom)
            $entries = @{}
            foreach ($m in [regex]::Matches($r.Out, '[\w\-\./\\]+\.(?:uasset|uexp|ubulk|umap)')) {
                $e = ($m.Value -replace '\\', '/')
                $low = $e.ToLowerInvariant()
                foreach ($p in $plainPatterns) {
                    if ($low.Contains($p)) { $entries[$e] = $true; break }
                }
            }
            foreach ($e in $entries.Keys) { $allMatches[$e] = $pak }
            $totalEntries = 0
            foreach ($m in [regex]::Matches($r.Out, '\.(?:uasset|uexp|ubulk|umap)(?![A-Za-z])')) { $totalEntries++ }
            Msg ('  ' + $name + ': записей ассетов: ' + $totalEntries + ', подходит под наши шаблоны: ' + $entries.Count)
        }
        if ($allMatches.Count -gt 0) {
            Msg ('  Извлекаю по точным именам: ' + $allMatches.Count + ' файлов...')
            if ($allMatches.Count -gt 500) { Msg ('  (совпадений слишком много — извлеку первые 500)') }
            # Пробуем сначала распаковщик 4.25.3, затем (если ничего не извлеклось)
            # упаковщик 4.20: у того в справке заявлены и -Extract, и -Filter.
            $extractTryExes = @($extractExe)
            if ((Test-Path -LiteralPath $packExeList) -and ($extractTryExes -notcontains $packExeList)) { $extractTryExes += $packExeList }
            $seenExact = @{}
            foreach ($tryExe in $extractTryExes) {
                if ($total -gt 0) { break }
                $tryName = [System.IO.Path]::GetFileName($tryExe)
                if ($tryExe -ne $extractExe) { Msg ('  Пробую извлечение через ' + $tryName + '...') }
                if (Test-Path -LiteralPath $tmpDir) { Remove-Item -LiteralPath $tmpDir -Recurse -Force }
                New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
                $i = 0
                foreach ($e in $allMatches.Keys) {
                    $i++
                    if ($i -gt 500) { break }
                    $r = Invoke-ToolRun $tryExe @($allMatches[$e], '-Extract', $tmpDir, ('-Filter=' + $e))
                    $status2 = $(if ($r.Started) { ('код ' + $r.ExitCode) } else { ('ОТКАЗ: ' + $r.StartError) })
                    [System.IO.File]::AppendAllText($dbgPath, ('--- точное имя :: ' + $tryName + ' :: ' + $e + ' :: ' + $status2 + "`r`n"), $Utf8NoBom)
                    if (-not $r.Started) { $runFailures++ }
                }
                $total = Copy-ExtractedFiles $origDir $seenExact
                Msg ('  Извлечено по точным именам (' + $tryName + '): ' + $total + ' файлов')
            }
        }
    }

    if ($total -eq 0) {
        Msg ''
        Msg '---- Диагностика (конец лога UnrealPak) ----'
        $dbgLines = @([System.IO.File]::ReadAllLines($dbgPath))
        $from = [Math]::Max(0, $dbgLines.Count - 40)
        for ($k = $from; $k -lt $dbgLines.Count; $k++) { Msg ('  ' + $dbgLines[$k]) }
        Msg ('Полный лог: ' + $dbgPath)
        Msg ('Оглавления paks: ' + (Join-Path $reportsDir 'pak_list_*.txt'))
        Die 'Не извлечено ни одного файла. Пришлите extract_debug.txt и pak_list_*.txt из папки reports: по ним точно видно, запускался ли UnrealPak, читается ли pak и есть ли в вашей версии игры (1.29) нужные ассеты.'
    }
}

# Переносит извлечённое из временного e1/... в orig/Tropico6/Content/...
function Copy-ExtractedFiles([string]$origDir, [hashtable]$seen) {
    $contentRoot = Join-Sub $origDir 'Tropico6/Content'
    $got = 0
    foreach ($f in (Get-ChildItem -LiteralPath $origDir -Recurse -File -ErrorAction SilentlyContinue)) {
        $rel = Get-ContentSubpath $f.FullName
        if (-not $rel) { continue }
        if ($seen.ContainsKey($rel)) { continue }
        $seen[$rel] = $true
        $got++
        $dst = Join-Sub $contentRoot ($rel -replace '/', [System.IO.Path]::DirectorySeparatorChar)
        if ($f.FullName -eq $dst) { continue }   # файл уже лежит на нужном месте
        $dstDir = Split-Path -Parent $dst
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
    if (Test-Path -LiteralPath (Join-Sub $origDir 'e1')) {
        Remove-Item -LiteralPath (Join-Sub $origDir 'e1') -Recurse -Force
    }
    return $got
}

# ---------------------------------------------------------------------------
# UAssetGUI: tojson / fromjson
# ---------------------------------------------------------------------------
function Invoke-ToJson([string]$uassetPath, [string]$jsonPath) {
    $uag = Join-Path $script:ToolsDir 'UAssetGUI.exe'
    if (-not (Test-Path -LiteralPath $uag)) { Die 'UAssetGUI не найден. Выберите пункт 1 — он скачается автоматически.' }
    $null = Invoke-Tool $uag @('tojson', $uassetPath, $jsonPath, '26') ('конвертация в JSON: ' + $uassetPath)
    if (-not (Test-Path -LiteralPath $jsonPath)) { Die ('UAssetGUI не создал ' + $jsonPath) }
}

function Invoke-FromJson([string]$jsonPath, [string]$uassetPath) {
    $uag = Join-Path $script:ToolsDir 'UAssetGUI.exe'
    $null = Invoke-Tool $uag @('fromjson', $jsonPath, $uassetPath) ('сборка .uasset из JSON: ' + $uassetPath)
}

# ---------------------------------------------------------------------------
# Обход целей и правила рецепта
# ---------------------------------------------------------------------------
function Get-TargetAssets([string]$origRoot, [string]$target) {
    $relPosix = $target -replace '\\', '/'
    $base = Join-Path $origRoot ($relPosix -replace '/', [System.IO.Path]::DirectorySeparatorChar)
    $out = @()
    if ($relPosix.EndsWith('.uasset') -and (Test-Path -LiteralPath $base -PathType Leaf)) {
        $out += @{ Rel = $relPosix; Path = $base }
        return $out
    }
    if (-not (Test-Path -LiteralPath $base -PathType Container)) { return $out }
    foreach ($f in (Get-ChildItem -LiteralPath $base -Recurse -File -Filter '*.uasset' -ErrorAction SilentlyContinue | Sort-Object FullName)) {
        $rel = Get-ContentSubpath $f.FullName
        if ($rel) { $out += @{ Rel = $rel; Path = $f.FullName } }
    }
    return $out
}

function Get-Recipe {
    if ($null -ne $script:Recipe) { return $script:Recipe }
    $script:Recipe = ConvertFrom-JsonText $script:RecipeJson
    return $script:Recipe
}

function Get-RulesForAsset([object]$recipe, [string]$relContentPath) {
    $out = @()
    foreach ($rule in (Get-JProp $recipe 'rules')) {
        $glob = [string](Get-JProp $rule 'asset_glob')
        if ([regex]::IsMatch($relContentPath, ('^(' + $glob + ')$'))) { $out += $rule }
    }
    return $out
}

function Test-RuleMatch([object]$rule, [object]$node, [string]$pathStr) {
    $name = [string](Get-JProp $node 'Name')
    $excl = Get-JProp $rule 'exclude'
    if ($excl -and [regex]::IsMatch($name, [string]$excl)) { return $false }
    if (-not [regex]::IsMatch($name, [string](Get-JProp $rule 'property'))) { return $false }
    $ctx = Get-JProp $rule 'context'
    if ($ctx -and -not [regex]::IsMatch($pathStr, [string]$ctx)) { return $false }
    $val = Get-JProp $node 'Value'
    if (-not (Test-Number $val)) { return $false }
    $cond = Get-JProp $rule 'if_value'
    if ($cond) {
        if ($cond -eq '>0' -and $val -le 0) { return $false }
        if ($cond -eq '>=1' -and $val -lt 1) { return $false }
    }
    $range = Get-JProp $rule 'range'
    if ($range) {
        $rmin = [double]$range[0]; $rmax = [double]$range[1]
        if (([double]$val -lt $rmin) -or ([double]$val -gt $rmax)) { return $false }
    }
    return $true
}

function Get-NewValue([object]$rule, $old) {
    $action = [string](Get-JProp $rule 'action')
    if ($action -eq 'scale') { $new = [double]$old * [double](Get-JProp $rule 'value') }
    elseif ($action -eq 'set') { $new = [double](Get-JProp $rule 'value') }
    else { Die ('неизвестное действие: ' + $action) }
    $lo = -1e12; $hi = 1e12
    $clamp = Get-JProp $rule 'clamp'
    if ($clamp) { $lo = [double]$clamp[0]; $hi = [double]$clamp[1] }
    $new = [Math]::Min([Math]::Max($new, $lo), $hi)
    if ($old -is [int] -or $old -is [long]) { $new = [int][Math]::Round($new) }
    else { $new = [double]$new }
    $changed = -not ([Math]::Abs([double]$new - [double]$old) -le ([Math]::Abs([double]$old) * 1e-9 + 1e-9))
    return @{ New = $new; Changed = $changed }
}

# ---------------------------------------------------------------------------
# patch
# ---------------------------------------------------------------------------
function Copy-ModAsset([string]$rel, [string]$origRoot) {
    $modRoot = Join-Sub (Join-Path $script:WorkDir $script:DirMod) 'Tropico6/Content'
    $relLocal = $rel -replace '/', [System.IO.Path]::DirectorySeparatorChar
    $dstUasset = Join-Path $modRoot $relLocal
    $dstDir = Split-Path -Parent $dstUasset
    if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
    $srcUasset = Join-Path $origRoot $relLocal
    Copy-Item -LiteralPath $srcUasset -Destination $dstUasset -Force
    $srcUexp = $srcUasset.Substring(0, $srcUasset.Length - 7) + '.uexp'
    if (Test-Path -LiteralPath $srcUexp) {
        Copy-Item -LiteralPath $srcUexp -Destination ($dstUasset.Substring(0, $dstUasset.Length - 7) + '.uexp') -Force
    }
    return $dstUasset
}

function Get-RoundtripMap([string]$modUasset) {
    $tmpJson = $modUasset.Substring(0, $modUasset.Length - 7) + '.verify.json'
    Invoke-ToJson $modUasset $tmpJson
    $data = ConvertFrom-JsonText (Read-Text $tmpJson)
    $actual = @{}
    foreach ($pair in (Get-AllNodes (Get-JProp $data 'Exports'))) {
        $node = $pair[0]; $pathArr = $pair[1]
        $val = Get-JProp $node 'Value'
        if (Test-Number $val) {
            $k = ($pathArr -join ' / ')
            if (-not $actual.ContainsKey($k)) { $actual[$k] = $val }
        }
    }
    try { Remove-Item -LiteralPath $tmpJson -Force -ErrorAction SilentlyContinue } catch { }
    return $actual
}

function Test-RoundtripOk([hashtable]$actual, [hashtable]$change) {
    $k = [string]$change['Path']
    if (-not $actual.ContainsKey($k)) { return $false }
    $got = [double]$actual[$k]
    $want = [double]$change['New']
    return ([Math]::Abs($got - $want) -le ([Math]::Abs($want) * 1e-4 + 1e-6))
}

function Invoke-HexPatch([string]$modUasset, [hashtable]$change) {
    # Бинарное исправление значения, которое UAssetGUI не записал в .uexp
    # (известная проблема FloatProperty/ByteProperty в fromjson).
    $uexp = $modUasset.Substring(0, $modUasset.Length - 7) + '.uexp'
    if (-not (Test-Path -LiteralPath $uexp)) { return $false }
    $oldV = $change['Old']; $newV = $change['New']
    if ($oldV -is [int] -or $oldV -is [long]) {
        $oldB = [System.BitConverter]::GetBytes([int]$oldV)
        $newB = [System.BitConverter]::GetBytes([int][Math]::Round([double]$newV))
    } else {
        $oldB = [System.BitConverter]::GetBytes([single][double]$oldV)
        $newB = [System.BitConverter]::GetBytes([single][double]$newV)
    }
    $backup = [System.IO.File]::ReadAllBytes($uexp)
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    $dataStr = $enc.GetString($backup)
    $pat = $enc.GetString($oldB)
    $positions = @()
    $start = 0
    while ($true) {
        $pos = $dataStr.IndexOf($pat, $start, [System.StringComparison]::Ordinal)
        if ($pos -lt 0) { break }
        $positions += $pos
        $start = $pos + 1
        if ($positions.Count -gt 1000) { break }
    }
    if ($positions.Count -eq 0) { return $false }
    foreach ($pos in $positions) {
        $data = $backup.Clone()
        [System.Buffer]::BlockCopy($newB, 0, $data, $pos, $newB.Length)
        [System.IO.File]::WriteAllBytes($uexp, $data)
        $actual = Get-RoundtripMap $modUasset
        if (Test-RoundtripOk $actual $change) { return $true }
    }
    [System.IO.File]::WriteAllBytes($uexp, $backup)
    return $false
}

function Invoke-Patch {
    $recipe = Get-Recipe
    $origRoot = Join-Sub (Join-Path $script:WorkDir $script:DirOrig) 'Tropico6/Content'
    if (-not (Test-Path -LiteralPath $origRoot -PathType Container)) {
        Die 'Нет извлечённых ассетов. Сначала извлеките их (пункт 1).'
    }
    $jsonDir = Join-Path $script:WorkDir $script:DirJson
    $reportsDir = Join-Path $script:WorkDir $script:DirReports
    foreach ($d in @($jsonDir, $reportsDir)) {
        if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    }

    Msg 'Применение рецепта правок…'
    $log = @()
    $touched = @{}
    $targets = @(Get-JProp $recipe 'patch_targets')
    if ($targets.Count -eq 0) { $targets = $script:PatchTargets }
    foreach ($target in $targets) {
        foreach ($asset in (Get-TargetAssets $origRoot ([string]$target))) {
            $rel = [string]$asset.Rel
            $rules = Get-RulesForAsset $recipe $rel
            if ($rules.Count -eq 0) { continue }
            $jname = ($rel -replace '/', '__') -replace '\.uasset$', '.json'
            $jpath = Join-Path $jsonDir $jname
            # JSON создаём заново при каждом запуске из свежего оригинала:
            # файл от прошлого запуска содержал бы уже изменённые значения,
            # и повторная установка применила бы множители второй раз.
            Invoke-ToJson ([string]$asset.Path) $jpath
            $data = ConvertFrom-JsonText (Read-Text $jpath)

            $changes = @()
            foreach ($pair in (Get-AllNodes (Get-JProp $data 'Exports'))) {
                $node = $pair[0]; $pathArr = $pair[1]
                $pathStr = ($pathArr -join ' / ')
                foreach ($rule in $rules) {
                    $val = Get-JProp $node 'Value'
                    if (-not (Test-Number $val)) { continue }
                    if (-not (Test-RuleMatch $rule $node $pathStr)) { continue }
                    $res = Get-NewValue $rule $val
                    if (-not $res.Changed) { continue }
                    $entry = @{
                        Rule = [string](Get-JProp $rule 'id')
                        Desc = [string](Get-JProp $rule 'desc')
                        Asset = $rel; Path = $pathStr
                        Old = $val; New = $res.New
                    }
                    $changes += $entry
                    $log += $entry
                    Set-JProp $node 'Value' $res.New
                    break
                }
            }
            if ($changes.Count -eq 0) { continue }

            Write-Text $jpath (ConvertTo-JsonText $data)
            $modUasset = Copy-ModAsset $rel $origRoot
            Invoke-FromJson $jpath $modUasset

            # проверка записи + бинарное исправление при необходимости
            $actual = Get-RoundtripMap $modUasset
            foreach ($ch in $changes) {
                if (Test-RoundtripOk $actual $ch) { continue }
                if (Invoke-HexPatch $modUasset $ch) {
                    Msg ('  [bin] ' + $rel + ': ' + $ch.Path + ' = ' + $ch.New + ' (бинарная правка)')
                } else {
                    Warn2 ('Значение не удалось записать: ' + $rel + ' :: ' + $ch.Path + ' (' + $ch.Old + ' -> ' + $ch.New + ')')
                    $ch['Failed'] = $true
                }
            }
            $touched[$rel] = $true
        }
    }

    $logPath = Join-Path $reportsDir 'patch_log.json'
    Write-Text $logPath (ConvertTo-JsonText @($log | ForEach-Object {
        $e = $_; $rec = @{}
        foreach ($k in @('Rule','Desc','Asset','Path','Old','New')) { $rec[$k] = $e[$k] }
        if ($e.ContainsKey('Failed')) { $rec['Failed'] = $e['Failed'] }
        $rec
    }))
    Msg ''
    $okCount = 0; $failCount = 0
    foreach ($e in $log) { if ($e.ContainsKey('Failed')) { $failCount++ } else { $okCount++ } }
    $failNote = ''
    if ($failCount -gt 0) { $failNote = ' (не записано: ' + $failCount + ')' }
    Msg ('Изменено значений: ' + $okCount + ' из ' + $log.Count + $failNote)
    Msg ('Изменено ассетов: ' + $touched.Count)
    if ($touched.Count -gt 0) {
        Msg 'Ассеты:'
        foreach ($rel in ($touched.Keys | Sort-Object)) { Msg ('  - ' + $rel) }
    }
    Msg ('Журнал правок: ' + $logPath)
    if ($log.Count -eq 0) {
        Warn2 'Ни одно правило не сработало. Возможно, структура ассетов вашей версии игры отличается.'
        Die 'Правки не применены — мод не собран.'
    }
    if ($failCount -gt 0) { Die 'Есть значения, которые не удалось записать. См. журнал правок.' }
}

# ---------------------------------------------------------------------------
# package / verify / install / uninstall
# ---------------------------------------------------------------------------
function Invoke-Package {
    $modRoot = Join-Path (Join-Path $script:WorkDir $script:DirMod) 'Tropico6'
    $hasUasset = $false
    if (Test-Path -LiteralPath $modRoot) {
        foreach ($f in (Get-ChildItem -LiteralPath $modRoot -Recurse -File -Filter '*.uasset' -ErrorAction SilentlyContinue)) { $hasUasset = $true; break }
    }
    if (-not $hasUasset) { Die 'Нет исправленных файлов. Сначала примените правки (пункт 1).' }
    $packExe = Join-Path $script:ToolsDir 'UnrealPak_UE4_20.exe'
    if (-not (Test-Path -LiteralPath $packExe)) { Die 'UnrealPak (упаковщик) не найден. Выберите пункт 1 — он скачается автоматически.' }
    $outDir = Join-Path $script:WorkDir $script:DirOut
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
    $pakPath = Join-Path $outDir $script:ModPakName
    if (Test-Path -LiteralPath $pakPath) { Remove-Item -LiteralPath $pakPath -Force }

    # файл-ответ для UnrealPak (только абсолютные пути!)
    $resp = Join-Path $script:WorkDir '_pak_response.txt'
    Write-Text $resp ('"' + $modRoot + '\*" "../../../Tropico6/Content/"')
    $null = Invoke-Tool $packExe @($pakPath, ('-Create=' + $resp), '-compress') 'упаковка мода'

    if (-not (Test-Path -LiteralPath $pakPath) -or ((Get-Item -LiteralPath $pakPath).Length -lt 500)) {
        Die 'Не удалось собрать .pak (файл отсутствует или слишком мал).'
    }
    $listing = Invoke-Tool $packExe @($pakPath, '-List') 'чтение содержимого .pak'
    $nFiles = ([regex]::Matches($listing, '\.uasset')).Count
    Msg ''
    Msg ('Собран мод: ' + $pakPath)
    Msg ('Размер: ' + [Math]::Round((Get-Item -LiteralPath $pakPath).Length / 1024.0, 1) + ' КБ, .uasset внутри: ' + $nFiles)
    if ($nFiles -eq 0) { Die 'В .pak не попали ассеты — проверьте work/modfiles.' }
}

function Invoke-Verify {
    $pakPath = Join-Path (Join-Path $script:WorkDir $script:DirOut) $script:ModPakName
    if (-not (Test-Path -LiteralPath $pakPath)) { Die 'Сначала соберите мод.' }
    $logPath = Join-Path (Join-Path $script:WorkDir $script:DirReports) 'patch_log.json'
    if (-not (Test-Path -LiteralPath $logPath)) { Die 'Не найден журнал правок. Сначала примените правки (пункт 1).' }
    $log = ConvertFrom-JsonText (Read-Text $logPath)
    $failed = @()
    $logItems = @($log)
    foreach ($e in $logItems) {
        if (Test-JProp $e 'Failed') { $failed += $e }
    }
    if ($failed.Count -gt 0) {
        foreach ($e in $failed) {
            Warn2 ('не записано: ' + (Get-JProp $e 'Asset') + ' :: ' + (Get-JProp $e 'Path'))
        }
        Die 'В журнале есть незаписанные значения — пересоберите мод после исправления.'
    }
    Msg ('Журнал: ' + $logItems.Count + ' правок, все значения подтверждены ранее.')
    Msg 'Проверка содержимого .pak…'
    $packExe = Join-Path $script:ToolsDir 'UnrealPak_UE4_20.exe'
    $listing = Invoke-Tool $packExe @($pakPath, '-List') 'чтение содержимого .pak'
    $expected = @{}
    foreach ($e in $logItems) { $expected[[string](Get-JProp $e 'Asset')] = $true }
    $missing = @()
    foreach ($rel in ($expected.Keys | Sort-Object)) {
        if (-not $listing.Contains($rel)) { $missing += $rel }
    }
    if ($missing.Count -gt 0) {
        foreach ($rel in $missing) { Warn2 ('в .pak нет файла: ' + $rel) }
        Die 'Проверка не пройдена.'
    }
    Msg ('[ok] Все ' + $expected.Count + ' изменённых ассетов присутствуют в .pak.')
}

function Invoke-Install([hashtable]$cfg) {
    $pakSrc = Join-Path (Join-Path $script:WorkDir $script:DirOut) $script:ModPakName
    if (-not (Test-Path -LiteralPath $pakSrc)) { Die 'Сначала соберите мод (пункт 1).' }
    $d = Get-PaksDir $cfg
    if (-not $d) { Die 'Не найдена папка Paks игры — укажите путь к игре.' }
    $dst = Join-Path $d $script:ModPakName
    Copy-Item -LiteralPath $pakSrc -Destination $dst -Force
    Msg ('Мод установлен: ' + $dst)
    Msg ''
    Msg 'Готово! Запустите Tropico 6 — мод загрузится автоматически.'
    Msg ('Отключить мод: удалите файл ' + $dst)
    Msg '              или запустите эту программу и выберите пункт 2.'
}

function Invoke-Uninstall([hashtable]$cfg) {
    $d = Get-PaksDir $cfg
    if ($d) {
        $dst = Join-Path $d $script:ModPakName
        if (Test-Path -LiteralPath $dst) {
            Remove-Item -LiteralPath $dst -Force
            Msg ('Мод удалён: ' + $dst)
            Msg 'Игра полностью вернулась к стандартному поведению (оригинальные файлы не изменялись).'
        } else {
            Msg 'Мод в игре не найден (уже удалён).'
        }
    } else {
        Warn2 ('Не найдена папка Paks игры. Удалите вручную: <игра>\Tropico6\Content\Paks\' + $script:ModPakName)
    }
}

# ---------------------------------------------------------------------------
# scan / status
# ---------------------------------------------------------------------------
function Invoke-Scan {
    $recipe = Get-Recipe
    $origRoot = Join-Sub (Join-Path $script:WorkDir $script:DirOrig) 'Tropico6/Content'
    if (-not (Test-Path -LiteralPath $origRoot -PathType Container)) {
        Die 'Нет извлечённых ассетов. Сначала извлеките их (пункт 1).'
    }
    $jsonDir = Join-Path $script:WorkDir $script:DirJson
    if (-not (Test-Path -LiteralPath $jsonDir)) { New-Item -ItemType Directory -Path $jsonDir -Force | Out-Null }
    $lines = @()
    $countFiles = 0
    $targets = @(Get-JProp $recipe 'patch_targets') + @(Get-JProp $recipe 'scan_targets')
    foreach ($target in $targets) {
        foreach ($asset in (Get-TargetAssets $origRoot ([string]$target))) {
            $jname = (([string]$asset.Rel -replace '/', '__') -replace '\.uasset$', '.json')
            $jpath = Join-Path $jsonDir $jname
            # JSON создаём заново: отчёт должен показывать актуальные
            # оригинальные значения игры, а не остатки прошлого запуска.
            Invoke-ToJson ([string]$asset.Path) $jpath
            $countFiles++
            $data = ConvertFrom-JsonText (Read-Text $jpath)
            foreach ($pair in (Get-AllNodes (Get-JProp $data 'Exports'))) {
                $node = $pair[0]; $pathArr = $pair[1]
                $val = Get-JProp $node 'Value'
                if (Test-Number $val) {
                    $lines += ([string]$asset.Rel + ' :: ' + ($pathArr -join ' / ') + ' = ' + $val)
                }
            }
        }
    }
    $reportsDir = Join-Path $script:WorkDir $script:DirReports
    if (-not (Test-Path -LiteralPath $reportsDir)) { New-Item -ItemType Directory -Path $reportsDir -Force | Out-Null }
    $report = Join-Path $reportsDir 'politics_scan.txt'
    Write-Text $report ((('# Отчёт scan — ' + (Get-Date).ToString('yyyy-MM-dd HH:mm') + ' — скрипт ' + $script:ScriptVersion)) + "`r`n" + ($lines -join "`r`n"))
    Msg ('Просмотрено ассетов: ' + $countFiles)
    Msg ('Числовых параметров: ' + $lines.Count)
    Msg ('Полный отчёт: ' + $report)
}

function Show-Status([hashtable]$cfg) {
    Msg $script:ModTitle
    Msg ('Версия скрипта: ' + $script:ScriptVersion)
    Msg ''
    $game = Find-GameRoot $cfg
    Msg ('Игра:            ' + $(if ($game) { $game } else { 'не найдена' }))
    Msg ('Рабочая папка:   ' + $script:WorkDir)
    foreach ($spec in $script:ToolDownloads) {
        $ok = (Test-Path -LiteralPath $spec.Path) -and ((Get-Item -LiteralPath $spec.Path -ErrorAction SilentlyContinue).Length -gt 100000)
        Msg (($(if ($ok) { '[ok] ' } else { '[--] ' })) + $spec.Label + '  ' + $spec.Path)
    }
    foreach ($sub in @($script:DirOrig, $script:DirMod, $script:DirOut)) {
        $d = Join-Path $script:WorkDir $sub
        $n = 0
        if (Test-Path -LiteralPath $d) {
            foreach ($f in (Get-ChildItem -LiteralPath $d -Recurse -File -ErrorAction SilentlyContinue)) { $n++ }
        }
        Msg (($(if ($n -gt 0) { '[ok]' } else { '[--]' })) + ' ' + $sub.PadRight(24) + ' файлов: ' + $n)
    }
    $d = Get-PaksDir $cfg
    $installed = $false
    if ($d -and (Test-Path -LiteralPath (Join-Path $d $script:ModPakName))) { $installed = $true }
    Msg ('В игре установлен: ' + $(if ($installed) { 'да' } else { 'нет' }))
}

# ---------------------------------------------------------------------------
# Полный конвейер и меню
# ---------------------------------------------------------------------------
function Invoke-FullInstall {
    $cfg = Get-Config
    Invoke-Setup
    $root = Find-GameRoot $cfg
    if (-not $root) {
        $root = Read-GameRootFromUser
        $cfg['game_root'] = $root
        Save-Config $cfg
        Msg ('Путь к игре сохранён: ' + $root)
    }
    Msg ('Игра: ' + $root)
    Msg ''
    Invoke-Extract $cfg
    Msg ''
    Invoke-Patch
    Msg ''
    Invoke-Package
    Msg ''
    Invoke-Verify
    Msg ''
    Invoke-Install $cfg
    Msg ''
    Msg '=========================================================='
    Msg ' Мод Hardball Politics собран и установлен.'
    Msg ' Проверка в игре: выборы, речи, ультиматумы, восстания.'
    Msg '=========================================================='
}

function Show-MainMenu {
    Msg ''
    Msg ('=== ' + $script:ModTitle + ' ===')
    Msg ('Версия скрипта: ' + $script:ScriptVersion)
    Msg 'Если этой строки нет или версия другая — вы запустили старую копию файла!'
    Msg 'Всё в одном файле: ничего устанавливать не нужно (только Windows PowerShell).'
    while ($true) {
        Msg ''
        Msg '  1) Установить мод (все шаги автоматически: извлечь, править, собрать, установить)'
        Msg '  2) Удалить мод из игры'
        Msg '  3) Статус и диагностика'
        Msg '  4) Подробный отчёт о параметрах игры (scan)'
        Msg '  0) Выход'
        $choice = Read-Host 'Выберите пункт'
        try {
            switch ($choice.Trim()) {
                '1' { Invoke-FullInstall }
                '2' { Invoke-Uninstall (Get-Config) }
                '3' { Show-Status (Get-Config) }
                '4' { Invoke-Scan }
                '0' { return }
                default { Msg 'Нет такого пункта.' }
            }
        } catch {
            Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
            Msg 'Можно повторить действие — окно не закроется.'
        }
    }
}

if (-not $global:HardballNoMain) {
    try {
        if ($args.Count -gt 0) {
            $cmd = [string]$args[0]
            $cfg = Get-Config
            switch ($cmd.ToLower()) {
                'all'        { Invoke-FullInstall }
                'setup'      { Invoke-Setup }
                'extract'    { Invoke-Extract $cfg }
                'scan'       { Invoke-Scan }
                'patch'      { Invoke-Patch }
                'package'    { Invoke-Package }
                'verify'     { Invoke-Verify }
                'install'    { Invoke-Install $cfg }
                'uninstall'  { Invoke-Uninstall $cfg }
                'status'     { Show-Status $cfg }
                default      { Die ('Неизвестная команда: ' + $cmd) }
            }
        } else {
            Show-MainMenu
        }
    } catch {
        Write-Host ('ОШИБКА: ' + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
}
