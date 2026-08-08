local M = {}

local function agent_dir()
  local override = vim.env.PI_CODING_AGENT_DIR
  if override and override ~= "" then
    return vim.fn.expand(override)
  end
  return vim.fn.expand("~/.pi/agent")
end

local function read_settings()
  local path = agent_dir() .. "/settings.json"
  if vim.fn.filereadable(path) ~= 1 then
    return {}
  end
  local ok, settings = pcall(vim.json.decode, table.concat(vim.fn.readfile(path), "\n"))
  return ok and type(settings) == "table" and settings or {}
end

function M.session_dir()
  local env_dir = vim.env.PI_CODING_AGENT_SESSION_DIR
  if env_dir and env_dir ~= "" then
    return vim.fn.expand(env_dir)
  end

  local configured = read_settings().sessionDir
  if configured and configured ~= "" then
    if configured:sub(1, 1) == "/" or configured:sub(1, 1) == "~" then
      return vim.fn.expand(configured)
    end
    return agent_dir() .. "/" .. configured
  end

  return agent_dir() .. "/sessions"
end

local function normalize(path)
  return vim.fn.fnamemodify(path or "", ":p"):gsub("/$", "")
end

local function content_text(content)
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
    elseif type(block) == "table" and block.type == "text" and block.text then
      parts[#parts + 1] = block.text
    end
  end
  return table.concat(parts, "")
end

local function read_info(path)
  local file = io.open(path, "r")
  if not file then
    return nil
  end

  local info = { path = path }
  local lines = 0
  for line in file:lines() do
    lines = lines + 1
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == "table" then
      if entry.type == "session" then
        info.id = entry.id
        info.cwd = entry.cwd
        info.created_at = entry.timestamp
      elseif entry.type == "session_info" and entry.name then
        info.name = entry.name
      elseif entry.type == "message" and entry.message and entry.message.role == "user" and not info.prompt then
        info.prompt = content_text(entry.message.content)
      end
    end
    if lines >= 120 and info.name and info.prompt then
      break
    end
  end
  file:close()

  local stat = vim.uv.fs_stat(path)
  info.mtime = stat and stat.mtime and stat.mtime.sec or 0
  info.cwd = info.cwd or ""
  info.label = vim.trim((info.name or info.prompt or vim.fn.fnamemodify(path, ":t:r")):gsub("\n", " "))
  return info
end

function M.list(opts)
  opts = opts or {}
  local root = M.session_dir()
  if vim.fn.isdirectory(root) ~= 1 then
    return {}
  end

  local current_cwd = normalize(opts.cwd or vim.fn.getcwd())
  local sessions = {}
  local paths = vim.fs.find(function(name)
    return name:sub(-6) == ".jsonl"
  end, { path = root, type = "file", limit = opts.limit or 2000 })

  for _, path in ipairs(paths) do
    local info = read_info(path)
    if info and (opts.all or normalize(info.cwd) == current_cwd) then
      sessions[#sessions + 1] = info
    end
  end

  table.sort(sessions, function(a, b)
    return (a.mtime or 0) > (b.mtime or 0)
  end)
  return sessions
end

function M.pick(opts, callback)
  opts = opts or {}
  local sessions = M.list(opts)
  if #sessions == 0 then
    callback(nil)
    return
  end

  local choices = {}
  for _, session in ipairs(sessions) do
    local timestamp = session.mtime > 0 and os.date("%Y-%m-%d %H:%M", session.mtime) or "unknown time"
    local cwd = session.cwd ~= "" and (" · " .. vim.fn.fnamemodify(session.cwd, ":~")) or ""
    choices[#choices + 1] = string.format("%s  [%s%s]", session.label, timestamp, cwd)
  end

  vim.ui.select(choices, { prompt = opts.prompt or "Pi session: " }, function(_, index)
    callback(index and sessions[index] or nil)
  end)
end

return M
