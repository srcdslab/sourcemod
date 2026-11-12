#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <cstrike>
#include <dhooks>

// Runtime check of DHooks on CS:S (x86 and x86_64): virtual hooks + detours,
// int/float/bool/vector/object params, param changes and return values.
//
// Install dhooks-css-test.games.txt into gamedata/. Run `dhx_test` with at least one
// alive bot, or start the server with -dhx_auto to run it unattended and quit.
// Every check logs a "DHX:" line; compare the values with the ones the test passes.
DynamicHook g_hTeleport;
DynamicHook g_hOnTakeDamage;
DynamicHook g_hAcceptInput;
DynamicHook g_hShootPosition;
DynamicHook g_hMaxSpeed;
Handle g_hCallShootPosition;
Handle g_hCallMaxSpeed;
int g_iVariantFieldType;
DynamicDetour g_dRoundRespawn;
DynamicDetour g_dSwitchTeam;
DynamicDetour g_dTerminateRound;
DynamicDetour g_dSetHibernating;

public void OnPluginStart()
{
	GameData gd = new GameData("dhooks-css-test.games");
	if (gd == null)
		SetFailState("gamedata missing");

	g_hTeleport = new DynamicHook(gd.GetOffset("Teleport"), HookType_Entity, ReturnType_Void, ThisPointer_CBaseEntity);
	g_hTeleport.AddParam(HookParamType_VectorPtr);
	g_hTeleport.AddParam(HookParamType_ObjectPtr);
	g_hTeleport.AddParam(HookParamType_VectorPtr);

	g_hOnTakeDamage = new DynamicHook(gd.GetOffset("OnTakeDamage"), HookType_Entity, ReturnType_Int, ThisPointer_CBaseEntity);
	g_hOnTakeDamage.AddParam(HookParamType_ObjectPtr);

	// variant_t is passed by hidden reference (CHandle has a copy constructor), hence ODTOR.
	g_hAcceptInput = new DynamicHook(gd.GetOffset("AcceptInput"), HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_CharPtr);
	g_hAcceptInput.AddParam(HookParamType_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_CBaseEntity);
	g_hAcceptInput.AddParam(HookParamType_Object, 20, DHookPass_ByVal|DHookPass_ODTOR|DHookPass_OCTOR|DHookPass_OASSIGNOP);
	g_hAcceptInput.AddParam(HookParamType_Int);

	g_iVariantFieldType = gd.GetOffset("variant_t::fieldType");

	g_hShootPosition = new DynamicHook(gd.GetOffset("Weapon_ShootPosition"), HookType_Entity, ReturnType_Vector, ThisPointer_CBaseEntity);
	g_hMaxSpeed = new DynamicHook(gd.GetOffset("GetPlayerMaxSpeed"), HookType_Entity, ReturnType_Float, ThisPointer_CBaseEntity);

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gd, SDKConf_Virtual, "Weapon_ShootPosition");
	PrepSDKCall_SetReturnInfo(SDKType_Vector, SDKPass_ByValue);
	g_hCallShootPosition = EndPrepSDKCall();

	StartPrepSDKCall(SDKCall_Player);
	PrepSDKCall_SetFromConf(gd, SDKConf_Virtual, "GetPlayerMaxSpeed");
	PrepSDKCall_SetReturnInfo(SDKType_Float, SDKPass_Plain);
	g_hCallMaxSpeed = EndPrepSDKCall();

	g_dRoundRespawn = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	CheckDetour(g_dRoundRespawn.SetFromConf(gd, SDKConf_Signature, "RoundRespawn"), "RoundRespawn");
	CheckDetour(g_dRoundRespawn.Enable(Hook_Pre, Detour_RoundRespawn), "RoundRespawn enable");

	g_dSwitchTeam = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_CBaseEntity);
	g_dSwitchTeam.AddParam(HookParamType_Int);
	CheckDetour(g_dSwitchTeam.SetFromConf(gd, SDKConf_Signature, "SwitchTeam"), "SwitchTeam");
	CheckDetour(g_dSwitchTeam.Enable(Hook_Pre, Detour_SwitchTeam), "SwitchTeam enable");

	g_dTerminateRound = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
	g_dTerminateRound.AddParam(HookParamType_Float);
	g_dTerminateRound.AddParam(HookParamType_Int);
	CheckDetour(g_dTerminateRound.SetFromConf(gd, SDKConf_Signature, "TerminateRound"), "TerminateRound");
	CheckDetour(g_dTerminateRound.Enable(Hook_Pre, Detour_TerminateRoundPre), "TerminateRound enable");
	CheckDetour(g_dTerminateRound.Enable(Hook_Post, Detour_TerminateRoundPost), "TerminateRound enable post");

	// Keep the server awake so bots can join (no cvar for it on CS:S).
	g_dSetHibernating = new DynamicDetour(Address_Null, CallConv_THISCALL, ReturnType_Void, ThisPointer_Address);
	g_dSetHibernating.AddParam(HookParamType_Bool);
	CheckDetour(g_dSetHibernating.SetFromConf(gd, SDKConf_Signature, "SetHibernating"), "SetHibernating");
	CheckDetour(g_dSetHibernating.Enable(Hook_Pre, Detour_SetHibernating), "SetHibernating enable");

	delete gd;
	if (FindCommandLineParam("-dhx_auto"))
		CreateConVar("dhx_auto", "1");
	RegServerCmd("dhx_test", Command_Test);
	HookEvent("round_freeze_end", Event_RoundFreezeEnd, EventHookMode_PostNoCopy);
	LogMessage("DHX: loaded, hooks set up");
}

// Unattended mode (no console input under gdb): run once a round is live, then quit.
public void Event_RoundFreezeEnd(Event hEvent, const char[] sName, bool bDontBroadcast)
{
	static bool bDone;
	if (bDone || FindConVar("dhx_auto") == null)
		return;
	bDone = true;
	CreateTimer(2.0, Timer_AutoTest);
}

public Action Timer_AutoTest(Handle hTimer)
{
	Command_Test(0);
	CreateTimer(3.0, Timer_Quit);
	return Plugin_Stop;
}

public Action Timer_Quit(Handle hTimer)
{
	LogMessage("DHX: auto quit");
	ServerCommand("quit");
	return Plugin_Stop;
}

void CheckDetour(bool bOk, const char[] sWhat)
{
	if (!bOk)
		SetFailState("DHX: %s failed", sWhat);
}

public Action Command_Test(int iArgs)
{
	int iBot = -1;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && IsFakeClient(i) && IsPlayerAlive(i) && !IsClientSourceTV(i))
		{
			iBot = i;
			break;
		}
	}
	if (iBot == -1)
	{
		LogMessage("DHX: no alive bot");
		return Plugin_Handled;
	}

	LogMessage("DHX: testing on bot %d (%N)", iBot, iBot);
	g_hTeleport.HookEntity(Hook_Pre, iBot, Hook_Teleport);
	g_hOnTakeDamage.HookEntity(Hook_Pre, iBot, Hook_OnTakeDamagePre);
	g_hOnTakeDamage.HookEntity(Hook_Post, iBot, Hook_OnTakeDamagePost);

	float fPos[3] = {123.5, -456.25, 64.0};
	TeleportEntity(iBot, fPos, NULL_VECTOR, NULL_VECTOR);
	float fNow[3];
	GetClientAbsOrigin(iBot, fNow);
	LogMessage("DHX: bot origin after TeleportEntity: %.2f %.2f %.2f", fNow[0], fNow[1], fNow[2]);
	// SDKHooks_TakeDamage bypasses hooks (SH_MCALL), so hurt through a real point_hurt.
	int iHealth = GetClientHealth(iBot);
	DispatchKeyValue(iBot, "targetname", "dhx_victim");
	int iHurt = CreateEntityByName("point_hurt");
	DispatchKeyValue(iHurt, "DamageTarget", "dhx_victim");
	DispatchKeyValue(iHurt, "Damage", "20");
	DispatchSpawn(iHurt);
	AcceptEntityInput(iHurt, "Hurt");
	RemoveEntity(iHurt);
	LogMessage("DHX: health %d -> %d (pre-hook halves 20 damage: expect -10)", iHealth, GetClientHealth(iBot));

	float fEye[3], fShoot[3];
	GetClientEyePosition(iBot, fEye);
	SDKCall(g_hCallShootPosition, iBot, fShoot);
	LogMessage("DHX: Weapon_ShootPosition (no hook) = %.2f %.2f %.2f", fShoot[0], fShoot[1], fShoot[2]);
	g_hShootPosition.HookEntity(Hook_Post, iBot, Hook_ShootPositionPost);
	SDKCall(g_hCallShootPosition, iBot, fShoot);
	LogMessage("DHX: Weapon_ShootPosition (post hook, unchanged) = %.2f %.2f %.2f, eye = %.2f %.2f %.2f", fShoot[0], fShoot[1], fShoot[2], fEye[0], fEye[1], fEye[2]);
	g_hShootPosition.HookEntity(Hook_Pre, iBot, Hook_ShootPositionPre);
	SDKCall(g_hCallShootPosition, iBot, fShoot);
	LogMessage("DHX: Weapon_ShootPosition (pre hook supercede) = %.2f %.2f %.2f (expect 1.50 -2.25 3.00)", fShoot[0], fShoot[1], fShoot[2]);

	float fSpeed = SDKCall(g_hCallMaxSpeed, iBot);
	g_hMaxSpeed.HookEntity(Hook_Pre, iBot, Hook_MaxSpeedPre);
	LogMessage("DHX: GetPlayerMaxSpeed %.2f -> %.2f (expect 123.50)", fSpeed, view_as<float>(SDKCall(g_hCallMaxSpeed, iBot)));

	g_hAcceptInput.HookEntity(Hook_Pre, iBot, Hook_AcceptInput);
	SetVariantString("255 0 0");
	AcceptEntityInput(iBot, "Color", iBot, iBot);

	int iTeam = GetClientTeam(iBot);
	CS_SwitchTeam(iBot, iTeam == CS_TEAM_T ? CS_TEAM_CT : CS_TEAM_T);
	CS_RespawnPlayer(iBot);
	CS_TerminateRound(3.0, CSRoundEnd_Draw);
	LogMessage("DHX: test done");
	return Plugin_Handled;
}

MRESReturn Hook_Teleport(int iEntity, DHookParam hParams)
{
	float fPos[3];
	hParams.GetVector(1, fPos);
	LogMessage("DHX: [vhook] Teleport ent=%d origin=%.2f %.2f %.2f angNull=%d", iEntity, fPos[0], fPos[1], fPos[2], hParams.IsNull(2));
	return MRES_Ignored;
}

MRESReturn Hook_OnTakeDamagePre(int iEntity, DHookReturn hReturn, DHookParam hParams)
{
	// CTakeDamageInfo: Vector m_vecDamageForce, m_vecDamagePosition, m_vecReportedPosition, EHANDLE x3, float m_flDamage
	float fDamage = hParams.GetObjectVar(1, 48, ObjectValueType_Float);
	hParams.SetObjectVar(1, 48, ObjectValueType_Float, fDamage / 2.0);
	LogMessage("DHX: [vhook] OnTakeDamage pre ent=%d damage=%.2f -> %.2f", iEntity, fDamage, fDamage / 2.0);
	return MRES_ChangedHandled;
}

MRESReturn Hook_OnTakeDamagePost(int iEntity, DHookReturn hReturn, DHookParam hParams)
{
	LogMessage("DHX: [vhook] OnTakeDamage post ent=%d return=%d", iEntity, hReturn.Value);
	return MRES_Ignored;
}

MRESReturn Detour_RoundRespawn(int iClient)
{
	LogMessage("DHX: [detour] RoundRespawn client=%d", iClient);
	return MRES_Ignored;
}

MRESReturn Detour_SwitchTeam(int iClient, DHookParam hParams)
{
	LogMessage("DHX: [detour] SwitchTeam client=%d team=%d", iClient, hParams.Get(1));
	return MRES_Ignored;
}

MRESReturn Detour_TerminateRoundPre(Address pGameRules, DHookParam hParams)
{
	float fDelay = hParams.Get(1);
	int iReason = hParams.Get(2);
	LogMessage("DHX: [detour] TerminateRound pre this=%s delay=%.2f reason=%d -> delay 1.5", pGameRules == Address_Null ? "null" : "ok", fDelay, iReason);
	hParams.Set(1, 1.5);
	return MRES_ChangedHandled;
}

MRESReturn Detour_TerminateRoundPost(Address pGameRules, DHookParam hParams)
{
	LogMessage("DHX: [detour] TerminateRound post delay=%.2f reason=%d", view_as<float>(hParams.Get(1)), hParams.Get(2));
	return MRES_Ignored;
}

MRESReturn Detour_SetHibernating(Address pServer, DHookParam hParams)
{
	static bool bLogged;
	if (!bLogged)
	{
		bLogged = true;
		LogMessage("DHX: [detour engine] SetHibernating(%d) -> 0", hParams.Get(1));
	}
	hParams.Set(1, false);
	return MRES_ChangedHandled;
}

MRESReturn Hook_ShootPositionPost(int iEntity, DHookReturn hReturn)
{
	float fVec[3];
	hReturn.GetVector(fVec);
	LogMessage("DHX: [vhook] Weapon_ShootPosition post ent=%d return=%.2f %.2f %.2f", iEntity, fVec[0], fVec[1], fVec[2]);
	return MRES_Ignored;
}

MRESReturn Hook_ShootPositionPre(int iEntity, DHookReturn hReturn)
{
	float fVec[3] = {1.5, -2.25, 3.0};
	hReturn.SetVector(fVec);
	return MRES_Supercede;
}

MRESReturn Hook_MaxSpeedPre(int iEntity, DHookReturn hReturn)
{
	hReturn.Value = 123.5;
	return MRES_Supercede;
}

MRESReturn Hook_AcceptInput(int iEntity, DHookReturn hReturn, DHookParam hParams)
{
	char sInput[32], sValue[32];
	hParams.GetString(1, sInput, sizeof(sInput));
	int iActivator = hParams.IsNull(2) ? -1 : hParams.Get(2);
	int iType = hParams.GetObjectVar(4, g_iVariantFieldType, ObjectValueType_Int);
	hParams.GetObjectVarString(4, 0, ObjectValueType_String, sValue, sizeof(sValue));
	LogMessage("DHX: [vhook] AcceptInput ent=%d input=%s activator=%d variant type=%d value=\"%s\" outputid=%d", iEntity, sInput, iActivator, iType, sValue, hParams.Get(5));
	return MRES_Ignored;
}
