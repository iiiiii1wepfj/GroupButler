local config = require "groupbutler.config"
local api = require "telegram-bot-api.methods".init(config.telegram.token)
local locale = require "groupbutler.languages"
local i18n = locale.translate
local null = require "groupbutler.null"

local _M = {}

function _M:new(update_obj)
	local plugin_obj = {}
	setmetatable(plugin_obj, {__index = self})
	for k, v in pairs(update_obj) do
		plugin_obj[k] = v
	end
	return plugin_obj
end

local function ban_bots(self, msg)
	local db = self.db
	local u = self.u

	if msg.from.id == msg.new_chat_member.id or msg:is_from_admin() then
		--ignore if added by an admin or new member joined by link
		return
	else
		local status = db:hget(('chat:%d:settings'):format(msg.chat.id), 'Antibot')
		if status == null then status = config.chat_settings.settings.Antibot end

		if status == 'on' then
			local users = msg.new_chat_members
			local n = 0 --bots banned
			for i = 1, #users do
				if users[i].is_bot == true then
					u:banUser(msg.chat.id, users[i].id)
					n = n + 1
				end
			end
			if n == #users then
				--if all the new members added are bots then don't send a welcome message
				return true
			end
		end
	end
end

local function is_on(self, chat_id, setting)
	local db = self.db

	local hash = 'chat:'..chat_id..':settings'
	local current = db:hget(hash, setting)
	if current == null then
		current = config.chat_settings.settings[setting]
	end

	if current == 'on' then
		return true
	end
	return false
end

-- local permissions =
-- {'can_send_messages', 'can_send_media_messages', 'can_send_other_messages', 'can_add_web_page_previews'}

local function list_to_kv(list)
	local copy = {}
	for i = 1, #list, 2 do
		copy[list[i]] = list[i + 1]
	end
	return copy
end

local function apply_default_permissions(self, chat_id, users)
	local db = self.db

	local hash = ('chat:%d:defpermissions'):format(chat_id)
	local def_permissions = list_to_kv(db:hgetall(hash))

	if next(def_permissions) then
		--for i=1, #permissions do
			--if not def_permissions[permissions[i]] then
				--def_permissions[permissions[i]] = config.chat_settings.defpermissions[permissions[i]]
			--end
		--end

		for i=1, #users do
			local res = api.getChatMember(chat_id, users[i].id)
			if res.status ~= 'restricted' then
				def_permissions.chat_id = chat_id
				def_permissions.user_id = users[i].id
				api.restrictChatMember(def_permissions)
			end
		end
	end
end

local function get_reply_markup(self, msg, text)
	local u = self.u

	local new_text, reply_markup
	if text then
		reply_markup, new_text = u:reply_markup_from_text(text)
		text = new_text:replaceholders(msg)
	end

	if is_on(self, msg.chat.id, "Welbut") then
		if not reply_markup then
			reply_markup = {inline_keyboard={}}
		end
		local line = {{text = i18n("Read the rules"), url = u:deeplink_constructor(msg.chat.id, "rules")}}
		table.insert(reply_markup.inline_keyboard, line)
	end

	return reply_markup, text
end

local function send_welcome(self, msg)
	local db = self.db
	local u = self.u

	if not is_on(self, msg.chat.id, 'Welcome') then
		return
	end

	local hash = 'chat:'..msg.chat.id..':welcome'
	local welcome_type = db:hget(hash, "type")
	local content = db:hget(hash, 'content')
	if welcome_type == "no" or content == "no" -- TODO: database migration no -> null
	or welcome_type == null or content == null then
		welcome_type = "text"
		content = i18n("Hi $name!")
	end

	local ok, err
	if welcome_type == "custom" -- TODO: database migration custom -> text
	or welcome_type == "text" then
		local reply_markup, text = get_reply_markup(self, msg, content)
		local link_preview = text:find('telegra%.ph/') == nil
		ok, err = api.sendMessage(msg.chat.id, text, "Markdown", link_preview, nil, nil, reply_markup)
	end
	if welcome_type == "media" then
		local caption = db:hget(hash, "caption")
		if caption == null then
			caption = nil
		end
		local reply_markup, text = get_reply_markup(self, msg, caption)
		ok, err = api.sendDocument(msg.chat.id, content, text, nil, nil, reply_markup)
	end

	if not ok and err.error_code == 160 then -- if bot can't send message
		u:remGroup(msg.chat.id, true)
		api.leaveChat(msg.chat.id)
		return
	end

	if is_on(self, msg.chat.id, "Weldelchain") then
		local key = ('chat:%d:lastwelcome'):format(msg.chat.id) -- get the id of the last sent welcome message
		local message_id = db:get(key)
		if message_id ~= null then
			api.deleteMessage(msg.chat.id, message_id)
		end
		db:setex(key, 259200, ok.message_id) --set the new message id to delete
	end
end

function _M:onTextMessage(blocks)
	local msg = self.message
	local db = self.db
	local u = self.u

	if blocks[1] == 'welcome' then
		if msg.chat.type == 'private' or not u:is_allowed('texts', msg.chat.id, msg.from) then return end

		local input = blocks[2]
		if not input and not msg.reply then
			u:sendReply(msg, i18n("Welcome and...?"))
			return
		end

		local hash = 'chat:'..msg.chat.id..':welcome'

		if not input and msg.reply then
			local replied_to = msg.reply:type()
			if replied_to == 'sticker' or replied_to == 'gif' then
				local file_id
				if replied_to == 'sticker' then
					file_id = msg.reply.sticker.file_id
				else
					file_id = msg.reply.document.file_id
				end
				db:hset(hash, 'type', 'media')
				db:hset(hash, 'content', file_id)
				if msg.reply.caption then
					db:hset(hash, 'caption', msg.reply.caption)
				else
					db:hdel(hash, 'caption') --remove the caption key if the new media doesn't have a caption
				end
				-- turn on the welcome message in the group settings
				db:hset(('chat:%d:settings'):format(msg.chat.id), 'Welcome', 'on')
				u:sendReply(msg, i18n("A form of media has been set as the welcome message: `%s`"):format(replied_to), "Markdown")
			else
				u:sendReply(msg, i18n("Reply to a `sticker` or a `gif` to set them as the *welcome message*"), "Markdown")
			end
		else
			db:hset(hash, 'type', 'custom')
			db:hset(hash, 'content', input)

			local reply_markup, new_text = u:reply_markup_from_text(input)

			local ok, err = u:sendReply(msg, new_text:gsub('$rules', u:deeplink_constructor(msg.chat.id, 'rules')), "Markdown",
				reply_markup)
			if not ok then
				db:hset(hash, 'type', 'no') --if wrong markdown, remove 'custom' again
				db:hset(hash, 'content', 'no')
				api.sendMessage(msg.chat.id, u:get_sm_error_string(err), "Markdown")
			else
				-- turn on the welcome message in the group settings
				db:hset(('chat:%d:settings'):format(msg.chat.id), 'Welcome', 'on')
				local id = ok.message_id
				api.editMessageText(msg.chat.id, id, nil, i18n("*Custom welcome message saved!*"), "Markdown")
			end
		end
	end
	if blocks[1] == 'new_chat_member' then
		if not msg.service then return end

		local extra
		if msg.from.id ~= msg.new_chat_member.id then extra = msg.from end
		u:logEvent(blocks[1], msg, extra)

		local stop = ban_bots(self, msg)
		if stop then return end

		apply_default_permissions(self, msg.chat.id, msg.new_chat_members)

		send_welcome(self, msg)

		local send_rules_private = db:hget('user:'..msg.new_chat_member.id..':settings', 'rules_on_join')
		if send_rules_private == "on" then
			local rules = db:hget('chat:'..msg.chat.id..':info', 'rules')
			if rules ~= null then
				api.sendMessage(msg.new_chat_member.id, rules, "Markdown")
			end
		end
	end
end

_M.triggers = {
	onTextMessage = {
		config.cmd..'(welcome) (.*)$',
		config.cmd..'set(welcome) (.*)$',
		config.cmd..'(welcome)$',
		config.cmd..'set(welcome)$',
		config.cmd..'(goodbye) (.*)$',
		config.cmd..'set(goodbye) (.*)$',

		'^###(new_chat_member)$'
	}
}

return _M
