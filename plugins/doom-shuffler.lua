local plugin = {}

plugin.name = "Doom Damage Shuffler"
plugin.author = "Shadow Hog"
plugin.minversion = "2.11.1"
plugin.settings =
{
	{ name='envDamageSwap', type='boolean', label='Swap on environmental damage (floors/ceilings)', default=false},
	{ name='SuppressLog', type='boolean', label='Suppress debug logs', default=true},
	{ name='grace', type='number', label="Minimum grace period before swapping (won't go < 6 frames)", default=35 },
	{ name='GraceOnHit', type='boolean', label="Apply grace period from last hit instead of last swap", default=true },
	{ name='DebugSingleGame', type='boolean', label='Debugging: Rearm the shuffler logic even if no new game was loaded' },
}

plugin.description =
[[
	This is a mod of the excellent Mega Man Damage Shuffler plugin by authorblues and kalimag.
	This adds support for BizHawk's DSSA-Doom core. You will be swapped to a different game upon taking damage.

	YOU WILL NEED BIZHAWK 2.11.1 MINIMUM!

	----SUPPORTED GAMES----
	Any game supported by the DSDA-Doom core. Prominent examples include:
	- DOOM1.WAD (Doom (shareware))
	- DOOM.WAD (Doom (registered), The Ultimate Doom)
	- DOOM2.WAD (Doom II: Hell on Earth)
	- TNT.WAD (Final Doom: TNT: Evilution)
	- PLUTONIA.WAD (Final Doom: The Plutonia Experiment)
	- HERETIC1.WAD (Heretic (shareware))
	- HERETIC.WAD (Heretic (registered), Heretic: Shadow of the Serpent Riders)
	- HEXEN.WAD (Hexen: Beyond Heretic (shareware and registered))
	Also many custom WAD files for the above.

	----PREPARATION----
	Set Min and Max Seconds VERY HIGH, assuming you don't want time swaps in addition to damage swaps.

	To load an IWAD (the WAD file that contains all the data the game needs), simply put the WAD in the folder for games to shuffle. This includes DOOM.WAD, DOOM2.WAD, TNT.WAD, PLUTONIA.WAD, HERETIC.WAD and HEXEN.WAD, at the very least.

	To load a PWAD (patch WAD files made by fans, containing modifications like new levels, graphics, sounds and so on, but which generally require an IWAD to be loaded first) for Doom 2, you can just put the PWAD into your shuffled games folder (provided you set up DOOM2.WAD in BizHawk's Firmware settings).

	To load a PWAD that ISN'T for Doom 2, or to load multiple PWADs at once for a single "game", you should use BizHawk's Multi-Disk Bundler tool (under the Tools bar):

	1. If the IWAD isn't Doom 2, set the relevant IWAD as the first entry. (If it is, you CAN set DOOM2.WAD as the first entry, or you can set it up as a Firmware and only load PWADs in this tool.)
	2. Set any desired PWADs as subsequent entries.
	3. Set the System value to "Doom".
	4. Save the resulting XML in your shuffled games folder.

	Ideally, when using the Multi-Disk Bundler tool, make sure the paths to the WAD files are absolute, or else relative to your shuffled games folder's location. If not, BizHawk may not be able to locate the WAD files when it comes time to run them.

	Note that the compatibility of PWADs is, at the latest, MBF21 (or possibly ID24?). If you don't know what that means: generally, if the mod requires UZDoom or Eternity Engine, it is NOT compatible. Otherwise, it probably is.

	The Doom core behaves like you are recording a demo in the original executable, and thus throws you right into the thick of things on MAP01 (or ExM1, where x is the selected Episode in the core's Sync Settings) and does not offer the option to open the pause menu. Be prepared for that in the case of a hot start.

	For games with episodes (e.g.: Doom 1/Ultimate Doom or Heretic), it is suggested you set the core's Sync Setting for continuous episodic play to "On", so clearing one episode immediately starts up the next. Note that this might put you at the start of each episode with weapons you aren't supposed to have; the plugin author has not yet tested this. The alternative is to make a separate XML for each episode of the WAD, and use the Shuffler's start-states feature to load each relevant episode with a pistol start (you will have to make the states yourself by playing with the starting episode/map Sync Settings, then savestating the instant the core loads).

	Note that there is a known issue with savestate size for particularly large and detailed maps - nuts.wad is cited as having saves almost half a gigabyte in size, for instance - and there is a non-zero chance of the emulator crashing outright if that savestate balloons to 4 gigabytes in size, the limit of the waterbox the core is built around. It is recommended you use relatively sane maps as a result, and not huge slaughtermaps. The plugin author has not experimented with larger non-slaughtermap levels like Alien Vendetta's MAP20, "Misri Halek", however.

	----OPTIONS----

	Swap on environmental damage: If this is set to false, only damage with an internally-assigned attacker will allow a swap. This is NULL for floor/ceiling damage, so essentially, swaps will never occur for nukage or crushers. If set to true, this criteria is ignored, and these will trigger swaps like any other damage would.

	Suppress debug logs: If toggled, does not print any of the debug logs intended more for the developers of the plugin than for end users. Disable this if you're really curious, just note it will flood your log file.

	Minimum grace period before swapping: Minimum number of frames (at 35Hz) that must pass before damage taken will shuffle. 35 frames (one second exactly) is the default. Adjust up or down as desired. This idea originated in the TownEater fork of the damage shuffler!

	Apply grace period from last hit instead of last swap: Alters the behavior of how grace is counted:
	- If unchecked, any damage after the first n frames of the game being swapped to damage will swap games.
	- If checked, any damage taken within the first n frames of the game being swapped to resets the count. Effectively, you must go n frames without taking any damage before swaps will be registered.
	Defaults to checked. Unchecking it is not recommended (Chaingunners exist).

	Enjoy? Send bug reports?

]]

---@enum game_state
GameState = {
	LEVEL        = 0,
	INTERMISSION = 1,
	FINALE       = 2,
	DEMOSCREEN   = 3
}

--local tags = {}
--local tag
--local gamemeta
local prevdata
local debug_timer
local last_hit
local swap_scheduled
local shouldSwap
--local gamesleft
local prev_framecount

-- update value in prevdata and return whether the value has changed, new value, and old value
-- value is only considered changed if it wasn't nil before
local function update_prev(key, value)
	if key == nil or value == nil then
		error("update_prev requires both a key and a value")
	end
	local prev_value = prevdata[key]
	prevdata[key] = value
	local changed = prev_value ~= nil and value ~= prev_value
	return changed, value, prev_value
end

local function doom_swap()
	return function(data)
		-- If a swap is already scheduled, decrease it but do no further processing.
		if data.delayCountdown ~= nil and data.delayCountdown > 0 then
			--log_console("delayCountdown: %d", data.delayCountdown)
			data.delayCountdown = data.delayCountdown - 1
			if data.delayCountdown == 0 then
				--console.log("delayCountdown is 0; swapping");
				return true;
			end
			return false;
		end

		local gameStateChanged, gameState, prevGameState = update_prev("GameState", structs.globals.gamestate)
		if gameState == GameState.LEVEL then
			local player1 = structs.globals.players[1]
			local bHealthChanged, dHealth, dPrevHealth = update_prev("p1HP", player1.mo.health)
			local bArmor1Changed, dArmor1, dPrevArmor1 = update_prev("p1Armor1", player1.armorpoints[1])
			local bArmor2Changed, dArmor2, dPrevArmor2 = update_prev("p1Armor2", player1.armorpoints[2])
			local bArmor3Changed, dArmor3, dPrevArmor3 = update_prev("p1Armor3", player1.armorpoints[3])
			local bArmor4Changed, dArmor4, dPrevArmor4 = update_prev("p1Armor4", player1.armorpoints[4])
			local bAttackerChanged, pAttacker, pPrevAttacker = update_prev("p1Attacker", tostring(player1.attacker))
			if pAttacker ~= "nil" -- Can't be slime or crusher
					and ( -- One of the below must be true
							(bHealthChanged and dHealth < dPrevHealth)
							or (bArmor1Changed and dArmor1 < dPrevArmor1)
							or (structs.globals.hexen and ( -- Only check armors 2-4 in Hexen; no other game uses them
								(bArmor2Changed and dArmor2 < dPrevArmor2)
								or (bArmor3Changed and dArmor3 < dPrevArmor3)
								or (bArmor4Changed and dArmor4 < dPrevArmor4)
							))
					) then
				data.delayCountdown = 2 -- 2/35 is just a smidgen larger than 3/60
			end
		end
		return false
	end
end

function plugin.on_game_load(data, settings)
	prevdata = {}
	debug_timer = 0
	last_hit = 0
	swap_scheduled = false
	shouldSwap = function() return false end

	prev_framecount = emu.framecount()

	local systemID = emu.getsystemid();
	local isDoom = (systemID == "Doom");

	if isDoom then
		log_console('Doom Damage Shuffler: current core is Doom')
		if structs == nil then
			structs = require("Doom.dsda.structs")
		end
		shouldSwap = doom_swap()
	elseif not settings.SuppressLog then
		log_console('Doom Damage Shuffler: current core is not Doom (%s)', systemID)
	end
end

function plugin.on_frame(data, settings)
	-- Detect resets, savestate load or rewind (or turbo if "Run lua scripts when turboing" is disabled)
	local inputs = joypad.get()
	local new_framecount = emu.framecount()
	if inputs.Reset or inputs.Power or new_framecount ~= prev_framecount + 1 then
		prevdata = {} -- reset prevdata to avoid swaps
	end
	prev_framecount = new_framecount

	-- avoiding super short swaps (<(6/35) seconds, just a smidgen longer than (10/60) seconds) as a precaution
	local grace = math.max(settings.grace or 0, 6)
	
	if settings.DebugSingleGame and swap_scheduled then
		-- rearm the shuffler even though no on_game_load happened to reset things
		if frames_since_restart - 1 >= debug_timer then
			prevdata = {}
			last_hit = frames_since_restart - 1
			swap_scheduled = false
		end
	end
	
	-- run the check method for each individual game
	
	if not swap_scheduled then
	
		-- PROCESS "DON'T SWAP" SETTINGS HERE
		-- A function like this should be generalizable for other games in the future to make exceptions 
		-- so that users can turn off specific swap conditions
		-- laid out by a DisableExtraSwaps function

		-- AND NOW WE SWAP
		local schedule_swap, delay = shouldSwap(prevdata)
		--[[if schedule_swap and frames_since_restart > grace then
			delay = delay or 3
			debug_timer = -delay
			swap_game_delay(delay)
			swap_scheduled = true
			if not settings.SuppressLog or settings.DebugSingleGame then
				log_console('Doom Shuffler: swap scheduled for %s (frame: %d, delay: %d)', tag, frames_since_restart, delay)
			end
			if PAUSE_ON_SWAP then client.pause() end
		end]]
		if schedule_swap then
			if frames_since_restart > last_hit + grace then
				delay = delay or 3
				debug_timer = frames_since_restart + delay
				swap_game_delay(delay)
				swap_scheduled = true
				if not settings.SuppressLog or settings.DebugSingleGame then
					log_console('Doom Shuffler: swap scheduled for %s (frame: %d, delay: %d)', tag, frames_since_restart, delay)
				end
				if PAUSE_ON_SWAP then client.pause() end
			else
				log_debug('Doom Shuffler: swap blocked (grace) for %s (frame: %d, grace: %d)', tag, frames_since_restart, grace)
				--if settings.GraceOnHit then
					last_hit = frames_since_restart
				--end
			end
		end
	end
end

return plugin