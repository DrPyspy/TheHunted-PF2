/*
	TODO:
	- Silence text events from Civvy's invisible intel intel being picked up/dropped
	- Fix votes being doubled (tripled?) up
*/

/*
	Based off of the original Hunted plugin by msleeper, adapted for Pre-Fortress 2!
	There are still some vestigial bits here and there from the original plugin
	that need to be cleaned out, but the code should otherwise be fairly straightforward.
	
	The code is a bit mixed, as this was my first attempt at modifying and writing
	SourcePawn stuff, and the original plugin was a bit old. There's new features
	and old features everywhere!
	
	Original plugin: https://forums.alliedmods.net/showthread.php?p=646703
*/


#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <pf2>

#include "hunted/admin.sp"
//#include "hunted/votes.sp"

#define ROSTERSIZE 10

#define VO_HUNTEDDEAD "vo/tsf_hunted_v1/vox_civdead.mp3"
#define VO_HUNTEDCLOSE "vo/tsf_hunted_v1/vox_civlocated_v2.mp3"

#define LIMIT_EXACT 0
#define LIMIT_PERC 1

int currentRoster_limits[2][ROSTERSIZE] = {
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};
int currentRoster_limitMode[2][ROSTERSIZE] = {
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
	{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

static const String:classnames[][] = {
	"scout", "sniper", "soldier", "demoman", "medic", "heavy", "pyro", "spy", "engineer", "civilian"
};

// [Py] Pretty names
static const String:class_pnames[][] = {
	"Scout", "Sniper", "Soldier", "Demoman", "Medic", "Heavy", "Pyro", "Spy", "Engineer", "Civilian"
};

/*
================================================================================
	Voice shite
================================================================================
*/

	// [Py] should be rewritten to support an external config file for modification

	#define MAX_VOICECATEGORIES 3
	#define MAX_VOICEOPTIONS 8
	#define MAX_VOICEVARIANTS 2

	char civvy_commands[MAX_VOICECATEGORIES][MAX_VOICEOPTIONS][PLATFORM_MAX_PATH] = {
		{ "MEDIC!", "Thanks!", "Go Go Go!", "", "Go Left", "Go Right", "", "" },
		{ "Sniper!", "Spy!", "", "", "", "", "", "" },
		{ "Help!", "", "", "", "", "", "", "" },
	};

	char civvy_lines[MAX_VOICECATEGORIES][MAX_VOICEOPTIONS][MAX_VOICEVARIANTS][PLATFORM_MAX_PATH] = {
		{
			{ "vo/tsf_hunted_v1/civvy_medic1.mp3", "vo/tsf_hunted_v1/civvy_medic2.mp3" },
			{ "vo/tsf_hunted_v1/civvy_thanks.mp3", "" },
			{ "vo/tsf_hunted_v1/civvy_go1.mp3", "vo/tsf_hunted_v1/civvy_go2.mp3" },
			{ "", "" },
			{ "vo/tsf_hunted_v1/civvy_moveleft.mp3", "" },
			{ "vo/tsf_hunted_v1/civvy_moveright.mp3", "" },
			{ "", "" },
			{ "", "" },
		},
		{
			{ "vo/tsf_hunted_v1/civvy_sniper1.mp3", "vo/tsf_hunted_v1/civvy_sniper2.mp3" },
			{ "vo/tsf_hunted_v1/civvy_spy.mp3", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
		},
		{
			{ "vo/tsf_hunted_v1/civvy_helpme1.mp3", "vo/tsf_hunted_v1/civvy_helpme2.mp3" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
			{ "", "" },
		}
	};

int CurrentHunted = -1;             // ClientID of the current Hunted
int PreviousHunted = -1;            // ClientID of the previous Hunted, used for anti-grief checks
bool hunt_isEnabled = true;
new bool:IsHuntedDead = false;
//new bool:NewHuntedOnWarning = false;

bool roundActive = false;

// CVars
ConVar cvar_forceHunted;

ConVar cvar_forceEnabled;
ConVar cvar_classLimits;

float lastCivVoice = 0.0;

int huntedFlag = -1;
int huntedWarns = 0;
float huntedAlertDelay = 0.0;

/*
================================================================================
	Plugin registering and unregistering shite
================================================================================
*/

	public Plugin:myinfo =
	{
		name = "The Hunted (PF2 Edition)",
		author = "msleeper (original plugin), DrPyspy (PF2 adaptation)",
		description = "The Hunted plugin, now for PF2!",
	};

	public OnPluginStart()
	{
		cvar_forceHunted = CreateConVar("sm_hunted_forced", "0", "Forces Hunted mode on for all maps, including any map not defined in the config.", FCVAR_NONE, true, 0.0, true, 1.0);
		cvar_classLimits = CreateConVar("sm_hunted_rostertype", "default", "Determines the class restrictions for the mode.", FCVAR_NONE);

		LoadTranslations("common.phrases");
		LoadTranslations("hunted.phrases");
		
		HookConVarChange(cvar_forceHunted, CheckHuntedEnabled);
		HookConVarChange(cvar_classLimits, CheckClassLimits);

		RegisterAdminCmds();
	}

	public OnPluginEnd()
	{
		CurrentHunted = -1;
		PreviousHunted = -1;
	}

	public void Hunted_Start()
	{
		hunt_isEnabled = true;
		
		CurrentHunted = -1;
		PreviousHunted = -1;
		
		SetConVarInt(FindConVar("pf_allow_special_class"), 1);
		
		char val[64];
		FindConVar("sm_hunted_rostertype").GetString(val, sizeof(val));
		CheckClassLimits(FindConVar("sm_hunted_rostertype"), val, val);
		
		AddCommandListener(hook_VoiceMenu, "voicemenu"); 
		AddCommandListener(hook_DropItem, "dropitem"); 
		//AddCommandListener(hook_TextCommand, "say");
		
		HookEvent("teamplay_round_start", event_RoundStart);
		HookEvent("teamplay_round_win", event_RoundWin);
		HookEvent("player_spawn", event_PlayerRespawn);
		HookEvent("player_changeclass", event_ChangeClass);
		HookEvent("player_death", event_PlayerDeath);
		HookEvent("teamplay_flag_event", event_FlagEvent, EventHookMode_Pre);
		
		AddNormalSoundHook(HookSound);
		
		for ( int i = 1; i <= MaxClients; i++ )
		{
			if ( IsClientInGame(i) )
			{
				HookClient(i);
			}
		}
		
		PrintToServer("[HUNTED] Hooks hooked.");
		
		PrecacheScriptSound("Game.YourTeamWon");
		PrecacheScriptSound("Game.YourTeamLost");
		
		PrintToServer("[HUNTED] Successfully loaded!");
		//RegConsoleCmd("vote", HuntedVote);
		
		lastCivVoice = GetGameTime();

		CreateTimer(5.0, timer_NoHuntedWarning, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		CreateTimer(0.2, timer_ReturnIntel, INVALID_HANDLE, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
		
		// FastDL stuff here so we only download hunted-related stuff on relevant maps
		
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/vox_civdead.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/vox_civlocated_v2.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_spy.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_medic1.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_medic2.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_sniper1.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_sniper2.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_helpme1.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_helpme2.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_moveleft.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_moveright.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_go1.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_go2.mp3");
		AddFileToDownloadsTable("sound/vo/tsf_hunted_v1/civvy_thanks.mp3");
	}

	public void Hunted_Stop()
	{
		hunt_isEnabled = false;
		
		SetConVarInt(FindConVar("pf_allow_special_class"), 0);
		
		RemoveCommandListener(hook_VoiceMenu, "voicemenu"); 
		RemoveCommandListener(hook_DropItem, "dropitem"); 
		//RemoveCommandListener(hook_TextCommand, "say");
		
		UnhookEvent("teamplay_round_start", event_RoundStart);
		UnhookEvent("teamplay_round_win", event_RoundWin);
		UnhookEvent("player_spawn", event_PlayerRespawn);
		UnhookEvent("player_changeclass", event_ChangeClass);
		UnhookEvent("player_death", event_PlayerDeath);
		UnhookEvent("teamplay_flag_event", event_FlagEvent, EventHookMode_Pre);
		
		RemoveNormalSoundHook(HookSound);
		
		for ( int i = 1; i <= MaxClients; i++ )
		{
			if ( IsClientInGame(i) )
			{
				UnhookClient(i);
			}
		}
		
		PrintToServer("[HUNTED] Hooks unhooked.");
		
		PrintToServer("[HUNTED] Successfully unloaded!");
	}

	public void ReadRoster(char[] roster)
	{
		PrintToServer("[HUNTED] Loading roster '%s'", roster);
				
		char textPath[255];
		
		BuildPath(Path_SM, textPath, sizeof(textPath), "configs/hunted-limits.cfg");
		
		KeyValues kv = CreateKeyValues("MapList");
		
		if ( FileToKeyValues(kv, textPath) )
		{
			if ( KvJumpToKey(kv, roster, false) )
			{
				char teams[][] = { "red", "blue" };
				for ( int team = 0; team < 2; team++ )
				{
					KvJumpToKey(kv, teams[team], false);
					char strAmount[5];
					for ( int i = 0; i < ROSTERSIZE; i++ )
					{
						KvGetString(kv, classnames[i], strAmount, sizeof(strAmount), "0");
						currentRoster_limits[team][i] = StringToInt(strAmount);
						if ( StrContains(strAmount, "%", false) != -1 )
						{
							currentRoster_limitMode[team][i] = LIMIT_PERC;
							PrintToServer("Set percentage limit for %s (%i%%)", class_pnames[i+1], currentRoster_limits[team][i]);
						}
						else
						{
							currentRoster_limitMode[team][i] = LIMIT_EXACT;
							PrintToServer("Set exact limit for %s (%i)", class_pnames[i], currentRoster_limits[team][i]);
						}
						//currentRoster[0][i-1] = KvGetNum(kv, classnames[i], 0);
					}
					KvGoBack(kv);
				}
			}
			else if ( KvJumpToKey(kv, "modern", false) )
			{
				CloseHandle(kv);
				PrintToServer("[HUNTED] Unknown roster type '%s', loading default roster", roster);
				ReadRoster("modern");
				return;
			}
		}
		
		CloseHandle(kv);
	}

	public OnMapStart()
	{
		hunt_isEnabled = false;
		
		char mapName[128]; // [Py] surely there are no map names with more than 128 characters...
		GetCurrentMap(mapName, sizeof(mapName));
		
		char mapPrefix[8];
		strcopy(mapPrefix, 5, mapName);
		
		if ( !StrEqual(mapPrefix, "esc_", false) ) 
		{
			cvar_forceEnabled = FindConVar("sm_hunted_forced");
			if ( cvar_forceEnabled.IntValue != 1 )
			{
				PrintToServer("[HUNTED] %s is not a Hunted map. Not doing anything.", mapName);
				return;
			}
			PrintToServer("[HUNTED] sm_hunted_forced is on! Forcing plugin on...");
		}
		
		hunt_isEnabled = true;
		Hunted_Start();
	}

	public OnMapEnd()
	{
		CurrentHunted = -1;
		PreviousHunted = -1;
		Hunted_Stop();
	}
	
/*
================================================================================
	Utilities
================================================================================
*/

	void CleanupEngieBuildings()
	{
		int ent = -1;
		while ((ent = FindEntityByClassname(ent, "obj_*")) != -1)
		{
			int builder = GetEntPropEnt(ent, Prop_Send, "m_hBuilder");
			if ( builder < 1 || builder > MaxClients ) continue;
			RemoveEntity(ent);
		}
	}

	// Used to check if the client is on a team, and not a Spectator
	public bool:IsClientOnTeam(client)
	{
		if (client == -1 || client == 0)
			return false;

		if (IsClientConnected(client) && IsClientInGame(client))
		{
			new team = GetClientTeam(client);
			switch (team)
			{
				case 2:
					return true;
				case 3:
					return true;
				default:
					return false;
			}
		}

		return false;
	}

	// Used to check if the client actually is the Hunted by checking Class and Team.
	public bool IsPlayerHunted(client)
	{
		if ( client < 1 )
			return false;

		if ( IsClientConnected(client) && IsClientInGame(client) )
		{
			TFClassType class = TF2_GetPlayerClass(client);
			TFTeam team = TF2_GetClientTeam(client);

			if ( class == TFClass_Civilian && team == TFTeam_Blue && client == CurrentHunted )
			{
				return true;
			}

			return false;
		}
		
		return false;
	}

	// Set's a client's class and forces them to respawn
	public SetPlayerClass(int client, TFClassType class)
	{
		if ( !hunt_isEnabled )
			return;

		TF2_SetPlayerClass(client, class, false, true);
		TF2_RespawnPlayer(client);
	}
	
	public Action DisplayText(String:string[256], String:team[2])
	{
		new Text = CreateEntityByName("game_text_tf");
		DispatchKeyValue(Text, "message", string);
		DispatchKeyValue(Text, "display_to_team", team);
		DispatchKeyValue(Text, "icon", "leaderboard_dominated");
		DispatchKeyValue(Text, "targetname", "game_text1");
		DispatchKeyValue(Text, "background", team);
		DispatchKeyValue(Text, "spawnflags", "0");
		DispatchSpawn(Text);

		AcceptEntityInput(Text, "Display", Text, Text);

		CreateTimer(0.5, KillText, Text);
	}
	
	public Action DisplayTextToClient(int client, String:string[256], String:team[2], char icon[32])
	{
		new Text = CreateEntityByName("game_text_tf");
		DispatchKeyValue(Text, "message", string);
		DispatchKeyValue(Text, "display_to_team", team);
		DispatchKeyValue(Text, "icon", icon);
		DispatchKeyValue(Text, "targetname", "game_text1");
		DispatchKeyValue(Text, "background", team);
		DispatchKeyValue(Text, "spawnflags", "1");
		DispatchSpawn(Text);

		AcceptEntityInput(Text, "Display", client, client);

		CreateTimer(0.5, KillText, Text);
	}

	public Action:KillText(Handle:timer, any:ent)
	{
		if (IsValidEntity(ent))
			AcceptEntityInput(ent, "kill");

		return;
	}

	public PrintToTeamChat(client, const char[] txt)
	{
		for ( int i = 1; i <= MaxClients; i++ )
		{
			if ( IsClientInGame(i) && TF2_GetClientTeam(i) == TF2_GetClientTeam(client) )
			{
				PrintToChat(i, txt);
			}
		}
	}
	
	// Class-related Stuff

	int GetClassRatio(int team, int class)
	{
		int totalCount = GetTeamClientCount(view_as<int>(team == 0 ? TFTeam_Red : TFTeam_Blue));
		int altPerc = RoundToFloor( totalCount * (currentRoster_limits[team][class]/100.0) );
		if ( altPerc <= 0 ) return 1;
		return altPerc;
	}

	bool IsWithinLimit(int team, int class, int count)
	{
		if ( currentRoster_limits[team][class] <= -1 ) return true;
		if ( currentRoster_limits[team][class] == 0 ) return false;
		switch ( currentRoster_limitMode[team][class] )
		{
			case LIMIT_EXACT:
			{
				if ( count >= currentRoster_limits[team][class] )
				{
					return false;
				}
			}
			case LIMIT_PERC:
			{
				if ( count >= GetClassRatio(team, class) )
				{
					return false;
				}
				//PrintToChatAll("%i, %i, %i", totalCount, currentRoster_limits[team][class], altPerc);
			}
		}
		return true;
	}
	
/*
================================================================================
	Timers
================================================================================
*/

	public Action:timer_NoHuntedWarning(Handle:timer)
	{
		if ( !hunt_isEnabled )
		{
			KillTimer(timer);
			return;
		}

		if ( IsPlayerHunted(CurrentHunted) )
		{
			huntedWarns = 0;
			return;
		}

		if ( GetClientCount() == 0 || GetTeamClientCount(3) < 2 )
		{
			huntedWarns = 0;
			return;
		}

		char msg[256];

		if ( huntedWarns < 2 )
		{
			Format(msg, sizeof(msg), "Your team needs a Civilian! %i more warnings until a random Civilian is chosen...", 2-huntedWarns);
			DisplayText(msg, "3");
		}
		else
		{
			GetRandomHunted();
			Format(msg, sizeof(msg), "A random Civilian has been chosen!");
			DisplayText(msg, "3");
			huntedWarns = 0;
		}
		
		huntedWarns++;
	}

	public Action:timer_ReturnIntel(Handle:timer)
	{
		if ( CurrentHunted == -1 ) return;
		
		if ( !IsPlayerAlive(CurrentHunted) ) return;
		
		float origin[3];
		GetEntPropVector(CurrentHunted, Prop_Send, "m_vecOrigin", origin);
		
		if ( IsValidEntity(huntedFlag) )
		{
			TeleportEntity(huntedFlag, origin, NULL_VECTOR, NULL_VECTOR);
		}
	}

public CheckClassLimits(Handle:convar, char[] oldValue, char[] newValue)
{
	if ( StrEqual(newValue, "default") )
	{
		ReadRoster("modern");
	}
	else
	{
		ReadRoster(newValue);
	}
	RespawnPlayers();
}

public OnClientPutInServer(iClient)
{
	if ( hunt_isEnabled )
	{
		HookClient(iClient);
	}
}

/*
================================================================================
	Hooks
================================================================================
*/

	public void HookClient(iClient)
	{
		SDKHook(iClient, SDKHook_OnTakeDamage, OnTakeDamage);
	}

	public void UnhookClient(iClient)
	{
		SDKUnhook(iClient, SDKHook_OnTakeDamage, OnTakeDamage);
	}

	public OnClientDisconnect(client)
	{
		if ( !hunt_isEnabled ) return;
		
		if ( CurrentHunted == client )
		{
			CurrentHunted = -1;
			huntedWarns = 0;
		}
	}

	public Action:hook_DropItem(client, const String:command[], argc)
	{
		return Plugin_Handled;
	}

	public Action:hook_VoiceMenu(client, const String:command[], argc)
	{
		char starg1[32];
		char starg2[32];
		
		if ( !IsClientInGame(client) )
			return Plugin_Continue;
			
		if ( TF2_GetPlayerClass(client) != TFClass_Civilian )
		{
			return Plugin_Continue;
		}
			
		if ( GetGameTime() < lastCivVoice+1.0 )
		{
			return Plugin_Continue;
		}
			
		lastCivVoice = GetGameTime();

		GetCmdArg(1, starg1, sizeof(starg1));
		GetCmdArg(2, starg2, sizeof(starg2));
		
		int arg1 = StringToInt(starg1);
		int arg2 = StringToInt(starg2);
		
		char msg[255] = "\x07B6A8FF(Voice) %s\x07FFFFFF: %s";
		
		char name[64];
		GetClientName(client, name, sizeof(name));
		
		if ( StrEqual(civvy_commands[arg1][arg2], "", false) )
		{
			return Plugin_Handled;
		}
		
		char snd[64];
		char voicecmd[64];
		
		Format(voicecmd, sizeof(voicecmd), civvy_commands[arg1][arg2]);
		
		if ( StrEqual(civvy_lines[arg1][arg2][1], "", false) )
		{
			Format(snd, sizeof(snd), civvy_lines[arg1][arg2][0]);
		}
		else
		{
			Format(snd, sizeof(snd), civvy_lines[arg1][arg2][GetRandomInt(0,1)]);
		}
		
		Format(msg, sizeof(msg), msg, name, voicecmd);
		PrintToTeamChat(client, msg);
		
		if ( StrEqual(snd, "") )
		{
			return Plugin_Handled;
		}
		
		PrecacheSound(snd, true);
		EmitSoundToAll(snd, client, SNDCHAN_VOICE);

		return Plugin_Handled;
	}

	public Action:HookSound(clients[64], &numClients, String:sample[PLATFORM_MAX_PATH], &entity, &channel, &Float:volume, &level, &pitch, &flags)
	{
		if ( entity <= -1 ) return Plugin_Continue;
		
		char fuckname[256];
		GetEntityClassname(entity, fuckname, sizeof(fuckname));
		if ( StrEqual(fuckname, "item_teamflag", false) )
		{
			return Plugin_Handled;
		}
		return Plugin_Continue;
	}

	// [Py] Gives civvy some extra resistance to fire damage, kept around for reference
	
	public Action OnTakeDamage(int victim, int &attacker, int &inflictor, float &damage, int &damagetype, int &weapon, float damageForce[3], float damagePosition[3], int damagecustom)
	{
		if ( TF2_GetPlayerClass(victim) == TFClass_Civilian )
		{
			if ( damagecustom & DMG_BURN || damagecustom & DMG_IGNITE ) // [Py] should probably be damagetype BUT this info is in damagecustom so idk keep an eye on it I guess
			{
				damage *= 0.5;
				return Plugin_Changed;
			}
		}
		
		return Plugin_Changed;
	}
	
	// [Py] prevents non-civvys from interacting with capture points

	public Action OnStartTouchCapture(int entity, int client)
	{
		if ( client < 1 || client >= MaxClients ) // [Py] no non-players.... hopefully maybe
			return Plugin_Continue;
		
		if ( !IsClientInGame(client) || !IsPlayerAlive(client) )
			return Plugin_Continue;

		TFClassType class = TF2_GetPlayerClass(client);

		if (class != TFClass_Civilian)
		{
			return Plugin_Handled;
		}

		return Plugin_Continue;
	}


	public Action OnTouchWarningZone(int entity, int client)
	{
		if ( !roundActive ) return Plugin_Handled;
		
		if ( client < 1 || client > MaxClients ) return Plugin_Handled;
		
		TFClassType class = TF2_GetPlayerClass(client);
		if ( class != TFClass_Civilian )
		{
			return Plugin_Handled;
		}
		
		if ( huntedAlertDelay > GetGameTime() ) return Plugin_Handled;
		
		DisplayText("The Civilian is approaching the escape zone! Stop him!", "2");
		DisplayText("The Civilian is almost to the escape zone!", "3");
		PrecacheSound(VO_HUNTEDCLOSE, true);
		for ( int i = 1; i < MaxClients; i++ )
		{
			if ( IsClientConnected(i) && IsClientInGame(i) )
			{
				EmitSoundToClient(i, VO_HUNTEDCLOSE, _, 7, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, 100, _, NULL_VECTOR, NULL_VECTOR, false, 0.0);
			}
		}
		
		huntedAlertDelay = GetGameTime() + 7.0;

		return Plugin_Continue;
	}

	public Action OnTouchIntel(int entity, int client)
	{
		if ( client < 1 || client > MaxClients ) return Plugin_Continue;
		
		TFClassType class = TF2_GetPlayerClass(client);
		if ( class != TFClass_Civilian )
		{
			return Plugin_Handled;
		}

		return Plugin_Continue;
	}

/*
================================================================================
	Events
================================================================================
*/

	// [Py] silence all flag event stuff cause we don't need to see any of that
	public Action:event_FlagEvent(Event event, const char[] name, bool dontBroadcast)
	{
		event.BroadcastDisabled = true;
		return Plugin_Handled;
	}

	public Action event_ChangeClass(Event event, const String:name[], bool dontBroadcast)
	{
		if ( !hunt_isEnabled )
			return;

		int client = GetClientOfUserId(GetEventInt(event, "userid"));
		TFClassType class = view_as<TFClassType>(GetEventInt(event, "class"));

		if ( client == CurrentHunted && class != TFClass_Civilian )
		{
			PreviousHunted = CurrentHunted;
			CurrentHunted = -1;
			huntedWarns = 0;
		}
	}

	public Action:event_RoundStart(Handle:event, const String:name[], bool:dontBroadcast)
	{
		if ( GetClientCount() == 0 )
			return;

		GetRandomHunted();
		RespawnPlayers();

		//new String:Message[256];
		//Format(Message, sizeof(Message), "%T", "NewHunted", LANG_SERVER);
		//DisplayText(Message, "3");
		
		roundActive = true;
		
		int ent = -1;
		
		while ((ent = FindEntityByClassname(ent, "trigger_capture_area")) != -1)
		{
			SDKHook(ent, SDKHook_StartTouch, OnStartTouchCapture);
			//SetEntPropFloat(ent, Prop_Data, "m_flCapTime", 2.0);
		}
		
		ent = -1;
		
		while ((ent = FindEntityByClassname(ent, "func_respawnroom")) != -1)
		{
			SetEntProp(ent, Prop_Data, "m_bFlagShouldBeDropped", 0);
		}
		
		ent = -1;
		
		while ((ent = FindEntityByClassname(ent, "trigger_multiple")) != -1)
		{
			char targetname[64];
			GetEntPropString(ent, Prop_Data, "m_iName", targetname, sizeof(targetname));
			if ( StrEqual(targetname, "escape_warn") )
			{
				SDKHook(ent, SDKHook_StartTouch, OnTouchWarningZone);
			}
			//SetEntPropFloat(ent, Prop_Data, "m_flCapTime", 2.0);
		}
	}

	public Action:event_RoundWin(Handle:event, const String:name[], bool:dontBroadcast)
	{
		roundActive = false;
	}

	// Checks to see if the Hunted has died, and if so it announces the killer,
	// sets everyone to respawn when the Hunted does, and gives the Assassins
	// a team point. I am considering adding a psuedo-Humiliation mode here,
	// but right now I don't want to have it.
	//
	// Removed player respawning if the killer is the Hunted or Worldspawn,
	// IE suicide, falling from a ledge, etc. This prevents people from spamming
	// "Hunted Change" to grief, and to fix the exploit of changing Hunteds right
	// before setup ends, allowing Blue easier capping of the first point on multi
	// stage maps like Dustbowl.

	public Action:event_PlayerDeath(Handle:event, const String:name[], bool:dontBroadcast)
	{
		int victim = GetClientOfUserId(GetEventInt(event, "userid"));
		int killer = GetClientOfUserId(GetEventInt(event, "attacker"));
		int assister = GetClientOfUserId(GetEventInt(event, "assister"));

		char msg[256];
		
		if ( victim == CurrentHunted )
		{
			if ( killer == 0 || killer == CurrentHunted )
			{
				DisplayText("The Civilian has died of natural causes!", "3");

				if (!IsPlayerHunted(CurrentHunted))
				{
					PreviousHunted = CurrentHunted;
					CurrentHunted = -1;
				}
			}
			else
			{
				new String:KillerName[256];
				GetClientName(killer, KillerName, sizeof(KillerName));

				IsHuntedDead = true;
				huntedWarns = 0;

				new Score = GetTeamScore(2);
				Score += 1;
				SetTeamScore(2, Score);

				if ( assister == 0 )
				{
					Format(msg, sizeof(msg), "%s killed the Civilian!\nPrepare to respawn...", KillerName);
				}
				else
				{
					char AssisterName[256];
					GetClientName(assister, AssisterName, sizeof(AssisterName));

					Format(msg, sizeof(msg), "%s and %s killed the Civilian!\nPrepare to respawn...", KillerName, AssisterName);
				}

				DisplayText(msg, "0");

				if ( roundActive )
				{
					PrecacheSound(VO_HUNTEDDEAD, true);
					for ( int i = 1; i < MaxClients; i++ )
					{
						if ( IsClientConnected(i) && IsClientInGame(i) )
						{
							EmitSoundToClient(i, VO_HUNTEDDEAD, _, 7, SNDLEVEL_NORMAL, SND_NOFLAGS, SNDVOL_NORMAL, 100, _, NULL_VECTOR, NULL_VECTOR, false, 0.0);
						}
					}
				}
			}

			huntedWarns = 0;
		}
	}

	// Checks to see if 1.) the Hunted has died, and 2.) if the Hunted respawns
	// it forces all players to respawn. It also does another MasterPlayerCheck
	// to make sure nobody has tried to pull any shenanigans for changing class.

	public Action:event_PlayerRespawn(Handle:event, const String:name[], bool:dontBroadcast)
	{
		if ( !hunt_isEnabled ) return;

		new client = GetClientOfUserId(GetEventInt(event, "userid"));
		
		if ( !IsClientConnected(client) && !IsClientInGame(client) )
			return;

		if ( CurrentHunted == client && IsHuntedDead )
		{
			RespawnPlayers();
			IsHuntedDead = false;
		}

		if (client == CurrentHunted && !IsPlayerHunted(CurrentHunted))
		{
			PreviousHunted = CurrentHunted;
			CurrentHunted = -1;
			huntedWarns = 0;
		}
		
		MasterCheckPlayer(client);
	}
	
/*
================================================================================
================================================================================
*/

	public CheckHuntedEnabled(Handle:convar, const String:oldValue[], const String:newValue[])
	{
		if ( StringToInt(newValue) == 1 && !hunt_isEnabled )
		{
			Hunted_Start();
			GetRandomHunted();
			RespawnPlayers();
		}
		else if ( StringToInt(newValue) == 0 && hunt_isEnabled )
		{
			Hunted_Stop();
		}
	}

	public SetNewHunted(client)
	{
		PreviousHunted = CurrentHunted;
		CurrentHunted = client;
		TF2_ChangeClientTeam(CurrentHunted, TFTeam_Blue);
		TF2_SetPlayerClass(CurrentHunted, TFClass_Civilian);
		TF2_RespawnPlayer(client);
		RespawnPlayers();

		new String:name[MAX_NAME_LENGTH];
		GetClientName(CurrentHunted, name, sizeof(name));

		PrintToChatAll("%s is now the Civilian!", name);
	}

	// Randomly selects a new Hunted from the Blue team.
	public GetRandomHunted()
	{
		int maxplayers = MaxClients;

		decl Bodyguards[maxplayers];
		new team;
		new index = 0;
		
		if ( GetClientCount() == 0 || GetTeamClientCount(3) < 2 )
		{
			huntedWarns = 0;
			return;
		}

		for ( int i = 1; i <= maxplayers; i++ )
		{
			if (IsClientConnected(i) && IsClientInGame(i))
			{
				team = GetClientTeam(i);
				if (team == 3 && i != CurrentHunted)
				{
					Bodyguards[index] = i;
					index++;
				}
			}
		}

		int rand = GetRandomInt(0, index - 1);
		if ( Bodyguards[rand] < 1 || !IsClientConnected(Bodyguards[rand]) || !IsClientInGame(Bodyguards[rand]) )
		{
			huntedWarns = 0;
			return;
		}
		else
		{
			PreviousHunted = CurrentHunted;
			CurrentHunted = Bodyguards[rand];
			TF2_ChangeClientTeam(CurrentHunted, TFTeam_Blue);
			SetPlayerClass(CurrentHunted, TFClass_Civilian);
		}
	}

	// Respawns all players, except the Hunted. The Hunted is not respawned because
	// it throws the plugin into an endless loop. This is used when the Hunted
	// respawns normally, so there is no real need to respawn him again.

	public RespawnPlayers()
	{
		if (GetClientCount() < 1)
			return;
			
		CleanupEngieBuildings();

		new maxplayers = MaxClients;
		
		for (new i = 1; i <= maxplayers; i++)
		{
			if ( i == CurrentHunted ) continue;
			if ( IsClientConnected(i) && IsClientInGame(i) && IsClientOnTeam(i) )
			{
				TF2_RespawnPlayer(i);
			}
		}

		new RedCount = GetTeamClientCount(2);
		new BlueCount = GetTeamClientCount(3);

		if (BlueCount < 2)
			return;

		if (RedCount > BlueCount)
		{
			decl Assassins[maxplayers];
			new index = 0;
			new team;

			for (new i = 1; i <= maxplayers; i++)
			{
				if (IsClientConnected(i) && IsClientInGame(i))
				{
					team = GetClientTeam(i);
					if (team == 2)
					{
						Assassins[index] = i;
						index += 1;
					}
				}
			}

			new rand;
			while (GetTeamClientCount(2) > GetTeamClientCount(3))
			{
				rand = GetRandomInt(0, index - 1);

				team = GetClientTeam(Assassins[rand]);
				if (team == 2 && IsClientConnected(Assassins[rand]) && IsClientInGame(Assassins[rand]) && IsClientOnTeam(Assassins[rand]))
				{
					TF2_ChangeClientTeam(Assassins[rand], TFTeam_Red);
					TF2_RespawnPlayer(Assassins[rand]);
					char name[64];
					GetClientName(Assassins[rand], name, sizeof(name));
					PrintToChatAll("%s has been moved to RED to balance the teams.", name);
				}
			}
		}
	}

	public MasterCheckPlayer(client)
	{
		if ( !hunt_isEnabled )
			return;

		TFClassType class = TF2_GetPlayerClass(client);
		TFTeam team = TF2_GetClientTeam(client);
		
		if ( !IsPlayerHunted(CurrentHunted) )
		{
			PreviousHunted = CurrentHunted;
			CurrentHunted = -1;
		}
		
		if ( team == TFTeam_Blue && class == TFClass_Civilian )
		{
			bool giveFlag = false;
			
			if ( PreviousHunted == client )
			{
				PrintToChat(client, "\x07FFFFFF---");
				PrintToChat(client, "\x076E91A6Please wait before trying to select the \x076E91A6Civilian\x07FFA74D again.");
				PrintToChat(client, "\x07FFFFFF---");
			}
			else if ( CurrentHunted <= 0 )
			{
				CurrentHunted = client;
				DisplayTextToClient(client, "You are the Civilian!\nMake it to the escape zone alive!", "3", "leaderboard_dominated");
				PrintToChat(client, "\x07FFFFFF---");
				PrintToChat(client, "\x07FFFFFF[ CIVILIAN TIPS ]");
				PrintToChat(client, "\x076E91A6-\x07FFA74D Work with your team to stay alive and reach the escape zone!");
				PrintToChat(client, "\x076E91A6-\x07FFA74D Your 'Incoming' voice command is replaced with 'Sniper!'");
				PrintToChat(client, "\x07FFFFFF---");
				
				giveFlag = true;
			}
			else if ( CurrentHunted == client ) // [Py] If you're already civvy
			{
				giveFlag = true;
			}
			
			if ( giveFlag )
			{
				if ( IsValidEntity(huntedFlag) )
				{
					AcceptEntityInput(huntedFlag, "Kill");
				}
				
				int ent = CreateEntityByName("item_teamflag");
				if ( ent == -1 ) return;
				DispatchKeyValue(ent, "targetname", "hunted_outline");
				SDKHook(ent, SDKHook_Touch, OnTouchIntel);
				DispatchKeyValue(ent, "flag_model", "models/empty.mdl");
				DispatchKeyValue(ent, "ReturnTime", "0");
				DispatchSpawn(ent);
				SetVariantInt(2);
				AcceptEntityInput(ent, "SetTeam");
				
				huntedFlag = ent;
				
				return;
			}
		}
		
		VerifyClass(client);
	}

	public VerifyClass(client)
	{
		int curClass = view_as<int>(TF2_GetPlayerClass(client))-1;
		if ( curClass == -1 ) return;
		
		int team = TF2_GetClientTeam(client) == TFTeam_Blue ? 1 : 0;
		char teamName[2][] = { "RED", "BLU" };
		
		int classCount[ROSTERSIZE] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0};
		
		for ( int plr = 1; plr <= MaxClients; plr++ )
		{
			if ( client == plr ) continue;
			if ( IsClientInGame(plr) && TF2_GetClientTeam(plr) == TF2_GetClientTeam(client) && TF2_GetPlayerClass(plr) != TFClass_Unknown )
			{
				classCount[view_as<int>(TF2_GetPlayerClass(plr))-1] += 1;
			}
		}
		
		bool isInvalid = false;
		
		char msg[255];
		char textColor1[2][] = { "\x07FF8D4D", "\x07FFA74D" };
		char textColor2[2][] = { "\x07DB4747", "\x076E91A6" };
		
		if ( currentRoster_limits[team][curClass] == 0  )
		{
			isInvalid = true;
			Format(msg, sizeof(msg), "%s is not available on %s!", class_pnames[curClass], teamName[team]);
		}
		else if ( !IsWithinLimit(team, curClass, classCount[curClass]) )
		{
			isInvalid = true;
			if ( currentRoster_limits[team][curClass] == 1 )
			{
				Format(msg, sizeof(msg), "%s already has a %s!", teamName[team], class_pnames[curClass]);
			}
			else
			{
				Format(msg, sizeof(msg), "There's too many people playing %s on %s!", class_pnames[curClass], teamName[team]);
			}
		}
		
		if ( !isInvalid ) return;
		
		//PrintToChat(client, msg);
		DisplayTextToClient(client, msg, team == 0 ? "2" : "3", "voice_self");
		
		char goodClasses[255] = "";
		
		int randomClasses[ROSTERSIZE] = {-1, -1, -1, -1, -1, -1, -1, -1, -1, -1};
		int maxRandom = 0;
		
		for ( int i = 0; i < 10; i++ )
		{
			if ( currentRoster_limits[team][i] == 0 ) continue;
			char class[255] = "";
			char className[32];
			if ( currentRoster_limits[team][i] > 0 )
			{
				switch ( currentRoster_limitMode[team][i] )
				{
					case LIMIT_EXACT:
					{
						Format(className, sizeof(className), "%s (%i)", class_pnames[i], currentRoster_limits[team][i]);
					}
					case LIMIT_PERC:
					{
						Format(className, sizeof(className), "%s (%i*)", class_pnames[i], GetClassRatio(team, i));
					}
				}
			}
			else
			{
				Format(className, sizeof(className), "%s", class_pnames[i]);
			}
			if ( StrEqual(goodClasses, "") )
			{
				Format(class, sizeof(class), "%s", className);
			}
			else
			{
				Format(class, sizeof(class), ", %s", className);
			}
			StrCat(goodClasses, sizeof(goodClasses), class);
			if ( IsWithinLimit(team, i, classCount[i]) )
			{
				randomClasses[maxRandom] = i+1;
				maxRandom += 1;
			}
		}
		
		if ( team == 0 )
		{
			Format(msg, sizeof(msg), "\x07FF8D4DAs an Assassin, you can play as: \x07DB4747%s", goodClasses);
		}
		else
		{
			Format(msg, sizeof(msg), "\x07FFA74DAs a Bodyguard, you can play as: \x076E91A6%s", goodClasses);
		}
		
		PrintToChat(client, "\x07FFFFFF---");
		PrintToChat(client, msg);
		/*if ( curClass == view_as<int>(TFClass_Civilian)-1 )
		{
			PrintToChat(client, "%sIf you'd like to nominate yourself to replace the current Civilian, type %s!civvy%s in chat.", textColor1[team], textColor2[team], textColor1[team]);
		}*/
		PrintToChat(client, "\x07FFFFFF---");
		
		int randyClass = randomClasses[GetRandomInt(0, maxRandom-1)];
		SetPlayerClass(client, view_as<TFClassType>(randyClass));
	}

	public DestroyEpicFlag(const char[] output, int caller, int activator, float delay)
	{
		AcceptEntityInput(caller, "Kill");
	}
	
/*
================================================================================
	Third-party shite
================================================================================
*/
	
	// [Py] disable goomba stomp forever and ever and ever
	public Action OnStomp(int attacker, int victim)
	{
		if ( !hunt_isEnabled ) return Plugin_Continue;
		
		return Plugin_Handled;
	}