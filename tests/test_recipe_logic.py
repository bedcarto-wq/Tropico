#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Автономные тесты движка рецепта Hardball Politics.

Запуск: python tests/test_recipe_logic.py
Тесты не требуют ни игры, ни Windows-инструментов: движок правил проверяется
на синтетических JSON-структурах формата UAssetGUI, построенных на РЕАЛЬНЫХ
именах параметров, подтверждённых в ассетах Tropico 6
(BP_T6SingletonData, BP_Faction_*, ультиматумы фракций).
"""

import json
import math
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import hardball  # noqa: E402


def node(name, value):
    return {"Name": name, "Value": value}


def singleton_json():
    """Синтетический UAssetGUI-JSON BP_T6SingletonData с реальными именами."""
    return {
        "Exports": [
            {"Name": "BP_T6SingletonData_C",
             "Data": [
                 node("Politics", [
                     node("ElectionsPeriodicity", 120),
                     node("ElectionSpeech", [
                         node("PromiseSupportBonus", 15.0),
                         node("PromiseNeededHappiness", 5.0),
                         node("PraiseStandingBonus", 20.0),
                         node("VoterSwayBonus", 25.0),
                         node("SpeechDurationSeconds", 30.0),
                     ]),
                     node("ElectionSpeechPromiseNeededHappiness",
                          [node("RangeMin", 1.0), node("RangeMax", 5.0)]),
                     node("StandingModiferFleetingPraise", 10.0),
                     node("DualDemandTriggerChance", 40.0),
                     node("UltimatumTimeLimitInMonths", 12),
                     node("MonthsTillRejectingNotTouchedOfferedDemands", 24),
                     node("DegradationMonthsToMaxOutTreshhold", 12),
                     node("MonthlyRebelPointsPerRebel", 0.5),
                     node("MonthlyRebelPointsPerGuerrilla", 2.0),
                     node("ProtestHappinessThreshold", 20.0),
                     node("StandingGainMultiplier", 1.0),
                     node("StandingLossMulitplier", 1.0),
                     node("NeededRebelPointsForRebelAction", 100),
                     node("ElectionsPeriodicityExtra", 120),
                 ]),
             ]},
        ]
    }


def ultimatum_json():
    return {
        "Exports": [
            {"Name": "BP_T6FactionUltimatumCapitalists_C",
             "Data": [
                 node("FactionUltimatumData", [
                     node("CoolDownMonths", 12),
                     node("StandingLoss", 20.0),
                     node("UltimatumText", "text"),
                 ]),
             ]},
        ]
    }


def apply_all(recipe, data, rel):
    rules = hardball.rules_for_asset(recipe, rel)
    changes = []
    for node_obj, path in hardball.iter_nodes(data.get("Exports", [])):
        for rule in rules:
            if not hardball.rule_matches_node(rule, node_obj, path):
                continue
            new, changed = hardball.apply_rule_to_value(rule, node_obj["Value"])
            if changed:
                changes.append((rule["id"], hardball.path_str(path),
                                node_obj["Value"], new))
                node_obj["Value"] = new
            break
    return changes


def test_recipe_is_valid():
    recipe = hardball.load_recipe()
    assert recipe["mod"]["id"] == "HardballPolitics"
    for rule in recipe["rules"]:
        assert rule["action"] in ("scale", "set"), rule["id"]
        assert isinstance(rule["value"], (int, float)), rule["id"]
        assert rule["desc"], rule["id"]
        # проверка компилируемости регулярных выражений
        import re
        re.compile(rule["property"])
        re.fullmatch(rule["asset_glob"], "x")
        if rule.get("context"):
            re.compile(rule["context"])
    print("[ok] рецепт корректен: %d правил" % len(recipe["rules"]))


def test_speech_praise_nerf():
    recipe = hardball.load_recipe()
    data = singleton_json()
    changes = apply_all(recipe, data, "Blueprints/GameData/BP_T6SingletonData.uasset")
    by_rule = {}
    for rid, path, old, new in changes:
        by_rule.setdefault(rid, []).append((path, old, new))

    # Прямой бонус восхваления: 10 -> 3 (30%)
    (path, old, new), = by_rule["speech_praise_support"]
    assert "StandingModiferFleetingPraise" in path
    assert math.isclose(old, 10.0) and math.isclose(new, 3.0), (old, new)

    # Бонус поддержки внутри ElectionSpeech: 20 -> 6
    sup = [(p, o, n) for p, o, n in by_rule["speech_struct_support"]]
    assert all("ElectionSpeech" in p for p, o, n in sup)

    # Обещания: 15 -> 4.2 (28%)
    prom = [(p, o, n) for p, o, n in by_rule["speech_struct_promise"]]
    assert prom, "правило обещаний не сработало"
    assert math.isclose(prom[0][2], 4.2, abs_tol=1e-6)

    # Duration внутри ElectionSpeech НЕ трогаем (не support/praise/promise)
    for rid, path, old, new in changes:
        assert not path.endswith("SpeechDurationSeconds"), \
            "нельзя менять длительность речи"
    print("[ok] речь: бонусы поддержки/восхваления/обещаний урезаны, "
          "сторонние поля не тронуты")


def test_demands_and_escalation():
    recipe = hardball.load_recipe()
    data = singleton_json()
    changes = apply_all(recipe, data, "Blueprints/GameData/BP_T6SingletonData.uasset")
    vals = {}
    for rid, path, old, new in changes:
        vals.setdefault(rid, []).append((old, new))
    assert vals["dual_demand_frequency"][0] == (40.0, 50.0)
    assert vals["ultimatum_deadline"][0] == (12, 10)
    assert vals["offer_expiry"][0] == (24, 19)  # 24*0.8=19.2 -> int 19
    assert vals["degradation_speed"][0] == (12, 8)  # 12*0.7=8.4 -> 8
    assert math.isclose(vals["rebel_points_rebel"][0][1], 0.625, abs_tol=1e-9)
    assert math.isclose(vals["rebel_points_guerrilla"][0][1], 2.5, abs_tol=1e-9)
    assert math.isclose(vals["protest_threshold"][0][1], 22.0, abs_tol=1e-9)
    assert math.isclose(vals["standing_gain_mult"][0][1], 1.2, abs_tol=1e-9)
    assert math.isclose(vals["standing_loss_mult"][0][1], 1.2, abs_tol=1e-9)
    # Порог восстаний и периодичность выборов НЕ меняются
    for rid, path, old, new in changes:
        assert "NeededRebelPointsForRebelAction" not in path
        assert "ElectionsPeriodicity" not in path
    print("[ok] требования/эскалация: частота +25%, сроки -20%, "
          "пороги восстаний и выборов сохранены")


def test_ultimatum_cooldown():
    recipe = hardball.load_recipe()
    data = ultimatum_json()
    changes = apply_all(recipe, data,
                        "Blueprints/Ultimatums/Factions/BP_T6FactionUltimatumCapitalists.uasset")
    (rid, path, old, new), = changes
    assert rid == "ultimatum_cooldown"
    assert old == 12 and new == 10
    # StandingLoss (последствия) и текст ультиматума не тронуты
    print("[ok] ультиматумы: перезарядка -20%, последствия и тексты не тронуты")


def test_superpower_demands_untouched():
    recipe = hardball.load_recipe()
    data = ultimatum_json()
    changes = apply_all(recipe, data,
                        "Blueprints/Demands/Superpowers/USA/BP_T6_SuperpowerDemand_USA_1.uasset")
    assert changes == [], "требования супердержав менять запрещено"
    print("[ok] требования супердержав не затрагиваются")


def test_range_guard():
    """Защитный диапазон: если значение вне range, правило не применяется."""
    recipe = hardball.load_recipe()
    data = singleton_json()
    # подменяем значение на заведомо вне диапазона
    for node_obj, _path in hardball.iter_nodes(data["Exports"]):
        if node_obj["Name"] == "DualDemandTriggerChance":
            node_obj["Value"] = 99999.0
    changes = apply_all(recipe, data, "Blueprints/GameData/BP_T6SingletonData.uasset")
    assert all(c[0] != "dual_demand_frequency" for c in changes)
    print("[ok] защита от неожиданных значений работает")


def test_hexpatch():
    """Бинарное исправление float в .uexp (эмуляция бага UAssetGUI)."""
    with tempfile.TemporaryDirectory() as td:
        uasset = os.path.join(td, "test.uasset")
        uexp = os.path.join(td, "test.uexp")
        # .uexp: два float-значения, патчим первое
        payload = struct.pack("<f", 10.0) + b"\x00" * 8 + struct.pack("<f", 1.5)
        open(uexp, "wb").write(payload)
        open(uasset, "wb").write(b"\x00")

        calls = []

        class FakeCfg(dict):
            pass

        # Подменяем UAssetGUI: tojson возвращает текущее значение из uexp
        def fake_to_json(cfg, uasset_path, json_path):
            v = struct.unpack_from("<f", open(uexp, "rb").read(), 0)[0]
            data = {"Exports": [{"Data": [node("X", v)]}]}
            with open(json_path, "w") as f:
                json.dump(data, f)
            calls.append(v)

        orig_to_json = hardball.to_json
        orig_uag = hardball.uag
        hardball.to_json = fake_to_json
        hardball.uag = lambda cfg: "unused"
        try:
            change = {"path": "X", "old": 10.0, "new": 3.0}
            ok = hardball.hexpatch_value(FakeCfg(), uasset, change)
            assert ok, "hexpatch не сработал"
            final = struct.unpack_from("<f", open(uexp, "rb").read(), 0)[0]
            assert math.isclose(final, 3.0, abs_tol=1e-6)
            # второе значение не тронуто
            second = struct.unpack_from("<f", open(uexp, "rb").read(), 12)[0]
            assert math.isclose(second, 1.5, abs_tol=1e-9)
        finally:
            hardball.to_json = orig_to_json
            hardball.uag = orig_uag
    print("[ok] бинарное исправление значений (hexpatch) работает корректно")


def test_content_subpath():
    assert hardball.content_subpath(r"D:\x\Tropico6\Content\Blueprints\A.uasset") == \
        "Blueprints/A.uasset"
    assert hardball.content_subpath(r"D:\x\Other\A.uasset") is None
    print("[ok] вычисление путей относительно Content корректно")


def main():
    test_recipe_is_valid()
    test_speech_praise_nerf()
    test_demands_and_escalation()
    test_ultimatum_cooldown()
    test_superpower_demands_untouched()
    test_range_guard()
    test_hexpatch()
    test_content_subpath()
    print("")
    print("ВСЕ ТЕСТЫ ПРОЙДЕНЫ")


if __name__ == "__main__":
    main()
