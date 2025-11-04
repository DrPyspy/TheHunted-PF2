/*
	[Py] various admin/operator commands
*/

public RegisterAdminCmds()
{
	RegAdminCmd("sm_hunted_set", cmd_SetPlayerHunted, ADMFLAG_KICK, "Manually set the Civilian to a specific player using their name|ClientID");
	RegAdminCmd("sm_hunted_respawn", cmd_RespawnHunted, ADMFLAG_KICK, "Respawns all players.");
	//RegAdminCmd("sm_hunted_random", cmd_ForceHunted, ADMFLAG_KICK, "Forces a random player to be the Civilian, respawning all players accordingly.");
}

// ADMIN FUNCTION - Force a given player to be the Hunted
public Action:cmd_SetPlayerHunted(client, args)
{
	new String:arg1[32];
	GetCmdArg(1, arg1, sizeof(arg1));
	
	new client = GetClientOfUserId(client);

	new target = FindTarget(client, arg1);
	if (target == -1)
		return Plugin_Handled;

	SetNewHunted(target);
	
	//PrintToConsole(client, "[HUNTED] %s was forced as the Civilian.", name);
	return Plugin_Handled;
}

// ADMIN FUNCTION - Respawn all players
public Action:cmd_RespawnHunted(client, args)
{
	RespawnPlayers();
	return Plugin_Handled;
}

// ADMIN FUNCTION - Force reset of all players, and choose a random Hunted
public Action:cmd_ForceHunted(client, args)
{
	GetRandomHunted();
	RespawnPlayers();

	PrintToChatAll("[HUNTED] %T", "NewHunted", LANG_SERVER);
	PrintToConsole(client, "[HUNTED] %t", "NewHunted");
	return Plugin_Handled;
}