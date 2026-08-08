local M = {}

local state = {
  bufnr = nil,
  winnr = nil,
  active_block = nil,
  session_path = nil,
  status = "idle",
  model = nil,
  thinking = nil,
  context_usage = nil,
  cost = nil,
  tokens = nil,
  streamed_message = false,
}

local function valid_buffer()
  return state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
end

local function valid_window()
  return state.winnr and vim.api.nvim_win_is_valid(state.winnr)
end

local function mutate(callback)
  if not valid_buffer() then
    return
  end
  vim.bo[state.bufnr].modifiable = true
  callback()
  vim.bo[state.bufnr].modifiable = false
end

local function append_lines(lines)
  if not valid_buffer() then
    return
  end
  mutate(function()
    vim.api.nvim_buf_set_lines(state.bufnr, -1, -1, false, lines)
  end)
  if valid_window() then
    pcall(vim.api.nvim_win_set_cursor, state.winnr, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
  end
end

local function set_status_line(text)
  if not valid_buffer() then
    return
  end
  mutate(function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, 1, false, { text })
  end)
end

local function text_content(content)
  if type(content) == "string" then
    return content
  end
  if type(content) ~= "table" then
    return ""
  end

  local parts = {}
  for _, block in ipairs(content) do
    if type(block) == "string" then
      parts[#parts + 1] = block
    elseif type(block) == "table" then
      if block.type == "text" or block.type == "thinking" then
        parts[#parts + 1] = block.text or block.thinking or ""
      end
    end
  end
  return table.concat(parts, "")
end

local function content_lines(content)
  local text = text_content(content)
  if text == "" then
    return { "" }
  end
  return vim.split(text, "\n", { plain = true })
end

local function display_model()
  if not state.model then
    return "default model"
  end
  return string.format("%s/%s", state.model.provider or "?", state.model.id or "?")
end

local function display_session()
  if not state.session_path or state.session_path == "" then
    return "new session"
  end
  return vim.fn.fnamemodify(state.session_path, ":~")
end

local function status_text()
  local usage = ""
  if state.context_usage and tonumber(state.context_usage.percent) then
    usage = string.format(" · context %d%%", tonumber(state.context_usage.percent))
  end
  if state.cost ~= nil then
    usage = usage .. string.format(" · $%.4f", tonumber(state.cost) or 0)
  end
  return string.format("Pi · %s · thinking %s · %s · %s%s", state.status, state.thinking or "?", display_model(), display_session(), usage)
end

local function finish_block()
  if not state.active_block then
    return
  end
  state.active_block = nil
  append_lines({ "" })
end

local function render_active_block()
  local block = state.active_block
  if not block or not valid_buffer() then
    return
  end

  local lines = vim.split(block.text or "", "\n", { plain = true })
  if #lines == 0 then
    lines = { "" }
  end
  lines[1] = block.prefix .. lines[1]
  for index = 2, #lines do
    lines[index] = block.continuation .. lines[index]
  end

  mutate(function()
    vim.api.nvim_buf_set_lines(state.bufnr, block.start, -1, false, lines)
  end)
  if valid_window() then
    pcall(vim.api.nvim_win_set_cursor, state.winnr, { vim.api.nvim_buf_line_count(state.bufnr), 0 })
  end
end

local function begin_block(kind, prefix, continuation)
  finish_block()
  local start = vim.api.nvim_buf_line_count(state.bufnr)
  state.active_block = {
    kind = kind,
    start = start,
    prefix = prefix or "",
    continuation = continuation or "  ",
    text = "",
  }
  append_lines({ "" })
  render_active_block()
end

local function update_block(text, append)
  if not state.active_block then
    begin_block("stream", "")
  end
  if append then
    state.active_block.text = state.active_block.text .. (text or "")
  else
    state.active_block.text = text or ""
  end
  render_active_block()
end

local function append_labeled(label, content)
  finish_block()
  local lines = content_lines(content)
  lines[1] = label .. lines[1]
  for index = 2, #lines do
    lines[index] = "  " .. lines[index]
  end
  append_lines(lines)
  append_lines({ "" })
end

local function partial_result_text(partial)
  if type(partial) ~= "table" then
    return ""
  end
  return text_content(partial.content)
end

local function tool_arguments(args)
  if type(args) == "string" then
    return args
  end
  if type(args) == "table" then
    local ok, encoded = pcall(vim.json.encode, args)
    return ok and encoded or ""
  end
  return ""
end

function M.open()
  if valid_window() then
    return state.bufnr
  end

  local origin_window = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  state.winnr = vim.api.nvim_get_current_win()
  if not valid_buffer() then
    state.bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(state.bufnr, "pi://transcript")
  end
  vim.api.nvim_win_set_buf(state.winnr, state.bufnr)
  vim.api.nvim_win_set_width(state.winnr, math.min(88, math.max(48, math.floor(vim.o.columns * 0.38))))

  vim.bo[state.bufnr].buftype = "nofile"
  vim.bo[state.bufnr].bufhidden = "hide"
  vim.bo[state.bufnr].swapfile = false
  vim.bo[state.bufnr].modifiable = false
  vim.bo[state.bufnr].filetype = "markdown"
  vim.bo[state.bufnr].syntax = "markdown"
  vim.wo[state.winnr].number = false
  vim.wo[state.winnr].relativenumber = false
  vim.wo[state.winnr].signcolumn = "no"
  vim.wo[state.winnr].wrap = true
  vim.wo[state.winnr].linebreak = true
  vim.wo[state.winnr].winfixwidth = true
  M.clear()
  if vim.api.nvim_win_is_valid(origin_window) then
    vim.api.nvim_set_current_win(origin_window)
  end
  return state.bufnr
end

function M.focus()
  if valid_window() then
    vim.api.nvim_set_current_win(state.winnr)
  end
end

function M.close()
  if valid_window() then
    vim.api.nvim_win_close(state.winnr, false)
  end
  state.winnr = nil
end

function M.clear()
  state.active_block = nil
  state.streamed_message = false
  if not valid_buffer() then
    return
  end
  mutate(function()
    vim.api.nvim_buf_set_lines(state.bufnr, 0, -1, false, { status_text(), "" })
  end)
end

function M.set_session(path)
  state.session_path = path
  set_status_line(status_text())
end

function M.set_state(data)
  if type(data) ~= "table" then
    return
  end
  if data.model == vim.NIL then
    state.model = nil
  elseif data.model ~= nil then
    state.model = data.model
  end
  if data.thinkingLevel == vim.NIL then
    state.thinking = nil
  elseif data.thinkingLevel ~= nil then
    state.thinking = data.thinkingLevel
  end
  if data.sessionFile == vim.NIL then
    state.session_path = nil
  elseif data.sessionFile ~= nil then
    state.session_path = data.sessionFile
  end
  if data.contextUsage == vim.NIL then
    state.context_usage = nil
  elseif data.contextUsage ~= nil then
    state.context_usage = data.contextUsage
  end
  if data.isStreaming then
    state.status = "running"
  end
  set_status_line(status_text())
end

function M.set_status(status)
  state.status = status or state.status
  set_status_line(status_text())
end

function M.set_stats(data)
  if type(data) ~= "table" then
    return
  end
  if data.cost == vim.NIL then
    state.cost = nil
  elseif data.cost ~= nil then
    state.cost = data.cost
  end
  if data.tokens == vim.NIL then
    state.tokens = nil
  elseif data.tokens ~= nil then
    state.tokens = data.tokens
  end
  if type(data.contextUsage) == "table" then
    state.context_usage = data.contextUsage
  end
  set_status_line(status_text())
end

function M.session_path()
  return state.session_path
end

function M.append_user(message)
  M.open()
  append_labeled("> ", message)
  M.set_status("starting")
end

function M.append(lines)
  M.open()
  append_lines(lines or {})
end

function M.handle_event(event)
  if type(event) ~= "table" then
    return
  end
  M.open()

  local event_type = event.type
  if event_type == "state" then
    M.set_state(event.data)
    return
  elseif event_type == "agent_start" then
    M.set_status("running")
    append_lines({ "▶ Agent started", "" })
    return
  elseif event_type == "agent_settled" then
    finish_block()
    M.set_status("idle")
    append_lines({ "■ Agent settled", "" })
    return
  elseif event_type == "agent_end" then
    finish_block()
    M.set_status(event.willRetry and "retrying" or "thinking")
    append_lines({ event.willRetry and "↻ Agent run finished; retrying" or "· Agent turn finished", "" })
    return
  elseif event_type == "turn_start" then
    M.set_status("thinking")
    return
  elseif event_type == "message_start" then
    state.streamed_message = false
    return
  elseif event_type == "message_update" then
    state.streamed_message = true
    local delta = event.assistantMessageEvent or {}
    local delta_type = delta.type
    if delta_type == "thinking_start" then
      begin_block("thinking", "[thinking] ")
    elseif delta_type == "thinking_delta" then
      update_block(delta.delta or "", true)
    elseif delta_type == "thinking_end" then
      finish_block()
    elseif delta_type == "text_start" then
      begin_block("assistant", "[assistant] ")
    elseif delta_type == "text_delta" then
      update_block(delta.delta or "", true)
    elseif delta_type == "text_end" then
      finish_block()
    elseif delta_type == "toolcall_start" then
      begin_block("tool_call", "[tool call] ")
    elseif delta_type == "toolcall_delta" then
      update_block(delta.delta or "", true)
    elseif delta_type == "toolcall_end" then
      if delta.toolCall then
        update_block(tool_arguments(delta.toolCall.arguments), false)
      end
      finish_block()
    end
    return
  elseif event_type == "message_end" then
    if event.message and event.message.role == "assistant" and not state.streamed_message then
      for _, block in ipairs(event.message.content or {}) do
        if block.type == "thinking" then
          append_labeled("[thinking] ", block.thinking)
        elseif block.type == "text" then
          append_labeled("[assistant] ", block.text)
        end
      end
    end
    state.streamed_message = false
    return
  elseif event_type == "tool_execution_start" then
    finish_block()
    M.set_status("tool: " .. (event.toolName or "unknown"))
    append_lines({ string.format("▶ Tool: %s", event.toolName or "unknown"), "  Args: " .. tool_arguments(event.args) })
    begin_block("tool_output", "  Output: ", "          ")
    return
  elseif event_type == "tool_execution_update" then
    M.set_status("tool: " .. (event.toolName or "unknown"))
    update_block(partial_result_text(event.partialResult), false)
    return
  elseif event_type == "tool_execution_end" then
    update_block(partial_result_text(event.result), false)
    finish_block()
    append_lines({ event.isError and "  ✗ Tool failed" or "  ✓ Tool finished", "" })
    M.set_status("thinking")
    return
  elseif event_type == "bash_execution_update" then
    if not state.active_block or state.active_block.kind ~= "bash" then
      begin_block("bash", "[bash] ", "        ")
    end
    update_block(event.delta or "", true)
    return
  elseif event_type == "compaction_start" then
    finish_block()
    M.set_status("compacting")
    append_lines({ "↻ Context compaction started", "" })
    return
  elseif event_type == "compaction_end" then
    finish_block()
    append_lines({ "✓ Context compaction finished", "" })
    M.set_status("thinking")
    return
  elseif event_type == "auto_retry_start" then
    finish_block()
    M.set_status("retrying")
    append_lines({ string.format("↻ Retry %s/%s: %s", event.attempt or "?", event.maxAttempts or "?", event.errorMessage or ""), "" })
    return
  elseif event_type == "auto_retry_end" then
    append_lines({ event.success and "✓ Retry succeeded" or "✗ Retry failed", "" })
    M.set_status("thinking")
    return
  elseif event_type == "queue_update" then
    local steering = #(event.steering or {})
    local follow_up = #(event.followUp or {})
    M.set_status(string.format("queued: %d steer, %d follow-up", steering, follow_up))
    return
  elseif event_type == "extension_ui_request" then
    if event.method == "notify" then
      append_lines({ string.format("[%s] %s", event.notifyType or "info", event.message or ""), "" })
    elseif event.method == "setStatus" then
      M.set_status(event.statusText or "idle")
    elseif event.method == "setWidget" then
      append_lines(event.widgetLines or {})
      append_lines({ "" })
    end
    return
  elseif event_type == "extension_error" then
    finish_block()
    M.set_status("error")
    append_lines({ "✗ Extension error: " .. (event.error or event.message or "unknown error"), "" })
    return
  elseif event_type == "rpc_error" or event_type == "stderr" then
    local text = event.message or event.text
    if text and text ~= "" then
      append_lines({ "[rpc] " .. vim.trim(text), "" })
    end
    return
  elseif event_type == "rpc_exit" then
    finish_block()
    M.set_status("disconnected")
    append_lines({ "■ " .. (event.message or "Pi disconnected"), "" })
  end
end

function M.render_entries(entries, data)
  M.open()
  M.clear()
  if data then
    M.set_state(data)
  end

  for _, entry in ipairs(entries or {}) do
    if entry.type == "message" and entry.message then
      local message = entry.message
      if message.role == "user" then
        append_labeled("> ", message.content)
      elseif message.role == "assistant" then
        for _, block in ipairs(message.content or {}) do
          if block.type == "thinking" then
            append_labeled("[thinking] ", block.thinking)
          elseif block.type == "text" then
            append_labeled("[assistant] ", block.text)
          elseif block.type == "toolCall" then
            append_labeled("[tool call] " .. (block.name or "unknown") .. " ", tool_arguments(block.arguments))
          end
        end
      elseif message.role == "toolResult" then
        append_labeled("[tool result] " .. (message.toolName or "unknown") .. " ", message.content)
      end
    elseif entry.type == "compaction" then
      append_labeled("[compaction] ", entry.summary)
    elseif entry.type == "branch_summary" then
      append_labeled("[branch summary] ", entry.summary)
    elseif entry.type == "model_change" then
      append_lines({ string.format("[model] %s/%s", entry.provider or "?", entry.modelId or "?"), "" })
    elseif entry.type == "thinking_level_change" then
      append_lines({ "[thinking level] " .. (entry.thinkingLevel or "?"), "" })
    elseif entry.type == "session_info" then
      append_lines({ "[session name] " .. (entry.name or ""), "" })
    elseif entry.type == "custom_message" and entry.display then
      append_labeled("[extension] ", entry.content)
    end
  end

  M.set_status("idle")
end

return M
