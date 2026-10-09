#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Hardball Politics («Политика без поблажек») — утилита сборки и установки
мода для Tropico 6.

Полностью автоматизирует конвейер:
  1. setup    — подготовка рабочей папки и загрузка инструментов
                (UAssetGUI, UnrealPak 4.25.3 для распаковки, UnrealPak 4.20 для сборки).
  2. extract  — извлечение политических ассетов из .pak-файлов вашей копии игры.
  3. scan     — разбор ассетов и подробный отчёт по всем политическим параметрам.
  4. patch    — применение рецепта правок (recipe/hardball_recipe.json)
                с проверкой исходных значений и полным журналом изменений.
  5. package  — сборка z_HardballPolitics.pak.
  6. install  — установка мода в игру. uninstall — удаление (полное восстановление).
  7. doctor   — проверка окружения. status — текущее состояние.

Оригинальные файлы игры никогда не изменяются: мод представляет собой
отдельный .pak, который игра загружает поверх оригинала. Удаление .pak
полностью возвращает стандартное поведение.
"""

import argparse
import json
import math
import os
import re
import shutil
import struct
import subprocess
import sys
from urllib.request import Request, urlopen

APP_DIR = os.path.dirname(os.path.abspath(__file__))
RECIPE_PATH = os.path.join(APP_DIR, "recipe", "hardball_recipe.json")
CONFIG_PATH = os.path.join(APP_DIR, "hardball_config.json")
MOD_ID = "HardballPolitics"
MOD_TITLE = "Hardball Politics — Политика без поблажек"
MOD_PAK_NAME = "z_HardballPolitics.pak"

DEFAULT_CONFIG = {
    "game_root": "",
    "work_dir": os.path.join(APP_DIR, "work"),
    "uassetgui_exe": os.path.join(APP_DIR, "tools", "UAssetGUI.exe"),
    "unrealpak_extract_exe": os.path.join(APP_DIR, "tools", "UnrealPak_4_25_3.exe"),
    "unrealpak_pack_exe": os.path.join(APP_DIR, "tools", "UnrealPak_UE4_20.exe"),
    "uasset_engine_version": "26",
    "mod_pak_name": MOD_PAK_NAME,
}

# Каталоги внутри рабочей папки
DIR_ORIG = "orig"        # распакованные оригиналы (только чтение)
DIR_JSON = "json"        # JSON-представления (UAssetGUI)
DIR_MOD = "modfiles"     # исправленные .uasset/.uexp для упаковки
DIR_OUT = "output"       # готовые .pak
DIR_REPORTS = "reports"  # отчёты

# Что извлекаем из игры: фильтры UnrealPak.
EXTRACT_FILTERS = [
    "*T6SingletonData*",
    "*FactionUltimatum*",
    "*FactionDemand*",
    "*T6Escalation*",
    "*GuerillaRebel*",
]

# Пути (относительно Tropico6/Content), к которым применяется рецепт.
PATCH_TARGETS = [
    "Blueprints/GameData/BP_T6SingletonData.uasset",
    "Blueprints/Ultimatums/Factions/",
    "Blueprints/Demands/Factions/",
]


def msg(text=""):
    print(text)


def warn(text):
    print("[ВНИМАНИЕ] " + text)


def die(text, code=1):
    print("[ОШИБКА] " + text, file=sys.stderr)
    sys.exit(code)


def load_config():
    if not os.path.exists(CONFIG_PATH):
        return dict(DEFAULT_CONFIG)
    with open(CONFIG_PATH, encoding="utf-8") as f:
        loaded = json.load(f)
    cfg = dict(DEFAULT_CONFIG)
    cfg.update(loaded)
    return cfg


def save_config(cfg):
    with open(CONFIG_PATH, "w", encoding="utf-8") as f:
        json.dump(cfg, f, indent=2, ensure_ascii=False)


def find_game_root(cfg):
    """Автопоиск корня игры (папка, содержащая Tropico6/Content/Paks)."""
    if cfg.get("game_root"):
        return cfg["game_root"]
    candidates = [
        r"C:\Program Files (x86)\Steam\steamapps\common\Tropico 6",
        r"C:\Program Files\Steam\steamapps\common\Tropico 6",
        os.path.expandvars(r"%ProgramFiles%\Epic Games\Tropico6"),
        os.path.expandvars(r"%ProgramFiles(x86)%\Epic Games\Tropico6"),
    ]
    for c in candidates:
        if os.path.isdir(os.path.join(c, "Tropico6", "Content", "Paks")):
            return c
    return ""


def paks_dir(cfg):
    root = find_game_root(cfg)
    if not root:
        return ""
    d = os.path.join(root, "Tropico6", "Content", "Paks")
    return d if os.path.isdir(d) else ""


def game_paks(cfg):
    d = paks_dir(cfg)
    if not d:
        return []
    paks = []
    for f in sorted(os.listdir(d)):
        if f.lower().endswith(".pak") and not f.startswith(("z_", "ZZZ_")):
            paks.append(os.path.join(d, f))
    return paks


def run_cmd(cmd, what=""):
    """Запуск внешнего инструмента с понятными сообщениями об ошибках."""
    proc = subprocess.run(cmd, capture_output=True, text=True, shell=False)
    if proc.returncode != 0:
        msg("")
        msg("Команда: " + " ".join('"%s"' % c for c in cmd))
        if proc.stdout.strip():
            msg(proc.stdout.strip()[-3000:])
        if proc.stderr.strip():
            msg(proc.stderr.strip()[-3000:])
        die("Не удалось выполнить: %s" % (what or cmd[0]))
    return proc.stdout


# ---------------------------------------------------------------------------
# setup: загрузка инструментов
# ---------------------------------------------------------------------------

TOOL_DOWNLOADS = {
    "uassetgui_exe": {
        "label": "UAssetGUI (конвертер .uasset <-> JSON)",
        "urls": [
            "https://github.com/atenfyr/UAssetGUI/releases/download/v1.1.0/UAssetGUI.exe",
            "https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UAssetGUI.exe",
        ],
    },
    "unrealpak_extract_exe": {
        "label": "UnrealPak 4.25.3 (распаковка игровых .pak)",
        "urls": [
            "https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UnrealPakTool/UnrealPak.exe",
        ],
    },
    "unrealpak_pack_exe": {
        "label": "UnrealPak 4.20 (сборка модового .pak)",
        "urls": [
            "https://raw.githubusercontent.com/zhuangchengfeng/Tropico6Mod_Agent/master/UnrealPakTool/UnrealPak%5Bv5_UE4.20%5D.exe",
        ],
    },
}


def download(url, dest):
    msg("  скачиваю: " + url)
    req = Request(url, headers={"User-Agent": "Mozilla/5.0"})
    with urlopen(req, timeout=180) as resp, open(dest, "wb") as out:
        shutil.copyfileobj(resp, out)


def cmd_setup(args, cfg):
    work = cfg["work_dir"]
    for sub in (DIR_ORIG, DIR_JSON, DIR_MOD, DIR_OUT, DIR_REPORTS):
        os.makedirs(os.path.join(work, sub), exist_ok=True)
    os.makedirs(os.path.dirname(cfg["uassetgui_exe"]) or "tools", exist_ok=True)

    for key, spec in TOOL_DOWNLOADS.items():
        dest = cfg[key]
        if os.path.isfile(dest) and os.path.getsize(dest) > 100_000:
            msg("  [ok] %s уже на месте" % spec["label"])
            continue
        last_err = None
        for url in spec["urls"]:
            try:
                download(url, dest)
                if os.path.getsize(dest) > 100_000:
                    msg("  [ok] загружен: %s" % spec["label"])
                    break
            except Exception as e:  # noqa: BLE001
                last_err = e
        else:
            warn("Не удалось скачать %s (%s). Положите файл вручную в %s "
                 "или укажите путь в hardball_config.json." %
                 (spec["label"], last_err, dest))

    # Настройка пути к игре
    root = find_game_root(cfg)
    if root:
        cfg["game_root"] = root
        msg("  [ok] игра найдена: " + root)
    else:
        warn("Игра не найдена автоматически. Запустите: "
             'python hardball.py set-game "C:\\...\\Tropico 6"')
    save_config(cfg)
    msg("")
    msg("Рабочая папка: " + work)
    msg("Следующий шаг: python hardball.py extract")


def cmd_set_game(args, cfg):
    root = args.path
    if not os.path.isdir(os.path.join(root, "Tropico6", "Content", "Paks")):
        die("В указанной папке нет Tropico6\\Content\\Paks. "
            "Укажите корневую папку игры (где лежит папка Tropico6).")
    cfg["game_root"] = root
    save_config(cfg)
    msg("Путь к игре сохранён: " + root)


# ---------------------------------------------------------------------------
# extract: извлечение ассетов из игры
# ---------------------------------------------------------------------------

def content_subpath(path):
    """Из полного пути извлечённого файла возвращает путь относительно
    Tropico6/Content (или None)."""
    norm = os.path.normpath(path).replace("\\", "/")
    parts = norm.split("/")
    for i, p in enumerate(parts):
        if p == "Content" and i + 1 < len(parts):
            return "/".join(parts[i + 1:])
    return None


def cmd_extract(args, cfg):
    pak_files = game_paks(cfg)
    if not pak_files:
        die("Не найдены .pak файлы игры. Проверьте game_root в hardball_config.json.")
    extract_exe = cfg["unrealpak_extract_exe"]
    if not os.path.isfile(extract_exe):
        die("UnrealPak (распаковщик) не найден: %s. Сначала выполните: "
            "python hardball.py setup" % extract_exe)
    orig_dir = os.path.join(cfg["work_dir"], DIR_ORIG)
    os.makedirs(orig_dir, exist_ok=True)

    total = 0
    for pattern in EXTRACT_FILTERS:
        dest = os.path.join(orig_dir, "filter_" + pattern.strip("*"))
        got = 0
        for pak in pak_files:
            name = os.path.basename(pak)
            if "_VO" in name or "vo_" in name.lower():
                continue  # паки локализации/озвучки не нужны
            out = subprocess.run(
                [extract_exe, pak, "-Extract", dest, "-Filter=" + pattern],
                capture_output=True, text=True, shell=False)
            if out.returncode != 0:
                warn("Извлечение %s из %s завершилось с кодом %d "
                     "(часто это нормально: фильтр ничего не нашёл в этом паке)."
                     % (pattern, name, out.returncode))
        for root, _dirs, files in os.walk(dest):
            for f in files:
                rel = content_subpath(os.path.join(root, f))
                if rel:
                    dst = os.path.join(orig_dir, "Tropico6", "Content", *rel.split("/"))
                    os.makedirs(os.path.dirname(dst), exist_ok=True)
                    shutil.copy2(os.path.join(root, f), dst)
                    got += 1
        # временные фильтры удаляем, итог лежит в orig/Tropico6/Content/...
        shutil.rmtree(dest, ignore_errors=True)
        msg("  фильтр %-22s -> %d файлов" % (pattern, got))
        total += got

    msg("")
    msg("Итого извлечено файлов: %d" % total)
    msg("Следующий шаг: python hardball.py scan  (отчёт о параметрах)")
    msg("             или python hardball.py patch (применить правки сразу)")


# ---------------------------------------------------------------------------
# UAssetGUI: tojson / fromjson / roundtrip
# ---------------------------------------------------------------------------

def uag(cfg):
    exe = cfg["uassetgui_exe"]
    if not os.path.isfile(exe):
        die("UAssetGUI не найден: %s. Сначала выполните: "
            "python hardball.py setup" % exe)
    return exe


def to_json(cfg, uasset_path, json_path):
    run_cmd([uag(cfg), "tojson", uasset_path, json_path,
             cfg["uasset_engine_version"]],
            "конвертация в JSON: " + uasset_path)
    if not os.path.isfile(json_path):
        die("UAssetGUI не создал %s" % json_path)


def from_json(cfg, json_path, uasset_path):
    run_cmd([uag(cfg), "fromjson", json_path, uasset_path],
            "сборка .uasset из JSON: " + uasset_path)


def iter_nodes(obj, path=()):
    """Рекурсивный обход структуры UAssetGUI-JSON.
    Возвращает (узел, путь_кортежем_имен); путь включает имя самого узла."""
    if isinstance(obj, dict):
        name = obj.get("Name")
        if isinstance(name, str):
            path = path + (name,)
            yield obj, path
        for v in obj.values():
            yield from iter_nodes(v, path)
    elif isinstance(obj, list):
        for item in obj:
            yield from iter_nodes(item, path)


def path_str(path):
    return " / ".join(path)


def iter_asset_files(orig_root, target):
    """Выдаёт (rel_content_path, abs_uasset) для цели рецепта."""
    base = os.path.join(orig_root, *target.split("/"))
    if os.path.isfile(base) and base.endswith(".uasset"):
        yield target, base
        return
    if not os.path.isdir(base):
        return
    for root, _dirs, files in os.walk(base):
        for f in sorted(files):
            if f.endswith(".uasset"):
                full = os.path.join(root, f)
                rel = os.path.relpath(full, orig_root).replace("\\", "/")
                yield rel, full


def load_recipe():
    with open(RECIPE_PATH, encoding="utf-8") as f:
        return json.load(f)


def rules_for_asset(recipe, rel_content_path):
    """Правила, применимые к ассету (сопоставление по 'asset_glob')."""
    out = []
    for rule in recipe["rules"]:
        if re.fullmatch(rule["asset_glob"], rel_content_path):
            out.append(rule)
    return out


def rule_matches_node(rule, node, path):
    """Применимо ли правило к данному узлу JSON."""
    if rule.get("exclude") and re.search(rule["exclude"], node["Name"]):
        return False
    if not re.search(rule["property"], node["Name"]):
        return False
    ctx = rule.get("context")
    if ctx and not re.search(ctx, path_str(path)):
        return False
    val = node.get("Value")
    if not isinstance(val, (int, float)) or isinstance(val, bool):
        return False
    cond = rule.get("if_value")
    if cond == ">0" and val <= 0:
        return False
    if cond == ">=1" and val < 1:
        return False
    rmin, rmax = rule.get("range", (-1e12, 1e12))
    if not (rmin <= val <= rmax):
        return False
    return True


def apply_rule_to_value(rule, old):
    """Вычисляет новое значение по правилу. Возвращает (new, was_changed)."""
    action = rule["action"]
    if action == "scale":
        new = old * rule["value"]
    elif action == "set":
        new = rule["value"]
    else:
        raise ValueError("неизвестное действие: " + action)
    lo, hi = rule.get("clamp", (-1e12, 1e12))
    new = min(max(new, lo), hi)
    if isinstance(old, int) and not isinstance(old, bool):
        new = int(round(new))
    else:
        new = float(new)
    changed = not (isinstance(new, float)
                   and math.isclose(new, old, rel_tol=1e-9, abs_tol=1e-9))
    return new, changed


def collect_patched_files(recipe):
    return list(recipe.get("patch_targets", PATCH_TARGETS))


# ---------------------------------------------------------------------------
# scan: отчёт по параметрам
# ---------------------------------------------------------------------------

def scan_targets(recipe):
    """Ассеты для отчёта: цели правок + scan_targets из рецепта."""
    return collect_patched_files(recipe) + list(recipe.get("scan_targets", []))


def cmd_scan(args, cfg):
    recipe = load_recipe()
    orig_root = os.path.join(cfg["work_dir"], DIR_ORIG, "Tropico6", "Content")
    if not os.path.isdir(orig_root):
        die("Сначала выполните: python hardball.py extract")
    json_dir = os.path.join(cfg["work_dir"], DIR_JSON)
    os.makedirs(json_dir, exist_ok=True)
    report_lines = []
    count_files = 0
    for target in scan_targets(recipe):
        for rel, uasset in iter_asset_files(orig_root, target):
            jname = rel.replace("/", "__").replace(".uasset", ".json")
            jpath = os.path.join(json_dir, jname)
            if not os.path.isfile(jpath):
                to_json(cfg, uasset, jpath)
            count_files += 1
            with open(jpath, encoding="utf-8") as f:
                data = json.load(f)
            for node, path in iter_nodes(data.get("Exports", [])):
                val = node.get("Value")
                if isinstance(val, (int, float)) and not isinstance(val, bool):
                    report_lines.append("%s :: %s = %s" % (rel, path_str(path), val))
    report = os.path.join(cfg["work_dir"], DIR_REPORTS, "politics_scan.txt")
    with open(report, "w", encoding="utf-8") as f:
        f.write("\n".join(report_lines))
    msg("Просмотрено ассетов: %d" % count_files)
    msg("Числовых параметров: %d" % len(report_lines))
    msg("Полный отчёт: " + report)


# ---------------------------------------------------------------------------
# patch: применение рецепта
# ---------------------------------------------------------------------------

def prepare_mod_copy(cfg, rel, orig_root):
    """Копирует .uasset+.uexp оригинала в modfiles с сохранением путей.
    Возвращает путь к .uasset в modfiles."""
    mod_root = os.path.join(cfg["work_dir"], DIR_MOD, "Tropico6", "Content")
    dst_uasset = os.path.join(mod_root, *rel.split("/"))
    os.makedirs(os.path.dirname(dst_uasset), exist_ok=True)
    src_uasset = os.path.join(orig_root, *rel.split("/"))
    shutil.copy2(src_uasset, dst_uasset)
    src_uexp = src_uasset[:-7] + ".uexp"
    if os.path.isfile(src_uexp):
        shutil.copy2(src_uexp, dst_uasset[:-7] + ".uexp")
    return dst_uasset


def verify_roundtrip(cfg, mod_uasset, expected_changes):
    """Проверяет, что значения записались в .uasset/.uexp.
    Возвращает список НЕ записанных изменений."""
    tmp_json = mod_uasset[:-7] + ".verify.json"
    to_json(cfg, mod_uasset, tmp_json)
    with open(tmp_json, encoding="utf-8") as f:
        data = json.load(f)
    actual = {}
    for node, path in iter_nodes(data.get("Exports", [])):
        val = node.get("Value")
        if isinstance(val, (int, float)) and not isinstance(val, bool):
            actual.setdefault(path_str(path), val)
    missing = []
    for ch in expected_changes:
        got = actual.get(ch["path"])
        if got is None or not math.isclose(float(got), float(ch["new"]),
                                           rel_tol=1e-4, abs_tol=1e-6):
            missing.append(ch)
    try:
        os.remove(tmp_json)
    except OSError:
        pass
    return missing


def hexpatch_value(cfg, mod_uasset, change):
    """Бинарное исправление значения, которое UAssetGUI не записал в .uexp
    (известная проблема FloatProperty/ByteProperty). Ищет старые байты,
    перебирает совпадения, после каждого проверяет результат через tojson."""
    uexp = mod_uasset[:-7] + ".uexp"
    if not os.path.isfile(uexp):
        return False
    old, new = float(change["old"]), float(change["new"])
    if isinstance(change["old"], int) and not isinstance(change["old"], bool):
        old_b = struct.pack("<i", int(old))
        new_b = struct.pack("<i", int(new))
    else:
        old_b = struct.pack("<f", old)
        new_b = struct.pack("<f", new)
    data = bytearray(open(uexp, "rb").read())
    positions = []
    start = 0
    while True:
        pos = data.find(old_b, start)
        if pos < 0:
            break
        positions.append(pos)
        start = pos + 1
    if not positions:
        return False
    backup = bytes(data)
    for pos in positions:
        data[pos:pos + len(new_b)] = new_b
        open(uexp, "wb").write(bytes(data))
        if verify_roundtrip(cfg, mod_uasset, [change]):
            # проверка всё ещё находит незаписанное значение — пробуем следующее совпадение
            data = bytearray(backup)
            continue
        return True
    open(uexp, "wb").write(backup)
    return False


def cmd_patch(args, cfg):
    recipe = load_recipe()
    orig_root = os.path.join(cfg["work_dir"], DIR_ORIG, "Tropico6", "Content")
    if not os.path.isdir(orig_root):
        die("Сначала выполните: python hardball.py extract")
    json_dir = os.path.join(cfg["work_dir"], DIR_JSON)
    os.makedirs(json_dir, exist_ok=True)
    os.makedirs(os.path.join(cfg["work_dir"], DIR_REPORTS), exist_ok=True)

    log = []
    touched_assets = set()
    for target in collect_patched_files(recipe):
        for rel, orig_uasset in iter_asset_files(orig_root, target):
            rules = rules_for_asset(recipe, rel)
            if not rules:
                continue
            jname = rel.replace("/", "__").replace(".uasset", ".json")
            jpath = os.path.join(json_dir, jname)
            if not os.path.isfile(jpath):
                to_json(cfg, orig_uasset, jpath)
            with open(jpath, encoding="utf-8") as f:
                data = json.load(f)

            changes = []
            for node, path in iter_nodes(data.get("Exports", [])):
                for rule in rules:
                    if not rule_matches_node(rule, node, path):
                        continue
                    new, changed = apply_rule_to_value(rule, node["Value"])
                    if not changed:
                        continue
                    entry = {
                        "rule": rule["id"],
                        "desc": rule["desc"],
                        "asset": rel,
                        "path": path_str(path),
                        "old": node["Value"],
                        "new": new,
                    }
                    changes.append(entry)
                    node["Value"] = new
                    log.append(entry)
                    break
            if not changes:
                continue

            # сохранить JSON и собрать модовую копию ассета
            with open(jpath, "w", encoding="utf-8") as f:
                json.dump(data, f, indent=2, ensure_ascii=False)
            mod_uasset = prepare_mod_copy(cfg, rel, orig_root)
            from_json(cfg, jpath, mod_uasset)

            # проверка записи + бинарное исправление при необходимости
            missing = verify_roundtrip(cfg, mod_uasset, changes)
            for ch in missing:
                if hexpatch_value(cfg, mod_uasset, ch):
                    msg("  [bin] %s: %s = %s (бинарная правка)" %
                        (rel, ch["path"], ch["new"]))
                else:
                    warn("Значение не удалось записать: %s :: %s (%s -> %s)" %
                         (rel, ch["path"], ch["old"], ch["new"]))
                    ch["failed"] = True
            touched_assets.add(rel)

    log_path = os.path.join(cfg["work_dir"], DIR_REPORTS, "patch_log.json")
    with open(log_path, "w", encoding="utf-8") as f:
        json.dump(log, f, indent=2, ensure_ascii=False)

    ok = sum(1 for e in log if not e.get("failed"))
    msg("")
    msg("Изменено значений: %d из %d" % (ok, len(log)))
    msg("Изменено ассетов: %d" % len(touched_assets))
    if touched_assets:
        msg("Ассеты:")
        for rel in sorted(touched_assets):
            msg("  - " + rel)
    msg("Журнал правок: " + log_path)
    if not log:
        warn("Ни одно правило не сработало. Запустите python hardball.py scan "
             "и проверьте отчёт: возможно, структура ассетов вашей версии игры "
             "отличается.")
        return
    msg("Следующий шаг: python hardball.py package")


# ---------------------------------------------------------------------------
# package / install / uninstall / verify / status / doctor
# ---------------------------------------------------------------------------

def cmd_package(args, cfg):
    mod_root = os.path.join(cfg["work_dir"], DIR_MOD, "Tropico6")
    has_uasset = False
    for _r, _d, fs in os.walk(mod_root):
        if any(f.endswith(".uasset") for f in fs):
            has_uasset = True
            break
    if not has_uasset:
        die("Нет исправленных файлов. Сначала выполните: python hardball.py patch")
    pack_exe = cfg["unrealpak_pack_exe"]
    if not os.path.isfile(pack_exe):
        die("UnrealPak (упаковщик) не найден: %s. Выполните: "
            "python hardball.py setup" % pack_exe)
    out_dir = os.path.join(cfg["work_dir"], DIR_OUT)
    os.makedirs(out_dir, exist_ok=True)
    pak_path = os.path.join(out_dir, cfg["mod_pak_name"])
    if os.path.isfile(pak_path):
        os.remove(pak_path)

    # Файл-ответ для UnrealPak (только абсолютные пути!)
    resp = os.path.join(cfg["work_dir"], "_pak_response.txt")
    with open(resp, "w", encoding="utf-8") as f:
        f.write('"%s\\*" "../../../Tropico6/Content/"' % mod_root)
    run_cmd([pack_exe, pak_path, "-Create=" + resp, "-compress"], "упаковка мода")

    if not os.path.isfile(pak_path) or os.path.getsize(pak_path) < 500:
        die("Не удалось собрать .pak (файл отсутствует или слишком мал).")
    listing = run_cmd([pack_exe, pak_path, "-List"], "проверка содержимого .pak")
    n_files = listing.count(".uasset")
    msg("")
    msg("Собран мод: %s" % pak_path)
    msg("Размер: %.1f КБ, .uasset внутри: %d" %
        (os.path.getsize(pak_path) / 1024.0, n_files))
    if n_files == 0:
        die("В .pak не попали ассеты — проверьте work/modfiles.")
    msg("Следующий шаг: python hardball.py install")


def cmd_install(args, cfg):
    pak_src = os.path.join(cfg["work_dir"], DIR_OUT, cfg["mod_pak_name"])
    if not os.path.isfile(pak_src):
        die("Сначала соберите мод: python hardball.py package")
    d = paks_dir(cfg)
    if not d:
        die('Не найдена папка Paks игры. Выполните: python hardball.py set-game "путь"')
    dst = os.path.join(d, cfg["mod_pak_name"])
    shutil.copy2(pak_src, dst)
    msg("Мод установлен: " + dst)
    msg("")
    msg("Запустите Tropico 6. Мод загружается автоматически при старте игры.")
    msg("Отключить: python hardball.py uninstall")


def cmd_uninstall(args, cfg):
    d = paks_dir(cfg)
    if d:
        dst = os.path.join(d, cfg["mod_pak_name"])
        if os.path.isfile(dst):
            os.remove(dst)
            msg("Мод удалён: " + dst)
            msg("Игра полностью вернулась к стандартному поведению "
                "(оригинальные файлы не изменялись).")
        else:
            msg("Мод в игре не найден (уже удалён).")
    else:
        warn("Не найдена папка Paks игры. Удалите вручную: "
             "<игра>\\Tropico6\\Content\\Paks\\%s" % cfg["mod_pak_name"])


def cmd_verify(args, cfg):
    """Проверка собранного .pak: сверяем содержимое с журналом правок."""
    pak_path = os.path.join(cfg["work_dir"], DIR_OUT, cfg["mod_pak_name"])
    if not os.path.isfile(pak_path):
        die("Сначала соберите мод: python hardball.py package")
    log_path = os.path.join(cfg["work_dir"], DIR_REPORTS, "patch_log.json")
    if not os.path.isfile(log_path):
        die("Не найден журнал правок. Выполните: python hardball.py patch")
    with open(log_path, encoding="utf-8") as f:
        log = json.load(f)
    failed = [e for e in log if e.get("failed")]
    if failed:
        for e in failed:
            warn("не записано: %s :: %s" % (e["asset"], e["path"]))
        die("В журнале есть незаписанные значения — пересоберите мод "
            "после исправления.")
    msg("Журнал: %d правок, все значения подтверждены ранее." % len(log))
    msg("Проверка содержимого .pak…")
    listing = run_cmd([cfg["unrealpak_pack_exe"], pak_path, "-List"],
                      "чтение содержимого .pak")
    expected = sorted({e["asset"] for e in log})
    missing = [rel for rel in expected if rel not in listing]
    if missing:
        for rel in missing:
            warn("в .pak нет файла: " + rel)
        die("Проверка не пройдена.")
    msg("[ok] Все %d изменённых ассетов присутствуют в .pak." % len(expected))
    msg("Проверка пройдена. Устанавливайте: python hardball.py install")


def cmd_status(args, cfg):
    work = cfg["work_dir"]
    msg(MOD_TITLE)
    msg("")
    game = find_game_root(cfg)
    msg("Игра:            %s" % (game or "не найдена (python hardball.py set-game)"))
    msg("Рабочая папка:   %s" % work)
    for label, key in (
        ("UAssetGUI", "uassetgui_exe"),
        ("UnrealPak 4.25.3", "unrealpak_extract_exe"),
        ("UnrealPak 4.20", "unrealpak_pack_exe"),
    ):
        state = "[ok] " if os.path.isfile(cfg[key]) else "[--] "
        msg("%s%s %s" % (state, label, cfg[key]))
    for sub, label in ((DIR_ORIG, "извлечённые оригиналы"),
                       (DIR_MOD, "исправленные файлы"),
                       (DIR_OUT, "готовые .pak")):
        d = os.path.join(work, sub)
        n = sum(len(fs) for _r, _dd, fs in os.walk(d)) if os.path.isdir(d) else 0
        msg("%s %-24s файлов: %d" % ("[ok]" if n else "[--]", label, n))
    installed = os.path.join(paks_dir(cfg), cfg["mod_pak_name"]) if paks_dir(cfg) else ""
    msg("В игре установлен: %s" %
        ("да" if installed and os.path.isfile(installed) else "нет"))


def cmd_doctor(args, cfg):
    ok = True
    msg("Проверка окружения для сборки мода Hardball Politics")
    msg("")
    root = find_game_root(cfg)
    if root:
        msg("[ok] Tropico 6 найдена: " + root)
    else:
        ok = False
        warn('Tropico 6 не найдена. Укажите путь: python hardball.py set-game "..."')
    for key, spec in TOOL_DOWNLOADS.items():
        if os.path.isfile(cfg[key]) and os.path.getsize(cfg[key]) > 100_000:
            msg("[ok] %s" % spec["label"])
        else:
            ok = False
            warn("не хватает инструмента: %s (%s). Выполните: python hardball.py setup"
                 % (spec["label"], cfg[key]))
    if sys.platform.startswith("win"):
        msg("[ok] запуск на Windows")
    else:
        warn("скрипт выполняется не на Windows: UAssetGUI и UnrealPak — "
             "Windows-приложения, финальная сборка должна выполняться на Windows.")
        ok = False
    msg("")
    msg("Результат: %s" % ("готово к работе" if ok else "требуется настройка"))


def main():
    parser = argparse.ArgumentParser(
        description="Hardball Politics — сборка и установка мода для Tropico 6")
    sub = parser.add_subparsers(dest="command")
    sub.add_parser("setup", help="подготовить папки и скачать инструменты")
    p_set = sub.add_parser("set-game", help="указать путь к игре")
    p_set.add_argument("path", help="корневая папка игры")
    sub.add_parser("extract", help="извлечь политические ассеты из игры")
    sub.add_parser("scan", help="отчёт по всем политическим параметрам")
    sub.add_parser("patch", help="применить рецепт правок")
    sub.add_parser("package", help="собрать z_HardballPolitics.pak")
    sub.add_parser("verify", help="проверить собранный мод")
    sub.add_parser("install", help="установить мод в игру")
    sub.add_parser("uninstall", help="удалить мод (восстановить оригинал)")
    sub.add_parser("status", help="текущее состояние")
    sub.add_parser("doctor", help="проверить окружение")
    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return
    cfg = load_config()
    cmds = {
        "setup": cmd_setup,
        "set-game": cmd_set_game,
        "extract": cmd_extract,
        "scan": cmd_scan,
        "patch": cmd_patch,
        "package": cmd_package,
        "verify": cmd_verify,
        "install": cmd_install,
        "uninstall": cmd_uninstall,
        "status": cmd_status,
        "doctor": cmd_doctor,
    }
    cmds[args.command](args, cfg)


if __name__ == "__main__":
    main()
