# Карта политических ассетов Tropico 6 (подтверждённые данные)

Все пути и имена ниже извлечены из реальных ассетов игры (анализ исходников публичного мода-образца, созданного Mod Kit, и разбор бинарных таблиц имён UE4). Это не догадки — каждое имя существует в ассетах.

## Ассеты, которые изменяет мод

### `Blueprints/GameData/BP_T6SingletonData.uasset` — глобальные данные игры
Класс `T6DataSingleton`. Содержит (среди прочего):

**Выборы и речь:**
- `ElectionSpeech` — структура параметров предвыборной речи
- `ElectionSpeechPromiseNeededHappiness` — критерий выполнения обещания
- `ElectionsPeriodicity`, `MonthsNoticePriorToElections`, `MonthsNoticeToCheatElections`
- `ThresholdLowSupport`, `LowMandateWarning`

**Требования и поддержка фракций:**
- `DemandSlotsFaction`, `DemandSlotsSuperpower`, `DualDemandTriggerChance`, `DualDemandSetting`
- `StandingGain`, `StandingGainBySpitterStar`, `StandingGainMultiplier`
- `StandingLoss`, `StandingLossPool`, `StandingLossMulitplier` (опечатка — имя такое в игре)
- `StandingModiferFleetingPraise` — бонус от восхваления фракции
- `UltimatumTimeLimitInMonths`, `MonthsTillRejectingNotTouchedOfferedDemands`
- `ConstitutionOptionsModifiers` (модификаторы конституции)

**Недовольство, протесты, восстания:**
- `DegradationMonthsToMaxOutTreshhold`, `ProtestHappinessThreshold`
- `MonthlyRebelPointsPerRebel`, `MonthlyRebelPointsPerGuerrilla`
- `NeededRebelPointsForRebelAction`, `RelativeSoldierRebelTreshold`
- `PacifistStateRebelPointsModifierPercent`, `OpenBallotsRebelConvertChanceModifier`
- `RebelAttackSquadParams(+/Modern)`, `RebelUprisingSquadParams(+/Modern)` — мод НЕ трогает (боевые параметры)
- `MilitaryCoupSquadParams`, `MilitiaParams` — мод НЕ трогает
- ссылки на `Military/DA_T6GuerillaRebelAttack(Uprising)(Modern)` — данные атак/восстаний

**Сложность:**
- `PoliticsAndDiplomacyDifficultyData`, `OppositionDifficultyData`, `CaribbeanHappinessDifficultyData`

### `Blueprints/Ultimatums/Factions/BP_T6FactionUltimatum*.uasset` — ультиматумы фракций
Подтверждённое поле `CoolDownMonths` (период перезарядки между ультиматумами) — подтверждено также на форуме TropicoModding.org.

### `Blueprints/Demands/Factions/…` — требования фракций
Дерево требований по фракциям (CAP/COM/CON/ENV/IND/INT/MIL/REL/REV), включая `DualDemands` — парные требования двух фракций.

## Ассеты, которые мод только сканирует (scan)

- `Blueprints/Escalations/BP_T6Escalation*` — поэтапная эскалация недовольства фракций (стандартные ступени 5.6 ТЗ)
- `Blueprints/Politics/Factions/BP_Faction_*` — фракции: `BaseStanding`, `FactionUltimatumData`, `Escalation`, портреты и тексты
- `Blueprints/Military/DA_T6GuerillaRebel*` — сценарии нападений и восстаний

## Что категорически не трогается (границы ТЗ)

- `Blueprints/Politics/Superpowers/*`, `Demands/Superpowers/*` — супердержавы и их требования
- `Quest/Win_Loose_Condition/Popups/LoosePopus/BP_Loose_FailedElection` — стандартный Game Over
- боевые параметры армий, экономика, торговля

## Техническая база конвейера

- Tropico 6 — Unreal Engine 4 (ассеты текущих сборок сериализуются движком уровня UE 4.26; `FileVersionUE4 = 522`, проверено бинарным разбором).
- Игра читает модовые `.pak` поверх оригинала из `Tropico6/Content/Paks` (имя с префиксом `z_` — загружается позже оригинала и переопределяет его).
- Извлечение: UnrealPak 4.25.3+ (актуальные сборки игры используют новый формат pak, старые 4.20-инструменты не читают оригиналы, но именно 4.20-упаковщик создаёт pak, корректно читаемый игрой).
- Конвертация ассетов: UAssetGUI atenfyr (engine version 26), CLI: `UAssetGUI.exe tojson <in> <out> 26` / `fromjson <in> <out>`.
- Известная проблема UAssetGUI: FloatProperty/ByteProperty могут не записываться fromjson — утилита мода автоматически проверяет каждую правку обратной конвертацией и при необходимости исправляет байты напрямую (hexpatch), как это делает проверенный сообществом конвейер модов.

## Источники

- Официальные примеры Mod Kit: https://github.com/imi0/Tropico6ModSamples
- Вики моддинга: https://tropico.fandom.com/wiki/Tropico_6_-_Modding («Override (replace) any asset that is in the game, including balancing values»)
- Гайд сообщества по UAsset-редакторам: tapatalk TropicoModding.org, тема t593 (поля Ultimatum CoolDownMonths, SuperpowerActionStandingLimit)
- Исходники публичного мода-образца «Hardcore mode» (mod.io, id 3486669) — структура Override/ и реальные имена параметров
- UAssetGUI: https://github.com/atenfyr/UAssetGUI
