local token = minetest.settings:get('telegram.token')
local chat_id = minetest.settings:get('telegram.chat_id')

if not token then
	error("Rotor add telegram.token in your minetest.conf.")
end
if not chat_id then
	error("Rotor add telegram.chat_id in your minetest.conf.")
end

local http_api = minetest.request_http_api()

if http_api == nil then
	error('Please give permission to perform HTTP requests. Please add `secure.http_mods = "minetesttgbridge"` to your minetest.conf.')
end


local api_url = 'https://api.telegram.org/bot'..token..'/'
local long_polling_timeout = 300
local latest_update = 0


function getUpdates()
	if not minetest.settings:get_bool('telegram.receive', true) then
		minetest.after(60, getUpdates)
		return
	end
	minetest.log('verbose', "getUpdates with offset = "..latest_update)
	http_api.fetch({
		url = api_url..'getUpdates',
		post_data = {
			offset = latest_update,
			timeout = long_polling_timeout,
			allowed_updates = '["message", "edited_message"]'
		},
		timeout = long_polling_timeout + 10
	}, function (result)
		if result.succeeded and result.code == 200 then
			local success, parsed = pcall(minetest.parse_json, result.data)
			if not success then
				minetest.log('error', "parsing json failed: "..parsed)
				minetest.log('verbose', result.data)

				local next_updateid = latest_update
				if latest_update == 0 then
					next_updateid = tonumber(result.data:match('"update_id":([0-9]+)'))
					if next_updateid == nil then
						minetest.after(10, getUpdates)
						return
					end
				end

				next_updateid = next_updateid + 1
				minetest.log('verbose', "Trying to skip to next message. (requested: "..latest_update.."; next: "..next_updateid..")")
				latest_update = next_updateid
				minetest.after(1, getUpdates)
				return
			end

			for _,update in pairs(parsed.result) do
				if update.update_id >= latest_update then
					minetest.log('verbose', "New update available from Telegram.")
					latest_update = update.update_id + 1
					if update.message ~= nil then
						local message = update.message
						if message.text then
							local name = message.from.username or message.from.first_name or message.from.id
							minetest.chat_send_all(name..': '..message.text)
							parseCommands(name, message.text)
						end
					elseif update.edited_message ~= nil then
						local message = update.edited_message
						if message.text then
							local name = message.from.username or message.from.first_name or message.from.id
							minetest.chat_send_all(name..': *'..message.text)
						end
					else
						minetest.log('warning', "Unsupported update type:\n"..dump(update))
					end
				end
			end
			minetest.after(1, getUpdates)
		elseif result.timeout then
			minetest.log('warning', 'Connection to Telegram timed out...')
			minetest.after(1, getUpdates)
		elseif result.code == 409 then
			minetest.log('warning', "Connection limited!")
			minetest.after(10, getUpdates)
		else
			minetest.log('error', 'Could not receive updates from Telegram!')
			minetest.after(10, getUpdates)
		end
	end)
end


chatcommands = {
	help = {
		description = "Get help for commands",
		func = function(name, param)
			local reply = "Available commands:\n"
			for cmd, def in pairs(chatcommands) do
				reply = reply..'/'..cmd
				if def.params and def.params ~= nil then
					reply = reply..' '..def.params
				end
				if def.description and def.description ~= nil then
					reply = reply..': '.. def.description
				end
				reply = reply..'\n'
			end
			sendMessage(reply, true)
		end,
	},
	list_players = {
		description = "List online players",
		func = function(name, param)
			local players = minetest.get_connected_players()
			if #players == 0 then
				sendMessage("No players are currently connected.", true)
				return
			end

			local reply = "Connected players:\n"
			for _,player in pairs(minetest.get_connected_players()) do
				reply = reply..'- '..player:get_player_name()..'\n'
			end
			minetest.chat_send_all(reply)
			sendMessage(reply, true)
		end
	},
}


function parseCommands(name, message)
	if message:sub(1, 1) ~="/" then
		return
	end

	local cmd, param = string.match(message, "^/([^ @]+)[^ ]* *(.*)$")
	if not cmd then
		sendMessage("-!- Empty command", true)
		return
	end

	local cmd_def = chatcommands[cmd]
	if not cmd_def then
		sendMessage("-!- Invalid command", true)
		return
	end

	local result = cmd_def.func(name, param)
	if result then
		sendMessage(result, true)
	end
end


function sanitize_markdown(text)
	-- escapes all markdown special characters
        local sanitized, _ = text:gsub('([_*%[%]%(%)~`>#%+-=%|%{%}%.%!])', '\\%1')
	return sanitized
end


function sendMessage(text, disable_notification, parse_mode, callback)
	disable_notification = disable_notification or false
	parse_mode = parse_mode or 'none'
	callback = callback or default_callback
	http_api.fetch({
		url = api_url..'sendMessage',
		post_data = {
			chat_id = chat_id,
			text = text,
			disable_notification = tostring(disable_notification),
			parse_mode = parse_mode
		}
	}, callback)
end


function default_callback(result)
	if result.succeeded and result.code == 200 then
		local parsed = minetest.parse_json(result.data)
		minetest.log('verbose', "Message sent: "..parsed.result.text)
	elseif result.data and result.data ~= "" then
		local parsed = minetest.parse_json(result.data)
		minetest.log('error', "API error: "..(dump(parsed):gsub('\n', ' ')))
	else
		minetest.log('error', "HTTP error: "..(dump(result):gsub('\n', ' ')))
	end
end


function startup()
	if minetest.settings:get_bool('telegram.announce_startup', true) then
		local dnd = minetest.settings:get_bool('telegram.announce_startup.dnd', false)
		sendMessage("Hemlo! The server is online now.", dnd)
	end
end


function join(player)
	if minetest.settings:get_bool('telegram.announce_join', true) then
		local dnd = minetest.settings:get_bool('telegram.announce_join.dnd', false)
		local name = '*'..sanitize_markdown(player:get_player_name())..'*'
		sendMessage(name.." joined the server\\.", dnd, 'MarkdownV2')
	end
end


function chat(name, message)
	if minetest.settings:get_bool('telegram.send', true) then
		local dnd = minetest.settings:get_bool('telegram.send.dnd', false)
		name = '*'..sanitize_markdown(name)..'*'
		sendMessage(name.." said: "..sanitize_markdown(message)..'\\.', dnd, 'MarkdownV2')
	end
end


function dead(player)
	if minetest.settings:get_bool('telegram.announce_dead', true) then
		local dnd = minetest.settings:get_bool('telegram.announce_dead.dnd', true)
		local name = "*"..sanitize_markdown(player:get_player_name()).."*"
		sendMessage(name.." died\\.", dnd, 'MarkdownV2')
	end
end


function leave(player)
	if minetest.settings:get_bool('telegram.announce_leave', true) then
		local dnd = minetest.settings:get_bool('telegram.announce_leave.dnd', true)
		local name = '*'..sanitize_markdown(player:get_player_name())..'*'
		sendMessage(name.." left the server\\.", dnd, 'MarkdownV2')
	end
end


function shutdown()
	if minetest.settings:get_bool('telegram.announce_shutdown', true) then
		local dnd = minetest.settings:get_bool('telegram.announce_shutdown.dnd', false)
		sendMessage("Server is shutting down.", dnd)
	end
end


minetest.register_on_joinplayer(join)
minetest.register_on_chat_message(chat)
minetest.register_on_dieplayer(dead)
minetest.register_on_leaveplayer(leave)
minetest.register_on_shutdown(shutdown)


http_api.fetch({url = api_url..'getMe'}, function (result)
	if result.succeeded and result.code == 200 then
		local parsed = minetest.parse_json(result.data)
		minetest.log('info', "Starting up @"..parsed.result.username)
		startup()
		getUpdates()
	else
		minetest.log('error', "Telegram API is invalid")
	end
end)
