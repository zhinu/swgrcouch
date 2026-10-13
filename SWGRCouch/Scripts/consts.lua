-- SWGRCouch / consts.lua  (G1 Core)
-- Single source of every path, name, enum value, key name and colour used by the mod.
-- No game calls, no state. Every value below was checked statically (ARCHITECTURE.md §0, §4.2 consts):
--   classes      -> work/script-objects.tsv (package /Script/Griffin) and work/reflect.tsv
--   BP / assets  -> notes/asset-list.txt (Content/Griffin/... -> /Game/Griffin/...)
--   enums        -> scripts/reflect-enum.py on SWGR-Win64-Shipping.exe (values re-run 2026-10-06)
--   hook targets -> scripts/reflect-func-all.py (native) and work/exports/*.txt (Blueprint)

local C = {}

C.MOD       = "SWGRCouch"
C.VERSION = "0.13.2"
C.TAB_ID    = "SWGR_SplitScreen"   -- FName of our CommonUI tab (not in DT_TabDescriptors)
C.TAB_LABEL = "FREE MODE"     -- 0.11.0: was "SPLIT SCREEN" (the mod also races solo: any track, any vehicle, any settings)

-- Game tab id (FName string) -> WS_ScreenContent index of the game's own pane [MT§2]
C.GAME_TABS = {
    MainMenu_Recommended = 0,
    MainMenu_Scenarios   = 1,
    MainMenu_Arcade      = 2,
    MainMenu_Multiplayer = 3,
}

-- Native classes (UClass object paths). Short key = class FName without U/A prefix.
C.CLASS = {
    PlayerController = "/Script/Engine.PlayerController",
    GameModeBase     = "/Script/Engine.GameModeBase",
    GridPanel        = "/Script/UMG.GridPanel",
}
for _, n in ipairs({
    "FrontEndGameMode", "FrontEndGameState", "RacingGameMode", "RacingGameState", "VehiclePawn",
    "GfnPlayerController", "GfnPlayerState", "GfnGameInstance", "FuseHudWidget", "UIManager",
    "CosmeticStateMachineManager", "ViewModelSubsystem", "EventRecipeSubsystem", "PlayfabOnlineMatchmaking",
    "PvpFlowComponent", "PlayerSpectatorComponent", "DrivingAIController", "PassbyWorldSubsystem",
    "OvertakeWorldSubsystem", "AudioNonPlayerProximityWorldSubsystem",
    -- 0.7.0 uxsplit.lua: the one race-message router (GameInstance subsystem; UE4SS object dump, run H reflection)
    "GfnMessagingSubsystem",
    -- race-builder data assets (LaunchCustomRace param classes [MT§5]; work/griffin-classes.txt lists them in the
    -- Griffin module). VERIFY(V-BLD-04): these resolve; builder skips the class check of a class that does not.
    "VehicleArchetype", "GameModeVariantDef", "TrackDef", "PlanetDef", "VehicleBuildDef",
}) do
    C.CLASS[n] = "/Script/Griffin." .. n
end

-- Class default objects of function libraries / settings (StaticFindObject paths)
C.CDO = {
    GameplayStatics           = "/Script/Engine.Default__GameplayStatics",
    KismetSystemLibrary       = "/Script/Engine.Default__KismetSystemLibrary",
    WidgetBlueprintLibrary    = "/Script/UMG.Default__WidgetBlueprintLibrary",
    SubsystemBlueprintLibrary = "/Script/Engine.Default__SubsystemBlueprintLibrary",
    GameMapsSettings          = "/Script/EngineSettings.Default__GameMapsSettings",
    InputDeviceLibrary        = "/Script/Engine.Default__InputDeviceLibrary",   -- work/script-objects.tsv
    -- 0.7.0 uxsplit.lua: MPC reads/writes (Get/SetVectorParameterValue, SetScalarParameterValue; UE4SS object dump)
    KismetMaterialLibrary     = "/Script/Engine.Default__KismetMaterialLibrary",
    -- 0.11.0 hud.lua: GetViewportSize(Object) -> Vector2D px, GetViewportScale(Object) -> Float DPI (UE4SS object dump)
    WidgetLayoutLibrary       = "/Script/UMG.Default__WidgetLayoutLibrary",
}

-- Blueprint classes (generated class paths, "_C"). LoadAsset needs the path WITHOUT "_C" (util does that).
C.BP = {
    MainMenu         = "/Game/Griffin/UI/Screens/MainMenu/WBP_FE_MainMenu.WBP_FE_MainMenu_C",
    TabBtn           = "/Game/Griffin/UI/Widgets/Buttons/WBP_Tab_Btn.WBP_Tab_Btn_C",
    CommonBtn        = "/Game/Griffin/UI/Widgets/Buttons/WBP_Common_Btn.WBP_Common_Btn_C",
    VerticalBtn      = "/Game/Griffin/UI/Widgets/Buttons/WBP_Vertical_Btn.WBP_Vertical_Btn_C",
    SettingList      = "/Game/Griffin/UI/Widgets/Settings/WBP_Setting_List.WBP_Setting_List_C",
    SectionHeader    = "/Game/Griffin/UI/Widgets/Global/WBP_SectionHeaderModal.WBP_SectionHeaderModal_C",
    Builder          = "/Game/Griffin/UI/Widgets/FrontEnd/QuickRace/WBP_FE_QuickRace_Custom_Widget.WBP_FE_QuickRace_Custom_Widget_C",
    HudRace          = "/Game/Griffin/UI/Screens/WBP_Hud_Race.WBP_Hud_Race_C",
    HudMemory        = "/Game/Griffin/UI/Screens/WBP_Hud_Memory.WBP_Hud_Memory_C",
    LapCounter       = "/Game/Griffin/UI/Widgets/HUD/WBP_Hud_EventLapCounter.WBP_Hud_EventLapCounter_C",
    LapCounterMemory = "/Game/Griffin/UI/Widgets/HUD/WBP_Hud_EventLapCounter_Memory.WBP_Hud_EventLapCounter_Memory_C",
    -- shown by CSM_RF_LocalResults when P1 finished [HUD§3.3]; a CommonActivatableWidget (exports/hud)
    PostRaceInfo     = "/Game/Griffin/UI/Screens/PostRace/WBP_PostRace_Info.WBP_PostRace_Info_C",
    -- shown by CSM_RF_SpectatingInProgress (P1 wrecked) over the whole viewport (asset-list.txt; wreck-design §4.3)
    PvpSpectate      = "/Game/Griffin/UI/Screens/Multiplayer/WBP_PVP_Spectate.WBP_PVP_Spectate_C",
    -- 0.12.0 UI v2 (notes/design/ui-v2/ui-redesign-final.md §3.4; every name checked in asset-list.txt; recipes in
    -- notes/research/ui-parts-catalogue.md §1). Variables are written before the add (PreConstruct reads them).
    -- page title "/RACE SETUP" (HeaderText, LightVersion; SetScreenTitleText later)                      C2, V-FIN-03
    ScreenTitle      = "/Game/Griffin/UI/Widgets/Decorative/WBP_Screen_Title.WBP_Screen_Title_C",
    -- command-row pill without button logic (ColorBase / ColorSelect / ColorUnselect; Img_Tile_Select_Thick = focus) C4
    ButtonBackerPill = "/Game/Griffin/UI/Widgets/Buttons/WBP_CommonButtonBacker_Pill.WBP_CommonButtonBacker_Pill_C",
    -- CLASS info-panel trait (write Txt_Title / RT_Desc; never InitFromTrait: soft loads)                C13, V-FIN-08
    VehicleTrait     = "/Game/Griffin/UI/Widgets/Vehicle/WBP_VehicleTrait.WBP_VehicleTrait_C",
    -- Aurebesh micro line + Moki label + rule (Label, Color; SetLabel)                                        C13
    SectionSubLabel  = "/Game/Griffin/UI/Widgets/Global/WBP_SectionSubLabel.WBP_SectionSubLabel_C",
    -- the teal info panel (MainPanelColor, ShowTightPanel, ShowShadow, ShowGradientPanel; NS_Content)        C13
    DarkPanel        = "/Game/Griffin/UI/Widgets/Decorative/WBP_DarkPanel.WBP_DarkPanel_C",
    -- the run map's dark detail card (ShowHeader, Label, SetTooltipLabel; NS_TooltipContent:SetContent)      C16
    TooltipHolder    = "/Game/Griffin/UI/Widgets/Decorative/WBP_Tooltip_Holder.WBP_Tooltip_Holder_C",
}

-- Data assets (object paths "Pkg.Obj")
local PAUSE = "/Game/Griffin/Config/StateMachines/PauseMenus/"
local RF    = "/Game/Griffin/Config/StateMachines/RaceFlow/"
C.ASSET = {
    CSM_PauseRoot       = PAUSE .. "CSM_PauseMenus_Root.CSM_PauseMenus_Root",
    CSM_PauseMenu       = PAUSE .. "CSM_PauseMenus_PauseMenu.CSM_PauseMenus_PauseMenu",
    CSM_PauseIdle       = PAUSE .. "CSM_PauseMenus_Idle.CSM_PauseMenus_Idle",
    -- sibling of Idle under CSM_PauseMenus_Root (Root's only two children, hard imports; asset-list.txt:57745).
    -- Paused = Active active (positive test): Idle is still loaded but NOT active once the race CSM leaves
    -- CSM_RF_InProgress/_Countdown (the only states that run CSM_PauseMenus_Root via CsmActionRunSubCsmData).
    CSM_PauseActive     = PAUSE .. "CSM_PauseMenus_Active.CSM_PauseMenus_Active",
    -- the two race-flow states that run the pause sub-machine (asset-list.txt:57799, :57792); gate the Idle fallback
    CSM_RFInProgress    = RF .. "CSM_RF_InProgress.CSM_RF_InProgress",
    CSM_RFCountdown     = RF .. "CSM_RF_Countdown.CSM_RF_Countdown",
    CSM_InProgressInHud = RF .. "CSM_RF_InProgress_InHud.CSM_RF_InProgress_InHud",
    CSM_CountdownInHud  = RF .. "CSM_RF_Countdown_InHud.CSM_RF_Countdown_InHud",
    CSM_PostRace        = RF .. "CSM_RF_PostRacePhase.CSM_RF_PostRacePhase",
    CSM_LocalResults    = RF .. "CSM_RF_LocalResults.CSM_RF_LocalResults",
    -- P1 wrecked/out: Spectating -> SpectatingInProgress (WBP_PVP_Spectate_C), children of CSM_RF_Racing (asset-list)
    CSM_Spectating      = RF .. "CSM_RF_Spectating.CSM_RF_Spectating",
    CSM_SpectatingInProgress = RF .. "CSM_RF_SpectatingInProgress.CSM_RF_SpectatingInProgress",
    -- front-end race builder state (asset-list.txt:59558); read by builder.lua
    CSM_QuickRaceSetup  = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_QuickRaceSetup.CSM_FrontEnd_QuickRaceSetup",
    -- front-end root and main-menu state (asset-list.txt:59559, :59548); builder devscreen exit, net client menu
    CSM_FrontEndRoot    = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_Root.CSM_FrontEnd_Root",
    CSM_PrimaryModeSelect = "/Game/Griffin/Gameplay/FrontEnd/StateMachine/CSM_FrontEnd_PrimaryModeSelect.CSM_FrontEnd_PrimaryModeSelect",
    -- 0.7.0 uxsplit.lua (asset-list.txt:72611, :89474): the world-global HUD colour collection (last-crash colours,
    -- ramjet FadeDirection/FadeProgress) and the vehicle-state VFX collection (full-screen danger effects; probe only).
    -- Both are looked up with StaticFindObject only (loaded with the race map), never LoadAsset.
    MPC_HUD             = "/Game/Griffin/UI/Library/Materials/HUD/MPC_HUD_Parameters.MPC_HUD_Parameters",
    MPC_VehicleVfx      = "/Game/Griffin/Vfx/Vehicles/StatusEffects/MPC_VehicleState_vfx.MPC_VehicleState_vfx",
}

-- Fallback CosmeticStateName FNames for IsStateActive(Name) [HUD§3.3]. Keyed like C.ASSET without "CSM_".
C.STATE_NAME = {
    InProgressInHud = "InProgress_InHud",
    CountdownInHud  = "Countdown_InHud",
    LocalResults    = "LocalResults",
}

C.MAP = {
    FrontEnd = "/Game/Griffin/Maps/L_FrontEnd/L_FrontEnd",
    -- seamless-travel transition map (asset-list.txt:60374); read by phase.lua
    Transition = "/Game/Griffin/Maps/L_SeamlessTravel/L_SeamlessTravel",
}

-- Hook paths (UFunction object paths). /Script/ = native (pre+post), /Game/ = Blueprint (one post-like callback).
local BP = C.BP
C.FN = {
    MenuRegisterTabs      = BP.MainMenu .. ":RegisterTabs",
    MenuCustomEvent       = BP.MainMenu .. ":CustomEvent",
    CommonBtnClicked      = BP.CommonBtn .. ":BP_OnClicked",
    BuilderGo             = BP.Builder ..
        ":BndEvt__WBP_FE_QuickRace_Custom_Widget_Btn_Go_K2Node_ComponentBoundEvent_6_CommonButtonBaseClicked__DelegateSignature",
    LapUpdate             = BP.LapCounter .. ":UpdateCurrentLap",
    LapUpdateMemory       = BP.LapCounterMemory .. ":UpdateCurrentLap",
    -- OnUserInputDeviceChanged(Enum NewConnectionState, Struct PlatformUserId, Struct InputDeviceId) flags 0x80401
    DeviceChanged         = "/Script/Griffin.GfnGameInstance:OnUserInputDeviceChanged",
    -- HandleNetworkFailure(Object World, Object NetDriver, Byte FailureType, Str ErrorString) flags 0x40401
    NetFailure            = "/Script/Griffin.GfnGameInstance:HandleNetworkFailure",
    -- static native BlueprintCallable ReturnToMainMenu(Object WorldContextObject), flags 0x4022401 [reflect-func-all];
    -- WBP_Pause's Quit/Abandon (QuitToMenu/AbandonRun) calls it [exports/WBP_Pause.txt import -135]; read by net.lua
    UIReturnToMainMenu    = "/Script/Griffin.UIBlueprintFunctionLibrary:ReturnToMainMenu",
    -- UGameUserSettings:SaveSettings() flags 0x4020402, ApplySettings(Bool bCheckForCommandLineOverrides) 0x4020402
    -- [reflect-func-all; reflect.tsv: SaveSettings only on UGameUserSettings]; read by gfx.lua (takedown guard)
    GUSSaveSettings       = "/Script/Engine.GameUserSettings:SaveSettings",
    GUSApplySettings      = "/Script/Engine.GameUserSettings:ApplySettings",
    -- HandleStartingNewPlayer(Object NewPlayer) BlueprintNativeEvent flags 0x8020c02
    StartingNewPlayer     = "/Script/Engine.GameModeBase:HandleStartingNewPlayer",
    -- Client_SetIsMidGameJoiner(Bool isMidGameJoiner) NetClient RPC flags 0x1040cc1
    MidGameJoiner         = "/Script/Griffin.PlayerSpectatorComponent:Client_SetIsMidGameJoiner",
    -- OnPlayerControllerDestroyed(Object playerController) flags 0x20401 (RacingGameMode owner)
    RaceCtrlDestroyed     = "/Script/Griffin.RacingGameMode:OnPlayerControllerDestroyed",
    -- RequestReturnToMenus() BlueprintCallable flags 0x4020401
    RequestReturnToMenus  = "/Script/Griffin.RacingGameMode:RequestReturnToMenus",
    -- OnSeamlessTravelStarted(Object currentWorld, Str newMapUrl) flags 0x40401
    SeamlessTravelStarted = "/Script/Griffin.RacingGameState:OnSeamlessTravelStarted",
    -- Client_RequestAckObjects() NetClient RPC flags 0x1020cc0
    AckRequest            = "/Script/Griffin.PvpFlowComponent:Client_RequestAckObjects",
    HumanSwitchedWithAI   = "/Script/Griffin.MatchManagerSubsystem:OnHumanSwitchedWithAI",
    ControllerAssigned    = "/Script/Griffin.VehiclePawn:Multi_ReceiveControllerAssigned",
    -- PossessedPawnChanged(Object oldPawn, Object newPawn) flags 0x40401
    PossessedPawnChanged  = "/Script/Griffin.GfnPlayerController:PossessedPawnChanged",
    -- 0.7.0 uxsplit.lua: all native, registered only while a split race runs (UE4SS object dump + reflect-func-all on the
    -- exe copy, 2026-10-07). Post-callbacks get (ctx, ReturnValue, params...) when the function returns a value.
    -- GetGameInstanceSubsystem(Object ContextObject, Class Class) -> Object
    GIS                   = "/Script/Engine.SubsystemBlueprintLibrary:GetGameInstanceSubsystem",
    -- AddMessage(const Name& MessageID, Struct& MessageHandle, Delegate OptionalResultDelegate, Object OptionalPayload,
    --   Byte OptionalHorizontalAlignment, Byte OptionalVerticalAlignment) flags 0x4420401
    MsgAdd                = "/Script/Griffin.GfnMessagingSubsystem:AddMessage",
    -- AddMessageParams(const Struct<GfnMessagingParams>& MessageID {ID, Parameters, Payload, Handle, H/V alignment},
    --   Delegate OptionalResultDelegate) -> Struct<GfnMessageHandle>
    MsgAddParams          = "/Script/Griffin.GfnMessagingSubsystem:AddMessageParams",
    -- RemoveMessage(const Name& MessageID, Bool IncludePendingMessages, const Struct& OptionalMessageHandle)
    MsgRemove             = "/Script/Griffin.GfnMessagingSubsystem:RemoveMessage",
    -- RemoveMessageByHandle(const Struct& MessageHandle)
    MsgRemoveByHandle     = "/Script/Griffin.GfnMessagingSubsystem:RemoveMessageByHandle",
    -- FlushMessageContainer(Name Container) flags 0x4020401
    MsgFlush              = "/Script/Griffin.GfnMessagingSubsystem:FlushMessageContainer",
    -- GetPlayerPawn(Object WorldContextObject, Int PlayerIndex) -> Object (static)
    GetPlayerPawn         = "/Script/Engine.GameplayStatics:GetPlayerPawn",
    -- SetVectorParameterValue(Object WorldContextObject, Object Collection, Name ParameterName, Struct ParameterValue)
    KmlSetVector          = "/Script/Engine.KismetMaterialLibrary:SetVectorParameterValue",
    -- PlayAnimation(Object InAnimation, Float StartAtTime, Int NumLoopsToPlay, Byte PlayMode, Float PlaybackSpeed,
    --   Bool bRestoreState) -> Struct<WidgetAnimationHandle>
    PlayAnimation         = "/Script/UMG.UserWidget:PlayAnimation",
    -- GetFullScreenEffectsEnabled() -> Bool, flags 0x54020401 (BlueprintPure const; BP_VehicleState's Tick reads it)
    FullScreenFx          = "/Script/Griffin.GfnUserSettings:GetFullScreenEffectsEnabled",
}

-- 0.7.0 uxsplit.lua: race rows of DT_HUD_NotificationData (row name = message id; notes/research/ux-split-messages.md
-- §1). c = TargetContainer, text = English body (matching a copy that waited in a full container), min =
-- MinimumDisplayTime (s), repost = a plain AddMessage post the game removes for EVERY player (RemoveMessage by id /
-- FlushMessageContainer): re-posted for the players that still hold it; global = no player (shown in every HUD);
-- perHud = posted by EVERY HUD instance (WBP_HUD_EliminationInfo2): the first post goes to every HUD, the duplicates
-- within 1.5 s are hidden.
C.MSG_CONTAINERS = { "HUD_Notification_Container", "Hud_Notification_GameFeed", "Hud_Notification_CrashFeed" }
local FEED, CENTER, CRASH = "Hud_Notification_GameFeed", "HUD_Notification_Container", "Hud_Notification_CrashFeed"
C.MSG = {
    Vulnerable                 = { c = FEED,   text = "System Malfunction",        min = 0,    repost = true },
    VulnerableDueToStatus      = { c = FEED,   text = "{Status}",                  min = 0 },
    VulnerableDueToChoked      = { c = FEED,   text = "{Status}",                  min = 0 },
    PerfectLanding             = { c = FEED,   text = "Perfect Landing",           min = 5 },
    Takedown                   = { c = FEED,   text = "{Player} Taken down",       min = 5 },
    ShieldBroken               = { c = FEED,   text = "SHIELD BROKEN",             min = 3 },
    SurgeExtended              = { c = FEED,   text = "Surge extended ({Reason})", min = 1.5 },
    SurgeEnded                 = { c = FEED,   text = "Surge ended ({Reason})",    min = 3 },
    WrongWay                   = { c = CENTER, text = "Wrong Way",                 min = 0,    repost = true },
    OutOfBounds                = { c = CENTER, text = "Out of Bounds",             min = 0,    repost = true },
    AffixDamaged               = { c = CENTER, text = "{Affix} damaged",           min = 3 },
    AutopilotActive            = { c = CENTER, text = "Autopilot Active",          min = 0 },
    AutopilotEnding            = { c = CENTER, text = "Autopilot Ending",          min = 0 },
    DisruptorTarget            = { c = CENTER, text = "Targeted by {player}",      min = 0 },
    RacerEliminated            = { c = CENTER, text = "{Player} eliminated",       min = 2,    perHud = true },
    RacerKnockedOut            = { c = CENTER, text = "Knocked Out",               min = 2,    perHud = true },
    TakendownBy                = { c = CRASH,  text = "Taken down by {Player}",    min = 0 },
    BurningExploded            = { c = CRASH,  text = "Burning Explosion!",        min = 0,    repost = true },
    CorrosionExploded          = { c = CRASH,  text = "Vehicle Corroded!",         min = 0,    repost = true },
    RamjetExploded             = { c = CRASH,  text = "Ramjet Exploded!",          min = 0,    repost = true },
    RaceEndingTimer            = { c = FEED,   text = "Race ending in {seconds}",  min = 1.75, global = true },
    RaceEndingTimerLongDisplay = { c = FEED,   text = "Race ending in {seconds}",  min = 5,    global = true },
}

-- 0.7.0 uxsplit.lua colours (FLinearColor, linear RGB; notes/research/ux-split-visuals.md §1.1, §4.3-4.5).
C.UX = {
    -- MPC_HUD_Parameters *_Default values: written back if the MPC's own *_Default cannot be read
    Defaults      = { AfterburnerColor = { R = 0.9911, G = 0.3968, B = 0.0666, A = 1 },
                      HighThreatColor  = { R = 0.0887, G = 0.0097, B = 0.0,    A = 1 },
                      MalfunctionColor = { R = 0.4969, G = 0.0648, B = 0.0,    A = 1 } },
    TintNone      = { R = 1, G = 1, B = 1, A = 1 },
    TintLastCrash = { R = 1.009, G = 0.093, B = 0.3045, A = 1 },   -- AfterburnerColor_LastCrash / _Default per channel
    TintRamjet    = { R = 0.0517, G = 0.544, B = 15.0, A = 1 },    -- RamjetColor / AfterburnerColor_Default per channel
    TintOverheat  = { R = 2.2, G = 0.12, B = 0.05, A = 1 },        -- ramjet overheat: hot red (OverheatColor-like), the
                                                                   -- game's "stop accelerating" warning per view
    FadeColour    = { R = 0.45, G = 0.02, B = 0.0, A = 1 },        -- final-life camera tint (dark red)
    FlashColour   = { R = 1.0, G = 0.85, B = 0.6, A = 1 },         -- system-malfunction camera flash (warm white)
    IconDim       = { R = 0.1, G = 0.1, B = 0.1, A = 0.1 },        -- BotEngineInfo icon "off" (its own SelectColor value)
    IconFull      = { R = 1, G = 1, B = 1, A = 1 },
}

-- 0.8.0 subsplit.lua: dialogue trigger rules (notes/research/subtitles-split.md §2.2). Suffixes after "Trigger.",
-- prefix match ("Sabotage" covers "Sabotage.PlayerSabotaged"). both = a line for every local player (race start,
-- eliminations, sabotage, introductions...); involved = an ability hit: PlayerHits -> the hitter, HitsPlayer -> the hit
-- player (OnPlayerHitTargetWithAbility hook); any other trigger goes to the player whose pod asked for it.
C.SUB_RULES = {
    both = { "RaceStart", "NemesisFinishes", "RacerEliminated", "AnnounceRacerEliminated", "AnnounceInvasion",
             "IntroduceEvent", "IntroduceHazard", "FinalEliminator", "RaceFinished", "Sabotage" },
    involved = { "Ability.PlayerHits", "Ability.HitsPlayer", "Vent.PlayerHits", "Vent.HitsPlayer" },
}

-- FKey names (strings present in the exe [API§3]); callers build {KeyName = U.fname(C.KEY.A)}
C.KEY = {
    A     = "Gamepad_FaceButton_Bottom",
    B     = "Gamepad_FaceButton_Right",
    Y     = "Gamepad_FaceButton_Top",
    X     = "Gamepad_FaceButton_Left",   -- 0.13.0: guests' COPY P1 on the racer cards
    Start = "Gamepad_Special_Right",
    Escape = "Escape",              -- EKeys::Escape (keyboard pause key of P1; pause.lua P1 poll, V-PAU-03)
}

-- Enum values (integers; UFunction enum params take integers [API§9])
C.E = {
    InputSource  = { None = 0, Player = 1, AI = 2 },                                   -- EVehicleInputSource
    Override     = { None = 0, SpawnPlayer = 1, SpawnAI = 2, FinishedRace = 3, Disconnect = 4, RollingStart = 5,
                     TakedownCam = 6, VehicleCineProxy = 7, Debug = 8, Autopilot = 9, Reset = 10 }, -- EVehicleInputSourceOverrideReason
    AIBehaviour  = { Idle = 0, Countdown = 1, Racing = 2, Aggression = 3, PostRace = 4, FollowSplineDirect = 5 }, -- ESimpleAIBehaviour
    Archetype    = { Car = 0, Plane = 1, Bike = 2, Skimmer = 3 },                       -- EVehicleArchetype
    GridEntry    = { Car = 0, Plane = 1, Bike = 2, Skimmer = 3, PlayerChoice = 4 },     -- ERaceGridEntryType
    PrimaryFlow  = { Unknown = 0, Campaign = 1, QuickRace = 2, Arcade = 3, Multiplayer = 4 }, -- EGfnPrimaryFlow
    Vis          = { Visible = 0, Collapsed = 1, Hidden = 2, HitTestInvisible = 3, SelfHitTestInvisible = 4 }, -- ESlateVisibility
    UILayer      = { InWorld = 0, HUD = 1, Menu = 2, Dialog = 3, MenuOverlay = 10 },    -- EUILayer
    TwoP         = { Horizontal = 0, Vertical = 1 },                                    -- ETwoPlayerSplitScreenType
    ThreeP       = { FavorTop = 0 },                                                    -- EThreePlayerSplitScreenType
    FourP        = { Grid = 0 },                                                        -- EFourPlayerSplitScreenType
    HAlign       = { Fill = 0, Left = 1, Center = 2, Right = 3 },                       -- EHorizontalAlignment [UI§1.3]
    Stretch      = { ScaleToFit = 2, ScaleToFitX = 3 },                                 -- EStretch (usmap; hud.lua)
    DeviceConn   = { Invalid = 0, Unknown = 1, Disconnected = 2, Connected = 3 },       -- EInputDeviceConnectionState
    FailReason   = { None = 0, Wrecked = 1, ModeRules = 2, HighRisk = 4, ExtraConditions = 8, MissedRequiredWin = 16,
                     UnknownPreSave = 32 },                                             -- ERaceFailReason (flags)
    ViewBlend    = { Linear = 0 },                                                      -- EViewTargetBlendFunction (VTBlend_Linear)
    -- ENetworkFailure, index = value (0-based)
    NetworkFailure = {
        [0] = "NetDriverAlreadyExists", [1] = "NetDriverCreateFailure", [2] = "NetDriverListenFailure",
        [3] = "ConnectionLost", [4] = "ConnectionTimeout", [5] = "FailureReceived", [6] = "OutdatedClient",
        [7] = "OutdatedServer", [8] = "PendingConnectionFailure", [9] = "NetGuidMismatch", [10] = "NetChecksumMismatch",
    },
}

-- Player colours (FLinearColor tables, linear RGB). 0.12.0 UI v2 (ui-redesign-final.md §2.2, rule 4): the game's own
-- planet tones (PlanetsToColors of the Arcade event card, ui-parts-catalogue §5) instead of the 0.11 blue / red / green /
-- yellow; used on small marks only (P-tags, the 6-su art rule, the stripe on scenario art, taken / lobby tags, in-race
-- tags). nametags.lua, roster.lua and the RACERS taken tags read this table and follow without edits.
C.COLOURS = {
    [1] = { R = 0.7913, G = 0.3968, B = 0.1046, A = 1 },   -- P1 APRICOT #E6A95B (Jakku / Tatooine)
    [2] = { R = 0.2874, G = 0.5271, B = 0.4678, A = 1 },   -- P2 TEAL #92C0B6 (Ando Prime)
    [3] = { R = 0.4564, G = 0.5647, B = 0.1878, A = 1 },   -- P3 LIME #B4C678 (Lantaana)
    [4] = { R = 0.5906, G = 0.0931, B = 0.0931, A = 1 },   -- P4 CRAIT RED #CA5656 (Crait)
    Remote = { R = 1, G = 1, B = 1, A = 1 },               -- remote humans: neutral white (unchanged)
}
-- Tag ink on each hue (§2.2): INK #222221 on apricot / teal / lime, WHITE on Crait red (Moki 46-52 su only).
C.COLOUR_INK = {
    [1] = { R = 0.0160, G = 0.0160, B = 0.0152, A = 1 },
    [2] = { R = 0.0160, G = 0.0160, B = 0.0152, A = 1 },
    [3] = { R = 0.0160, G = 0.0160, B = 0.0152, A = 1 },
    [4] = { R = 1, G = 1, B = 1, A = 1 },
    Remote = { R = 0.0160, G = 0.0160, B = 0.0152, A = 1 },
}
-- VERIFY(V-FIN-13): P4's Crait red readable over bright tracks and not mistaken for the UI's RUST accent. Fallback:
-- C.COLOURS[4] = C.COLOUR_P4_SAND and C.COLOUR_INK[4] = INK (SAND #D1C371, the Sentinel I tone).
C.COLOUR_P4_SAND = { R = 0.6376, G = 0.5457, B = 0.1651, A = 1 }

--- Name of an enum value. Works for name->value tables (C.E.Override) and value->name arrays (C.E.NetworkFailure).
---@return string
function C.enumName(enumTable, value)
    if type(enumTable) ~= "table" then return tostring(value) end
    local direct = enumTable[value]
    if type(direct) == "string" then return direct end
    for name, v in pairs(enumTable) do
        if v == value and type(name) == "string" then return name end
    end
    return tostring(value)
end

return C
