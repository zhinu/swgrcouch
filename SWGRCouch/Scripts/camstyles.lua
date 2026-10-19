-- SWGRCouch · camstyles.lua (couch-fix29): the campaign's racer styles per rank, static data (pure, no game call).
-- Source: the decoded CAM_Style_<Key>_Lv<N> RacerStyle assets (work/decoded-campaign/.../Campaign/Loadouts/
-- RacerStyles/, CL381121), copied verbatim: StandardAbilities (the style's starter abilities, perkdata ABILITIES ids),
-- Traits (every trait the native run applies with AddPassive on the racer's PlayerState: research perks-loadout.md
-- §1.3 #6 - the description-only TRT_StartWith* included, exactly as the run applies them to P1) and UnlocksRequired
-- (rank 1 = Unlock.Cam.Style.<Key>, 2 = .UpgradeA, 3 = .UpgradeB). The keys are couchprerun.styleKeyOf's (CAM_Style_
-- <Key>_Lv<N> -> <Key>, = perkdata STYLES keys). Never a soft pointer read: every path is a static string.
-- Users: couchrun (a guest's starter build = his style's StandardAbilities, his traits in every campaign race).
local M = {}

M.STYLES = {
  Abilities = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Abilities_Lv1.CAM_Style_Abilities_Lv1", unlock = "Unlock.Cam.Style.Abilities",
      abilities = { "Mine", "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithMine.TRT_StartWithMine", "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Abilities_Lv2.CAM_Style_Abilities_Lv2", unlock = "Unlock.Cam.Style.Abilities.UpgradeA",
      abilities = { "Mine", "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithMine.TRT_StartWithMine", "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair", "/Game/Griffin/Gameplay/Passives/TRT_NoEnergyGainOverchargeImproved.TRT_NoEnergyGainOverchargeImproved" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Abilities_Lv3.CAM_Style_Abilities_Lv3", unlock = "Unlock.Cam.Style.Abilities.UpgradeB",
      abilities = { "Mine", "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithMine.TRT_StartWithMine", "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair", "/Game/Griffin/Gameplay/Passives/TRT_NoEnergyGainOverchargeImproved.TRT_NoEnergyGainOverchargeImproved", "/Game/Griffin/Gameplay/Passives/TRT_AbilitiesReduceAbilityCooldowns.TRT_AbilitiesReduceAbilityCooldowns" } },
  },
  Afterburner = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Afterburner_Lv1.CAM_Style_Afterburner_Lv1", unlock = "Unlock.Cam.Style.Afterburner",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterburner.TRT_StrongerAfterburner", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerLastsLonger.TRT_AfterburnerLastsLonger" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Afterburner_Lv2.CAM_Style_Afterburner_Lv2", unlock = "Unlock.Cam.Style.Afterburner.UpgradeA",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterburner.TRT_StrongerAfterburner", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerLastsLonger.TRT_AfterburnerLastsLonger", "/Game/Griffin/Gameplay/Passives/TRT_RefillAfterburnerOnOvertake.TRT_RefillAfterburnerOnOvertake" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Afterburner_Lv3.CAM_Style_Afterburner_Lv3", unlock = "Unlock.Cam.Style.Afterburner.UpgradeB",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterburner.TRT_StrongerAfterburner", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerLastsLonger.TRT_AfterburnerLastsLonger", "/Game/Griffin/Gameplay/Passives/TRT_RefillAfterburnerOnOvertake.TRT_RefillAfterburnerOnOvertake", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerRefillOnAirtimeAndAdvancedCorner.TRT_AfterburnerRefillOnAirtimeAndAdvancedCorner" } },
  },
  Airborne = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Airborne_Lv1.CAM_Style_Airborne_Lv1", unlock = "Unlock.Cam.Style.Airborne",
      abilities = { "Shockwave_Punch" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVectoredShockwave.TRT_StartWithVectoredShockwave", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerRefillOnPerfectLanding.TRT_AfterburnerRefillOnPerfectLanding" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Airborne_Lv2.CAM_Style_Airborne_Lv2", unlock = "Unlock.Cam.Style.Airborne.UpgradeA",
      abilities = { "Shockwave_Punch" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVectoredShockwave.TRT_StartWithVectoredShockwave", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerRefillOnPerfectLanding.TRT_AfterburnerRefillOnPerfectLanding", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerPowerStacksWhenAirborne.TRT_AfterburnerPowerStacksWhenAirborne" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Airborne_Lv3.CAM_Style_Airborne_Lv3", unlock = "Unlock.Cam.Style.Airborne.UpgradeB",
      abilities = { "Shockwave_Punch" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVectoredShockwave.TRT_StartWithVectoredShockwave", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerRefillOnPerfectLanding.TRT_AfterburnerRefillOnPerfectLanding", "/Game/Griffin/Gameplay/Passives/TRT_AfterburnerPowerStacksWhenAirborne.TRT_AfterburnerPowerStacksWhenAirborne", "/Game/Griffin/Gameplay/Passives/TRT_AllLandingsArePerfect.TRT_AllLandingsArePerfect" } },
  },
  Antagonist = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Antagonist_Lv1.CAM_Style_Antagonist_Lv1", unlock = "Unlock.Cam.Style.Antagonist",
      abilities = { "Disruptor" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForAbilityHits.TRT_EnergyForAbilityHits" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Antagonist_Lv2.CAM_Style_Antagonist_Lv2", unlock = "Unlock.Cam.Style.Antagonist.UpgradeA",
      abilities = { "Disruptor", "Shockwave", "Mine" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForAbilityHits.TRT_EnergyForAbilityHits", "/Game/Griffin/Gameplay/Passives/TRT_StartWithAbilities.TRT_StartWithAbilities" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Antagonist_Lv3.CAM_Style_Antagonist_Lv3", unlock = "Unlock.Cam.Style.Antagonist.UpgradeB",
      abilities = { "Disruptor", "Shockwave", "Mine", "Vent_Flame" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForAbilityHits.TRT_EnergyForAbilityHits", "/Game/Griffin/Gameplay/Passives/TRT_StartWithAbilities.TRT_StartWithAbilities", "/Game/Griffin/Gameplay/Passives/TRT_StartWithFlameVent.TRT_StartWithFlameVent" } },
  },
  Battling = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Battling_Lv1.CAM_Style_Battling_Lv1", unlock = "Unlock.Cam.Style.Battling",
      abilities = { "Disruptor" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForTakedowns.TRT_EnergyForTakedowns" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Battling_Lv2.CAM_Style_Battling_Lv2", unlock = "Unlock.Cam.Style.Battling.UpgradeA",
      abilities = { "Disruptor" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForTakedowns.TRT_EnergyForTakedowns", "/Game/Griffin/Gameplay/Passives/TRT_SurgeForTakedowns.TRT_SurgeForTakedowns" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Battling_Lv3.CAM_Style_Battling_Lv3", unlock = "Unlock.Cam.Style.Battling.UpgradeB",
      abilities = { "Disruptor" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithDisruptor.TRT_StartWithDisruptor", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForTakedowns.TRT_EnergyForTakedowns", "/Game/Griffin/Gameplay/Passives/TRT_SurgeForTakedowns.TRT_SurgeForTakedowns", "/Game/Griffin/Gameplay/Passives/TRT_SurgeForTakedownsUpgrade.TRT_SurgeForTakedownsUpgrade" } },
  },
  Burning = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Burning_Lv1.CAM_Style_Burning_Lv1", unlock = "Unlock.Cam.Style.Burning",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterBurnerAndRamjetWhenBurning.TRT_StrongerAfterBurnerAndRamjetWhenBurning", "/Game/Griffin/Gameplay/Passives/TRT_GainBurningWhenRamjet.TRT_GainBurningWhenRamjet" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Burning_Lv2.CAM_Style_Burning_Lv2", unlock = "Unlock.Cam.Style.Burning.UpgradeA",
      abilities = { "Vent_Flame" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterBurnerAndRamjetWhenBurning.TRT_StrongerAfterBurnerAndRamjetWhenBurning", "/Game/Griffin/Gameplay/Passives/TRT_GainBurningWhenRamjet.TRT_GainBurningWhenRamjet", "/Game/Griffin/Gameplay/Passives/TRT_StartWithFlameVent.TRT_StartWithFlameVent" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Burning_Lv3.CAM_Style_Burning_Lv3", unlock = "Unlock.Cam.Style.Burning.UpgradeB",
      abilities = { "Vent_Flame" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StrongerAfterBurnerAndRamjetWhenBurning.TRT_StrongerAfterBurnerAndRamjetWhenBurning", "/Game/Griffin/Gameplay/Passives/TRT_GainBurningWhenRamjet.TRT_GainBurningWhenRamjet", "/Game/Griffin/Gameplay/Passives/TRT_StartWithFlameVent.TRT_StartWithFlameVent", "/Game/Griffin/Gameplay/Passives/TRT_BurningInfiniteRamjetAndAfterburner.TRT_BurningInfiniteRamjetAndAfterburner" } },
  },
  Cooling = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Cooling_Lv1.CAM_Style_Cooling_Lv1", unlock = "Unlock.Cam.Style.Cooling",
      abilities = { "Vent" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVent.TRT_StartWithVent", "/Game/Griffin/Gameplay/Passives/TRT_ImprovedCooling.TRT_ImprovedCooling" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Cooling_Lv2.CAM_Style_Cooling_Lv2", unlock = "Unlock.Cam.Style.Cooling.UpgradeA",
      abilities = { "Vent" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVent.TRT_StartWithVent", "/Game/Griffin/Gameplay/Passives/TRT_ImprovedCooling.TRT_ImprovedCooling", "/Game/Griffin/Gameplay/Passives/TRT_GainCooledWhenInFirstPlace.TRT_GainCooledWhenInFirstPlace" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Cooling_Lv3.CAM_Style_Cooling_Lv3", unlock = "Unlock.Cam.Style.Cooling.UpgradeB",
      abilities = { "Vent" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithVent.TRT_StartWithVent", "/Game/Griffin/Gameplay/Passives/TRT_ImprovedCooling.TRT_ImprovedCooling", "/Game/Griffin/Gameplay/Passives/TRT_GainCooledWhenInFirstPlace.TRT_GainCooledWhenInFirstPlace", "/Game/Griffin/Gameplay/Passives/TRT_GainCooledWhenInPodium.TRT_GainCooledWhenInPodium" } },
  },
  Defence = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Defence_Lv1.CAM_Style_Defence_Lv1", unlock = "Unlock.Cam.Style.Defence",
      abilities = { "Shield" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithShield.TRT_StartWithShield", "/Game/Griffin/Gameplay/Passives/TRT_BetterTopSpeedWhenNoCrashes.TRT_BetterTopSpeedWhenNoCrashes" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Defence_Lv2.CAM_Style_Defence_Lv2", unlock = "Unlock.Cam.Style.Defence.UpgradeA",
      abilities = { "Shield" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithShield.TRT_StartWithShield", "/Game/Griffin/Gameplay/Passives/TRT_BetterTopSpeedWhenNoCrashesDummy.TRT_BetterTopSpeedWhenNoCrashesDummy", "/Game/Griffin/Gameplay/Passives/TRT_BetterTopSpeedWhenNoCrashesUpgrade.TRT_BetterTopSpeedWhenNoCrashesUpgrade" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Defence_Lv3.CAM_Style_Defence_Lv3", unlock = "Unlock.Cam.Style.Defence.UpgradeB",
      abilities = { "Shield" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithShield.TRT_StartWithShield", "/Game/Griffin/Gameplay/Passives/TRT_BetterTopSpeedWhenNoCrashesDummy.TRT_BetterTopSpeedWhenNoCrashesDummy", "/Game/Griffin/Gameplay/Passives/TRT_BetterTopSpeedWhenNoCrashesUpgrade.TRT_BetterTopSpeedWhenNoCrashesUpgrade", "/Game/Griffin/Gameplay/Passives/TRT_GainSurgeOnShieldLoss.TRT_GainSurgeOnShieldLoss" } },
  },
  Drafting = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Drafting_Lv1.CAM_Style_Drafting_Lv1", unlock = "Unlock.Cam.Style.Drafting",
      abilities = { "Surge" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithSurge.TRT_StartWithSurge", "/Game/Griffin/Gameplay/Passives/TRT_BetterDrafting.TRT_BetterDrafting" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Drafting_Lv2.CAM_Style_Drafting_Lv2", unlock = "Unlock.Cam.Style.Drafting.UpgradeA",
      abilities = { "Surge" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithSurge.TRT_StartWithSurge", "/Game/Griffin/Gameplay/Passives/TRT_BetterDrafting.TRT_BetterDrafting", "/Game/Griffin/Gameplay/Passives/TRT_LongerDrafting.TRT_LongerDrafting" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Drafting_Lv3.CAM_Style_Drafting_Lv3", unlock = "Unlock.Cam.Style.Drafting.UpgradeB",
      abilities = { "Surge" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithSurge.TRT_StartWithSurge", "/Game/Griffin/Gameplay/Passives/TRT_BetterDrafting.TRT_BetterDrafting", "/Game/Griffin/Gameplay/Passives/TRT_LongerDrafting.TRT_LongerDrafting", "/Game/Griffin/Gameplay/Passives/TRT_BiggerDraftingZones.TRT_BiggerDraftingZones" } },
  },
  Frozen = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Frozen_Lv1.CAM_Style_Frozen_Lv1", unlock = "Unlock.Cam.Style.Frozen",
      abilities = { "Vent_Freezing" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithFrozenVent.TRT_StartWithFrozenVent", "/Game/Griffin/Gameplay/Passives/TRT_FrozenRamjetNoHeat.TRT_FrozenRamjetNoHeat" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Frozen_Lv2.CAM_Style_Frozen_Lv2", unlock = "Unlock.Cam.Style.Frozen.UpgradeA",
      abilities = { "Vent_Freezing" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithFrozenVent.TRT_StartWithFrozenVent", "/Game/Griffin/Gameplay/Passives/TRT_FrozenRamjetNoHeat.TRT_FrozenRamjetNoHeat", "/Game/Griffin/Gameplay/Passives/TRT_OnFrozenGainShield.TRT_OnFrozenGainShield" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Frozen_Lv3.CAM_Style_Frozen_Lv3", unlock = "Unlock.Cam.Style.Frozen.UpgradeB",
      abilities = { "Vent_Freezing" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithFrozenVent.TRT_StartWithFrozenVent", "/Game/Griffin/Gameplay/Passives/TRT_FrozenRamjetNoHeat.TRT_FrozenRamjetNoHeat", "/Game/Griffin/Gameplay/Passives/TRT_OnFrozenGainShield.TRT_OnFrozenGainShield", "/Game/Griffin/Gameplay/Passives/TRT_FrozenDoubleDuration.TRT_FrozenDoubleDuration" } },
  },
  Malfunction = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Malfunction_Lv1.CAM_Style_Malfunction_Lv1", unlock = "Unlock.Cam.Style.Malfunction",
      abilities = { "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair", "/Game/Griffin/Gameplay/Passives/TRT_SurgeWhenSysMalfRecovery.TRT_SurgeWhenSysMalfRecovery" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Malfunction_Lv2.CAM_Style_Malfunction_Lv2", unlock = "Unlock.Cam.Style.Malfunction.UpgradeA",
      abilities = { "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair", "/Game/Griffin/Gameplay/Passives/TRT_SurgeWhenSysMalfRecovery.TRT_SurgeWhenSysMalfRecovery", "/Game/Griffin/Gameplay/Passives/TRT_RecoverFromSysMalfFaster.TRT_RecoverFromSysMalfFaster" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Malfunction_Lv3.CAM_Style_Malfunction_Lv3", unlock = "Unlock.Cam.Style.Malfunction.UpgradeB",
      abilities = { "Repair" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithRepair.TRT_StartWithRepair", "/Game/Griffin/Gameplay/Passives/TRT_SurgeWhenSysMalfRecovery.TRT_SurgeWhenSysMalfRecovery", "/Game/Griffin/Gameplay/Passives/TRT_RecoverFromSysMalfFaster.TRT_RecoverFromSysMalfFaster", "/Game/Griffin/Gameplay/Passives/TRT_MalfunctionRepairOnRecovery.TRT_MalfunctionRepairOnRecovery" } },
  },
  Ramjet = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Ramjet_Lv1.CAM_Style_Ramjet_Lv1", unlock = "Unlock.Cam.Style.Ramjet",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_CriticalRamjetPower.TRT_CriticalRamjetPower", "/Game/Griffin/Gameplay/Passives/TRT_RamjetExtendedAlarm.TRT_RamjetExtendedAlarm" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Ramjet_Lv2.CAM_Style_Ramjet_Lv2", unlock = "Unlock.Cam.Style.Ramjet.UpgradeA",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_CriticalRamjetPower.TRT_CriticalRamjetPower", "/Game/Griffin/Gameplay/Passives/TRT_RamjetExtendedAlarm.TRT_RamjetExtendedAlarm", "/Game/Griffin/Gameplay/Passives/TRT_RamjetExtendedAlarmUpgrade.TRT_RamjetExtendedAlarmUpgrade" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Ramjet_Lv3.CAM_Style_Ramjet_Lv3", unlock = "Unlock.Cam.Style.Ramjet.UpgradeB",
      abilities = {  },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_CriticalRamjetPower.TRT_CriticalRamjetPower", "/Game/Griffin/Gameplay/Passives/TRT_RamjetExtendedAlarm.TRT_RamjetExtendedAlarm", "/Game/Griffin/Gameplay/Passives/TRT_RamjetExtendedAlarmUpgrade.TRT_RamjetExtendedAlarmUpgrade", "/Game/Griffin/Gameplay/Passives/TRT_RamjetReEngageAfterRelease.TRT_RamjetReEngageAfterRelease" } },
  },
  Struggling = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Struggling_Lv1.CAM_Style_Struggling_Lv1", unlock = "Unlock.Cam.Style.Struggling",
      abilities = { "Autopilot" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithAutopilot.TRT_StartWithAutopilot", "/Game/Griffin/Gameplay/Passives/TRT_OneMoreCrash.TRT_OneMoreCrash" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Struggling_Lv2.CAM_Style_Struggling_Lv2", unlock = "Unlock.Cam.Style.Struggling.UpgradeA",
      abilities = { "Autopilot" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithAutopilot.TRT_StartWithAutopilot", "/Game/Griffin/Gameplay/Passives/TRT_OneMoreCrash.TRT_OneMoreCrash", "/Game/Griffin/Gameplay/Passives/TRT_AfterCrashGainSurge.TRT_AfterCrashGainSurge" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Struggling_Lv3.CAM_Style_Struggling_Lv3", unlock = "Unlock.Cam.Style.Struggling.UpgradeB",
      abilities = { "Autopilot" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWithAutopilot.TRT_StartWithAutopilot", "/Game/Griffin/Gameplay/Passives/TRT_OneMoreCrash.TRT_OneMoreCrash", "/Game/Griffin/Gameplay/Passives/TRT_AfterCrashGainSurge.TRT_AfterCrashGainSurge", "/Game/Griffin/Gameplay/Passives/TRT_CoolingAtBack_Campaign.TRT_CoolingAtBack_Campaign" } },
  },
  Surging = {
    [1] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Surging_Lv1.CAM_Style_Surging_Lv1", unlock = "Unlock.Cam.Style.Surging",
      abilities = { "Surge_Overtake" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWtihOvertakingSurge.TRT_StartWtihOvertakingSurge", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForOvertakes.TRT_EnergyForOvertakes" } },
    [2] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Surging_Lv2.CAM_Style_Surging_Lv2", unlock = "Unlock.Cam.Style.Surging.UpgradeA",
      abilities = { "Surge_Overtake" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWtihOvertakingSurge.TRT_StartWtihOvertakingSurge", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForOvertakes.TRT_EnergyForOvertakes", "/Game/Griffin/Gameplay/Passives/TRT_SurgeMoreTopspeed_Trigger.TRT_SurgeMoreTopspeed_Trigger" } },
    [3] = { asset = "/Game/Griffin/Gameplay/Campaign/Loadouts/RacerStyles/CAM_Style_Surging_Lv3.CAM_Style_Surging_Lv3", unlock = "Unlock.Cam.Style.Surging.UpgradeB",
      abilities = { "Surge_Overtake" },
      traits = { "/Game/Griffin/Gameplay/Passives/TRT_StartWtihOvertakingSurge.TRT_StartWtihOvertakingSurge", "/Game/Griffin/Gameplay/Passives/TRT_EnergyForOvertakes.TRT_EnergyForOvertakes", "/Game/Griffin/Gameplay/Passives/TRT_SurgeMoreTopspeed_Trigger.TRT_SurgeMoreTopspeed_Trigger", "/Game/Griffin/Gameplay/Passives/TRT_SurgeTopSpeedSnowball_Trigger.TRT_SurgeTopSpeedSnowball_Trigger" } },
  },
}

-- rank 1..3 of a CAM_Style_<Key>_Lv<N> asset name (nil for anything else)
function M.rankOf(assetName)
    local n = type(assetName) == "string" and assetName:match("^CAM_Style_.-_Lv(%d)$") or nil
    n = tonumber(n)
    if n and n >= 1 and n <= 3 then return n end
    return nil
end

-- the data of a style at a rank (clamped to the ranks it has) -> entry, rank | nil
function M.get(key, rank)
    local s = type(key) == "string" and M.STYLES[key] or nil
    if not s then return nil end
    local r = math.max(1, math.min(3, math.floor(tonumber(rank) or 1)))
    while r > 1 and not s[r] do r = r - 1 end
    if not s[r] then return nil end
    return s[r], r
end

-- the trait id of a trait path (/Game/.../TRT_X.TRT_X -> TRT_X)
function M.traitId(path) return type(path) == "string" and path:match("%.([%w_]+)$") or nil end

return M
