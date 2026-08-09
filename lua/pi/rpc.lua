local M = {}

local client = {
  process = nil,
  stdout_buffer = "",
  stderr = "",
  pending = {},
  listeners = {},
  next_request_id = 0,
  state = nil,
  busy = false,
  stopping = false,
}

local function schedule(callback, ...)
  local args = { ... }
  vim.schedule(function()
    callback(unpack(args))
  end)
end

local function emit(event)
  for _, listener in pairs(client.listeners) do
    local ok, err = pcall(listener, event)
    if not ok then
      vim.schedule(function()
        vim.notify("pi.nvim RPC listener failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

local function reject_pending(message)
  local pending = client.pending
  client.pending = {}
  for _, callback in pairs(pending) do
    schedule(callback, nil, message)
  end
end

local function handle_line(line)
  if line == "" then
    return
  end
  if line:sub(-1) == "\r" then
    line = line:sub(1, -2)
  end

  local ok, event = pcall(vim.json.decode, line)
  if not ok or type(event) ~= "table" then
    emit({ type = "rpc_parse_error", raw = line })
    return
  end

  if event.type == "response" then
    if event.id and client.pending[event.id] then
      local callback = client.pending[event.id]
      client.pending[event.id] = nil
      if event.success then
        schedule(callback, event.data, nil, event)
      else
        schedule(callback, nil, event.error or "pi RPC command failed", event)
      end
    elseif event.success == false then
      emit({ type = "rpc_error", message = event.error or "pi RPC command failed", response = event })
    end
    return
  end

  if event.type == "agent_start" or event.type == "turn_start" then
    client.busy = true
    if client.state then
      client.state.isStreaming = true
    end
  elseif event.type == "agent_end" or event.type == "agent_settled" then
    client.busy = false
    if client.state then
      client.state.isStreaming = false
    end
  end

  emit(event)
end

local function feed_stdout(chunk)
  if not chunk or chunk == "" then
    return
  end

  client.stdout_buffer = client.stdout_buffer .. chunk
  while true do
    local newline = client.stdout_buffer:find("\n", 1, true)
    if not newline then
      return
    end
    local line = client.stdout_buffer:sub(1, newline - 1)
    client.stdout_buffer = client.stdout_buffer:sub(newline + 1)
    handle_line(line)
  end
end

local function fail_process(message)
  local process = client.process
  if not process then
    return
  end
  client.process = nil
  client.state = nil
  client.busy = false
  client.stopping = false
  reject_pending(message)
  emit({
    type = "rpc_exit",
    result = { code = -1, signal = 0 },
    message = message,
  })
  pcall(process.kill, process, 15)
end

local function on_exit(result)
  if client.stdout_buffer ~= "" then
    local final_line = client.stdout_buffer
    client.stdout_buffer = ""
    handle_line(final_line)
  end

  local process = client.process
  client.process = nil
  client.state = nil
  client.busy = false

  local message
  if client.stopping then
    message = "pi RPC stopped"
  else
    message = string.format("Pi exited before completing request (code=%s, signal=%s)", tostring(result.code), tostring(result.signal))
  end
  reject_pending(message)
  emit({ type = "rpc_exit", result = result, message = message })
  client.stopping = false

  if process then
    pcall(process.kill, process, 9)
  end
end

function M.subscribe(listener)
  client.listeners[#client.listeners + 1] = listener
  local index = #client.listeners
  return function()
    client.listeners[index] = nil
  end
end

function M.is_running()
  return client.process ~= nil
end

function M.is_busy()
  return client.busy or (client.state and client.state.isStreaming) or false
end

function M.get_state()
  return client.state
end

function M.set_state(data)
  if type(data) == "table" then
    client.state = data
    client.busy = data.isStreaming or false
  end
end

function M.get_stderr()
  return client.stderr
end

function M.respond(id, response)
  if not client.process then
    return nil
  end
  local payload = vim.tbl_extend("force", response or {}, {
    type = "extension_ui_response",
    id = id,
  })
  local ok, err = pcall(client.process.write, client.process, vim.json.encode(payload) .. "\n")
  if not ok then
    return nil, tostring(err)
  end
  return true
end

function M.request(command, callback)
  if not client.process then
    if callback then
      schedule(callback, nil, "pi RPC is not running")
    end
    return nil
  end

  client.next_request_id = client.next_request_id + 1
  local id = "nvim-" .. tostring(client.next_request_id)
  local request = vim.deepcopy(command)
  request.id = id
  client.pending[id] = callback or function() end

  local ok, err = pcall(client.process.write, client.process, vim.json.encode(request) .. "\n")
  if not ok then
    client.pending[id] = nil
    local message = tostring(err)
    fail_process(message)
    if callback then
      schedule(callback, nil, message)
    end
    return nil
  end
  return id
end

function M.start(command, callback)
  if client.process then
    if callback then
      M.request({ type = "get_state" }, callback)
    end
    return client.process
  end

  client.stdout_buffer = ""
  client.stderr = ""
  client.state = nil
  client.busy = false
  client.stopping = false

  local ok, process = pcall(vim.system, command, {
    text = true,
    stdin = true,
    stdout = vim.schedule_wrap(function(err, data)
      if err then
        emit({ type = "rpc_error", message = tostring(err) })
      else
        feed_stdout(data)
      end
    end),
    stderr = vim.schedule_wrap(function(err, data)
      if err then
        emit({ type = "stderr", text = tostring(err) })
      elseif data and data ~= "" then
        client.stderr = client.stderr .. data
        emit({ type = "stderr", text = data })
      end
    end),
  }, vim.schedule_wrap(on_exit))

  if not ok then
    if callback then
      schedule(callback, nil, tostring(process))
    end
    return nil, process
  end

  client.process = process
  M.request({ type = "get_state" }, function(data, err, response)
    if data then
      client.state = data
      client.busy = data.isStreaming or false
      emit({ type = "state", data = data, response = response })
    end
    if callback then
      callback(data, err, response)
    end
  end)
  return process
end

function M.stop()
  if not client.process then
    return
  end

  client.stopping = true
  local process = client.process
  local ok = pcall(process.write, process, nil)
  if not ok then
    pcall(process.kill, process, 15)
  end

  vim.defer_fn(function()
    if client.process == process then
      pcall(process.kill, process, 9)
    end
  end, 1000)
end

return M
