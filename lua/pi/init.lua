local config = require("pi.config")
local context = require("pi.context")
local session_mod = require("pi.session")
local rpc = require("pi.rpc")
local sessions = require("pi.sessions")
local transcript = require("pi.transcript")
local log = require("pi.log")

local M = {}

local active_session = nil
local last_session = nil
local selected_session_path = nil
local rpc_unsubscribe = nil
local refresh_stats

local function notify(message, level)
  vim.notify(message, level or vim.log.levels.INFO, { title = "pi.nvim" })
end

local function assert_supported_version()
  if vim.fn.has("nvim-0.10") == 0 then
    error("pi.nvim requires Neovim 0.10+")
  end
end

local function ensure_file_backed_buffer(command_name)
  local bufnr = vim.api.nvim_get_current_buf()
  if not context.buffer_is_file_backed(bufnr) then
    notify(string.format("%s requires a file", command_name), vim.log.levels.ERROR)
    return nil
  end
  return bufnr
end

local function build_append_system_prompt(cfg)
  local prompts = { context.get_system_prompt() }
  if cfg.append_system_prompt and cfg.append_system_prompt ~= "" then
    table.insert(prompts, cfg.append_system_prompt)
  end
  return table.concat(prompts, "\n\n")
end

function M.get_cmd()
  local cfg = config.get()
  local binary = { "pi" }
  if cfg.binary then
    if type(cfg.binary) == "table" then
      binary = vim.deepcopy(cfg.binary)
      for i, part in ipairs(binary) do
        binary[i] = vim.fn.expand(part)
      end
    else
      binary = { vim.fn.expand(cfg.binary) }
    end
  end

  local cmd = vim.list_extend(binary, { "--mode", "rpc", "--no-session" })
  if not cfg.extensions then
    table.insert(cmd, "--no-extensions")
  end
  if not cfg.skills then
    table.insert(cmd, "--no-skills")
  end
  if cfg.provider then
    table.insert(cmd, "--provider")
    table.insert(cmd, cfg.provider)
  end
  if cfg.model then
    table.insert(cmd, "--model")
    table.insert(cmd, cfg.model)
  end
  if cfg.thinking then
    table.insert(cmd, "--thinking")
    table.insert(cmd, cfg.thinking)
  end
  if cfg.system_prompt then
    table.insert(cmd, "--system-prompt")
    table.insert(cmd, cfg.system_prompt)
  end
  table.insert(cmd, "--append-system-prompt")
  table.insert(cmd, build_append_system_prompt(cfg))
  return cmd
end

local function remove_flag(cmd, flag, remove_value)
  local result = {}
  local skip = false
  for _, value in ipairs(cmd) do
    if skip then
      skip = false
    elseif value == flag then
      skip = remove_value
    else
      result[#result + 1] = value
    end
  end
  return result
end

function M.get_rpc_cmd(opts)
  opts = opts or {}
  local cmd = remove_flag(M.get_cmd(), "--no-session", false)
  if opts.session_path then
    cmd = remove_flag(cmd, "--provider", true)
    cmd = remove_flag(cmd, "--model", true)
    cmd = remove_flag(cmd, "--thinking", true)
    table.insert(cmd, "--session")
    table.insert(cmd, opts.session_path)
  end
  return cmd
end

local function normalize_path(path)
  return vim.fn.fnamemodify(path, ":p")
end

local function file_signature(path)
  local stat = vim.loop.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end

  return {
    size = stat.size,
    mtime_sec = stat.mtime and stat.mtime.sec or 0,
    mtime_nsec = stat.mtime and stat.mtime.nsec or 0,
  }
end

local function signatures_equal(a, b)
  if not a or not b then
    return a == b
  end
  return a.size == b.size and a.mtime_sec == b.mtime_sec and a.mtime_nsec == b.mtime_nsec
end

local function snapshot_loaded_file_buffers()
  local snapshots = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      snapshots[path] = file_signature(path)
    end
  end
  return snapshots
end

local function reload_changed_file_buffers(session)
  local before_snapshots = session.file_snapshots or {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and context.buffer_is_file_backed(bufnr) then
      local path = normalize_path(vim.api.nvim_buf_get_name(bufnr))
      local before = before_snapshots[path]
      local after = file_signature(path)
      if not signatures_equal(before, after) and vim.fn.filereadable(path) == 1 then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          local view = vim.api.nvim_get_current_buf() == bufnr and vim.fn.winsaveview() or nil
          vim.cmd("silent edit!")
          if view then
            vim.fn.winrestview(view)
          end
        end)
      end
    end
  end
end

local function update_transcript_state(data)
  if type(data) ~= "table" then
    return
  end
  rpc.set_state(data)
  if data.sessionFile ~= nil and data.sessionFile ~= vim.NIL then
    selected_session_path = data.sessionFile
  end
  transcript.set_state(data)
  if active_session then
    active_session.session_path = selected_session_path
  end
end

local function finish_session(session, status, error_message)
  if not session or session.closing then
    return
  end

  session.closing = true
  session.status = status
  session.ended_at = vim.loop.hrtime()
  if error_message then
    session.last_error = tostring(error_message)
    session_mod.push(session, session.last_error)
    notify("Pi request failed: " .. session.last_error, vim.log.levels.ERROR)
  elseif status == "done" then
    if session.on_done then
      local ok, err = pcall(session.on_done, session)
      if not ok then
        notify("pi on_done error: " .. tostring(err), vim.log.levels.ERROR)
      end
    end
    if not session.skip_reload then
      reload_changed_file_buffers(session)
    end
  end

  if active_session == session then
    active_session = nil
  end
  last_session = session
  log.append_session(nil, session, session.last_message, status, session.source_path)
end

local function handle_extension_ui_request(event)
  local method = event.method
  if method == "select" then
    vim.ui.select(event.options or {}, { prompt = event.title or "Pi selection: " }, function(choice)
      if choice == nil then
        rpc.respond(event.id, { cancelled = true })
      else
        rpc.respond(event.id, { value = choice })
      end
    end)
  elseif method == "confirm" then
    vim.ui.select({ "Yes", "No" }, { prompt = (event.title or "Pi confirmation") .. "\n" .. (event.message or "") }, function(choice)
      if choice == nil then
        rpc.respond(event.id, { cancelled = true })
      else
        rpc.respond(event.id, { confirmed = choice == "Yes" })
      end
    end)
  elseif method == "input" or method == "editor" then
    vim.ui.input({ prompt = event.title or "Pi input: ", default = event.prefill or "" }, function(value)
      if value == nil then
        rpc.respond(event.id, { cancelled = true })
      else
        rpc.respond(event.id, { value = value })
      end
    end)
  end
end

local function handle_rpc_event(event)
  transcript.handle_event(event)

  if event.type == "extension_ui_request" then
    handle_extension_ui_request(event)
  elseif event.type == "state" then
    update_transcript_state(event.data)
  elseif event.type == "agent_start" then
    if active_session then
      active_session.status = "running"
    end
  elseif event.type == "tool_execution_start" then
    if active_session then
      active_session.active_tool = event.toolName
    end
  elseif event.type == "tool_execution_end" then
    if active_session then
      active_session.active_tool = nil
    end
  elseif event.type == "agent_settled" then
    refresh_stats()
    if active_session then
      finish_session(active_session, active_session.cancelled and "cancelled" or "done")
    end
  elseif event.type == "rpc_error" then
    if active_session and not active_session.closing then
      finish_session(active_session, "error", event.message)
    end
  elseif event.type == "rpc_exit" then
    if active_session and not active_session.closing then
      finish_session(active_session, "error", "Pi exited before completing request: " .. (event.message or "unknown exit"))
    end
  elseif event.type == "response" then
    -- Responses are consumed by pi.rpc callbacks and are not broadcast.
  end
end

local function ensure_listener()
  if not rpc_unsubscribe then
    rpc_unsubscribe = rpc.subscribe(handle_rpc_event)
  end
end

local function load_entries(callback)
  rpc.request({ type = "get_entries" }, function(data, err)
    if err then
      notify("Unable to load Pi session: " .. err, vim.log.levels.ERROR)
      if callback then
        callback(nil, err)
      end
      return
    end
    local entries = type(data) == "table" and data.entries or {}
    transcript.render_entries(type(entries) == "table" and entries or {}, rpc.get_state())
    if callback then
      callback(data, nil)
    end
  end)
end

local function start_rpc(session_path, callback, command)
  ensure_listener()
  transcript.open()
  rpc.start(command or M.get_rpc_cmd({ session_path = session_path }), function(data, err)
    if err then
      notify("Unable to start Pi: " .. err, vim.log.levels.ERROR)
      if callback then
        callback(nil, err)
      end
      return
    end

    update_transcript_state(data)
    if session_path then
      load_entries(function(_, entries_err)
        if callback then
          callback(data, entries_err)
        end
      end)
    else
      transcript.clear()
      if callback then
        callback(data, nil)
      end
    end
  end)
end

refresh_stats = function()
  if not rpc.is_running() then
    return
  end
  rpc.request({ type = "get_session_stats" }, function(data)
    if data then
      transcript.set_stats(data)
    end
  end)
end

local function refresh_session_view(callback)
  rpc.request({ type = "get_state" }, function(data, err)
    if err then
      if callback then
        callback(nil, err)
      end
      return
    end
    update_transcript_state(data)
    load_entries(function(entries_data, entries_err)
      if callback then
        callback(data, entries_err, entries_data)
      end
    end)
  end)
end

local function start_new_session(callback)
  if not rpc.is_running() then
    start_rpc(nil, callback)
    return
  end

  if rpc.is_busy() then
    callback(nil, "Pi is currently running")
    return
  end

  rpc.request({ type = "new_session" }, function(data, err)
    if err then
      callback(nil, err)
      return
    end
    if type(data) == "table" and data.cancelled then
      callback(nil, "session creation was cancelled")
      return
    end
    rpc.request({ type = "get_state" }, function(state_data, state_err)
      if state_err then
        callback(nil, state_err)
        return
      end
      if type(state_data) == "table" and state_data.sessionFile ~= nil and state_data.sessionFile ~= vim.NIL then
        selected_session_path = state_data.sessionFile
      end
      transcript.clear()
      update_transcript_state(state_data)
      callback(state_data, nil)
    end)
  end)
end

local function submit_prompt(session, message)
  transcript.append_user(message)
  rpc.request({ type = "prompt", message = message }, function(_, err)
    if err then
      finish_session(session, "error", err)
    end
  end)
end

local function run_with_context(opts, message, bufnr, build_context_fn)
  opts = vim.deepcopy(opts or {})
  if active_session or rpc.is_busy() then
    notify("Pi is already running; use :PiCancel or wait for it to settle", vim.log.levels.WARN)
    return
  end

  local session = session_mod.new(bufnr)
  session.file_snapshots = snapshot_loaded_file_buffers()
  session.last_message = message
  session.skip_reload = opts.skip_reload
  session.on_done = opts.on_done
  session.session_path = selected_session_path
  active_session = session
  last_session = session

  local ok, built_context = pcall(build_context_fn)
  if not ok then
    finish_session(session, "error", built_context)
    return
  end

  local prompt = message .. "\n\nContext:\n" .. built_context
  local function ready(data, err)
    if err then
      finish_session(session, "error", err)
      return
    end
    update_transcript_state(data)
    submit_prompt(session, prompt)
  end

  if opts.new_session == false then
    if rpc.is_running() then
      ready(rpc.get_state(), nil)
    else
      start_rpc(opts.session_path or selected_session_path, ready, opts.cmd)
    end
  elseif rpc.is_running() then
    start_new_session(ready)
  else
    start_rpc(nil, ready, opts.cmd)
  end
end

function M.run(opts)
  opts = vim.deepcopy(opts or {})
  local message = opts.message
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  if not message or message == "" then
    notify("No message provided", vim.log.levels.ERROR)
    return
  end

  local build_context_fn = opts.build_context or function()
    return context.get_buffer_context(bufnr, config.get())
  end
  run_with_context(opts, message, bufnr, build_context_fn)
end

function M.setup(opts)
  assert_supported_version()
  config.setup(opts)
  ensure_listener()
end

function M.prompt_with_buffer()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAsk")
  if not bufnr then
    return
  end

  vim.ui.input({ prompt = context.format_prompt_label(bufnr, nil) }, function(input)
    if input then
      M.run({ message = input, bufnr = bufnr, new_session = true })
    end
  end)
end

function M.prompt_with_selection()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAskSelection")
  if not bufnr then
    return
  end

  local range = context.get_visual_selection_range()
  vim.ui.input({ prompt = context.format_prompt_label(bufnr, range) }, function(input)
    if input then
      M.run({ message = input, bufnr = bufnr, new_session = true, build_context = function()
        return context.get_visual_context(bufnr, config.get())
      end })
    end
  end)
end

function M.prompt_session()
  assert_supported_version()
  local bufnr = ensure_file_backed_buffer("PiAskSession")
  if not bufnr then
    return
  end

  vim.ui.input({ prompt = context.format_prompt_label(bufnr, nil) }, function(input)
    if input then
      M.run({ message = input, bufnr = bufnr, new_session = false })
    end
  end)
end

function M.cancel()
  if not active_session or not rpc.is_running() then
    return
  end
  active_session.cancelled = true
  rpc.request({ type = "abort" }, function(_, err)
    if err then
      finish_session(active_session, "error", err)
    end
  end)
end

function M.stop()
  if active_session and not active_session.closing then
    active_session.cancelled = true
    finish_session(active_session, "cancelled")
  end
  rpc.stop()
end

function M.open()
  transcript.open()
  transcript.focus()
  if rpc.is_running() then
    transcript.set_state(rpc.get_state())
  end
end

function M.close_transcript()
  transcript.close()
end

function M.switch_session(path)
  path = path and vim.fn.fnamemodify(vim.fn.expand(path), ":p") or nil
  if not path or path == "" then
    notify("A Pi session path is required", vim.log.levels.ERROR)
    return
  end
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before switching sessions", vim.log.levels.WARN)
    return
  end

  local function switched(data, err)
    if err then
      notify("Unable to switch Pi session: " .. err, vim.log.levels.ERROR)
      return
    end
    if type(data) == "table" and data.cancelled then
      notify("Pi session switch was cancelled", vim.log.levels.WARN)
      return
    end
    selected_session_path = path
    refresh_session_view(function(_, view_err)
      if view_err then
        notify("Unable to load resumed Pi session: " .. view_err, vim.log.levels.ERROR)
      else
        notify("Resumed Pi session: " .. vim.fn.fnamemodify(path, ":~"))
      end
    end)
  end

  if rpc.is_running() then
    rpc.request({ type = "switch_session", sessionPath = path }, switched)
  else
    selected_session_path = path
    start_rpc(path, function(_, err)
      if err then
        notify("Unable to resume session: " .. err, vim.log.levels.ERROR)
      end
    end)
  end
end

function M.resume_session(opts)
  opts = opts or {}
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before switching sessions", vim.log.levels.WARN)
    return
  end

  sessions.pick({ all = opts.all, prompt = opts.prompt }, function(session)
    if session then
      M.switch_session(session.path)
    else
      notify("No Pi sessions found for the selected scope", vim.log.levels.INFO)
    end
  end)
end

function M.new_session()
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before creating a session", vim.log.levels.WARN)
    return
  end
  start_new_session(function(_, err)
    if err then
      notify("Unable to create session: " .. err, vim.log.levels.ERROR)
    else
      notify("Started a new Pi session")
    end
  end)
end

local function refresh_after_session_command(command, success_message)
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before changing the session", vim.log.levels.WARN)
    return
  end

  rpc.request(command, function(data, err)
    if err then
      notify("Pi session command failed: " .. err, vim.log.levels.ERROR)
      return
    end
    if type(data) == "table" and data.cancelled then
      notify("Pi session command was cancelled", vim.log.levels.WARN)
      return
    end
    refresh_session_view(function(_, view_err)
      if view_err then
        notify("Unable to refresh Pi transcript: " .. view_err, vim.log.levels.ERROR)
      elseif success_message then
        notify(success_message)
      end
    end)
  end)
end

function M.clone_session()
  refresh_after_session_command({ type = "clone" }, "Cloned Pi session")
end

local function message_preview(message)
  if type(message) ~= "table" then
    return ""
  end
  if type(message.content) == "string" then
    return message.content
  end
  if type(message.content) == "table" then
    local parts = {}
    for _, block in ipairs(message.content) do
      if type(block) == "table" and (block.type == "text" or block.type == "thinking") then
        local piece = block.text or block.thinking
        if type(piece) == "string" then
          parts[#parts + 1] = piece
        end
      end
    end
    return table.concat(parts, "")
  end
  return ""
end

local function fork_tree_lines(nodes, lines, prefix)
  if type(nodes) ~= "table" then
    return
  end
  for index, node in ipairs(nodes) do
    local entry = node.entry or {}
    local marker = index == #nodes and "└─ " or "├─ "
    local label = entry.type or "entry"
    if entry.message then
      local message = entry.message
      label = label .. " " .. (message.role or "message")
      local preview = vim.trim(message_preview(message):gsub("\n", " "))
      if preview ~= "" then
        label = label .. ": " .. preview
      end
    elseif type(entry.summary) == "string" then
      label = label .. ": " .. vim.trim(entry.summary:gsub("\n", " "))
    end
    lines[#lines + 1] = prefix .. marker .. label
    fork_tree_lines(node.children, lines, prefix .. (index == #nodes and "   " or "│  "))
  end
end

function M.show_tree()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  rpc.request({ type = "get_tree" }, function(data, err)
    if err then
      notify("Unable to load Pi session tree: " .. err, vim.log.levels.ERROR)
      return
    end
    local lines = { "Pi session tree", "" }
    fork_tree_lines(type(data) == "table" and data.tree or {}, lines, "")
    transcript.append(lines)
    transcript.focus()
  end)
end

function M.fork_session()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before forking", vim.log.levels.WARN)
    return
  end

  rpc.request({ type = "get_fork_messages" }, function(data, err)
    if err then
      notify("Unable to list fork points: " .. err, vim.log.levels.ERROR)
      return
    end
    local messages = type(data) == "table" and data.messages or {}
    if type(messages) ~= "table" or #messages == 0 then
      notify("No user messages are available to fork", vim.log.levels.WARN)
      return
    end
    local choices = {}
    for _, message in ipairs(messages) do
      choices[#choices + 1] = vim.trim(message.text or "(empty prompt)")
    end
    vim.ui.select(choices, { prompt = "Fork Pi session from: " }, function(_, index)
      if not index then
        return
      end
      refresh_after_session_command({ type = "fork", entryId = messages[index].entryId }, "Forked Pi session")
    end)
  end)
end

function M.set_model(provider, model_id, callback)
  if not rpc.is_running() then
    if callback then
      callback(nil, "Pi is not running")
    end
    return
  end
  if rpc.is_busy() then
    if callback then
      callback(nil, "Pi is currently running")
    end
    return
  end
  rpc.request({ type = "set_model", provider = provider, modelId = model_id }, function(data, err)
    if not err and type(data) == "table" then
      local state = vim.deepcopy(rpc.get_state() or {})
      state.model = data
      update_transcript_state(state)
    end
    if callback then
      callback(data, err)
    end
  end)
end

function M.cycle_model(callback)
  if not rpc.is_running() then
    if callback then
      callback(nil, "Pi is not running")
    end
    return
  end
  if rpc.is_busy() then
    if callback then
      callback(nil, "Pi is currently running")
    end
    return
  end
  rpc.request({ type = "cycle_model" }, function(data, err)
    if not err and type(data) == "table" then
      local state = vim.deepcopy(rpc.get_state() or {})
      state.model = data.model or state.model
      state.thinkingLevel = data.thinkingLevel or state.thinkingLevel
      update_transcript_state(state)
    end
    if callback then
      callback(data, err)
    end
  end)
end

function M.set_thinking_level(level, callback)
  if not rpc.is_running() then
    if callback then
      callback(nil, "Pi is not running")
    end
    return
  end
  if rpc.is_busy() then
    if callback then
      callback(nil, "Pi is currently running")
    end
    return
  end
  rpc.request({ type = "set_thinking_level", level = level }, function(data, err)
    if not err then
      local state = vim.deepcopy(rpc.get_state() or {})
      state.thinkingLevel = level
      update_transcript_state(state)
    end
    if callback then
      callback(data, err)
    end
  end)
end

function M.cycle_thinking_level(callback)
  if not rpc.is_running() then
    if callback then
      callback(nil, "Pi is not running")
    end
    return
  end
  if rpc.is_busy() then
    if callback then
      callback(nil, "Pi is currently running")
    end
    return
  end
  rpc.request({ type = "cycle_thinking_level" }, function(data, err)
    if not err and type(data) == "table" then
      local state = vim.deepcopy(rpc.get_state() or {})
      state.thinkingLevel = data.level or state.thinkingLevel
      update_transcript_state(state)
    end
    if callback then
      callback(data, err)
    end
  end)
end

function M.session_path()
  local state = rpc.get_state()
  local path = selected_session_path
  if (path == nil or path == vim.NIL) and state and state.sessionFile ~= vim.NIL then
    path = state.sessionFile
  end
  if path then
    vim.fn.setreg("+", path)
    notify("Session path copied: " .. vim.fn.fnamemodify(path, ":~"))
  else
    notify("No Pi session is active", vim.log.levels.WARN)
  end
end

function M.session_name()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before naming the session", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Pi session name: " }, function(name)
    if name == nil then
      return
    end
    rpc.request({ type = "set_session_name", name = name }, function(_, err)
      if err then
        notify("Unable to name session: " .. err, vim.log.levels.ERROR)
      else
        notify(name == "" and "Cleared Pi session name" or ("Named Pi session: " .. name))
      end
    end)
  end)
end

function M.session_stats()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  rpc.request({ type = "get_session_stats" }, function(data, err)
    if err then
      notify("Unable to read Pi session stats: " .. err, vim.log.levels.ERROR)
      return
    end
    if type(data) ~= "table" then
      notify("Pi returned no session statistics", vim.log.levels.WARN)
      return
    end
    transcript.set_stats(data)
    local context_usage = type(data.contextUsage) == "table" and data.contextUsage or nil
    local context = context_usage and string.format("context %d%%", tonumber(context_usage.percent) or 0) or "context unknown"
    notify(string.format("Pi session · %s · %s · $%.4f", data.sessionId or "unknown", context, tonumber(data.cost) or 0))
  end)
end

function M.export_session()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Export HTML path (empty for default): " }, function(path)
    if path == nil then
      return
    end
    local command = { type = "export_html" }
    if path ~= "" then
      command.outputPath = vim.fn.expand(path)
    end
    rpc.request(command, function(data, err)
      if err then
        notify("Unable to export Pi session: " .. err, vim.log.levels.ERROR)
      else
        local exported_path = data and data.path
        notify("Exported Pi session: " .. (exported_path and exported_path ~= vim.NIL and exported_path or "done"))
      end
    end)
  end)
end

function M.steer()
  if not rpc.is_running() or not rpc.is_busy() then
    notify("Pi is not currently running", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Pi steer: " }, function(message)
    if message and message ~= "" then
      transcript.append({ "↗ Steer: " .. message, "" })
      rpc.request({ type = "steer", message = message }, function(_, err)
        if err then
          notify("Unable to steer Pi: " .. err, vim.log.levels.ERROR)
        end
      end)
    end
  end)
end

function M.follow_up()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  if not active_session and rpc.is_busy() then
    notify("Pi is running a turn that Neovim did not start", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Pi follow-up: " }, function(message)
    if not message or message == "" then
      return
    end

    if not active_session then
      local session = session_mod.new(vim.api.nvim_get_current_buf())
      session.file_snapshots = snapshot_loaded_file_buffers()
      session.last_message = message
      session.session_path = selected_session_path
      active_session = session
      last_session = session
    else
      active_session.last_message = message
    end

    transcript.append_user(message)
    local command_type = rpc.is_busy() and "follow_up" or "prompt"
    rpc.request({ type = command_type, message = message }, function(_, err)
      if err and active_session then
        finish_session(active_session, "error", err)
      end
    end)
  end)
end

function M.compact()
  if not rpc.is_running() then
    notify("No Pi session is active", vim.log.levels.WARN)
    return
  end
  if active_session or rpc.is_busy() then
    notify("Wait for Pi to settle before compacting", vim.log.levels.WARN)
    return
  end
  vim.ui.input({ prompt = "Compaction instructions (optional): " }, function(instructions)
    if instructions == nil then
      return
    end
    transcript.append({ "↻ Requested context compaction", instructions ~= "" and ("  Instructions: " .. instructions) or "", "" })
    rpc.request({ type = "compact", customInstructions = instructions ~= "" and instructions or nil }, function(_, err)
      if err then
        local level = tostring(err):find("Nothing to compact", 1, true) and vim.log.levels.WARN or vim.log.levels.ERROR
        notify("Unable to compact Pi session: " .. err, level)
      end
    end)
  end)
end

function M.is_running()
  return active_session ~= nil
end

function M.is_process_running()
  return rpc.is_running()
end

function M.is_busy()
  return rpc.is_busy()
end

function M._get_active_session()
  return active_session
end

function M._get_last_session()
  return last_session
end

function M.show_log()
  local log_path = log.DEFAULT_PATH
  if vim.fn.filereadable(log_path) == 0 then
    notify("pi.nvim: log file not found at " .. log_path, vim.log.levels.INFO)
    return
  end

  vim.cmd("new")
  vim.cmd("read " .. vim.fn.fnameescape(log_path))
  vim.cmd("1d")
  vim.bo.modifiable = false
  vim.bo.buftype = "nofile"
  vim.cmd("normal! G")
end

function M.get_buffer_context()
  return context.get_buffer_context(vim.api.nvim_get_current_buf(), config.get())
end

function M.get_visual_context()
  return context.get_visual_context(vim.api.nvim_get_current_buf(), config.get())
end

return M
