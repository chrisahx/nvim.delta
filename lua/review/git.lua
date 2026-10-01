local M = {}

-- All callbacks run on Neovim's main loop. Paths and revisions are never shell input.
function M.run(root, args, callback)
  local argv = { "git" }
  if root then
    vim.list_extend(argv, { "-C", root })
  end
  vim.list_extend(argv, args)
  local ok, err = pcall(vim.system, argv, { text = false }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local message = (result.stderr or ""):gsub("%s+$", "")
        if message == "" then
          message = string.format("Git %s failed (exit %d)", args[1], result.code)
        end
        callback(nil, message)
      else
        callback(result.stdout or "")
      end
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback(nil, "Cannot execute git: " .. tostring(err))
    end)
  end
end

function M.root(cwd, callback)
  M.run(cwd, { "rev-parse", "--show-toplevel" }, function(out, err)
    callback(out and out:gsub("\n$", ""), err and ("Not inside a Git repository: " .. err))
  end)
end

function M.resolve(root, base, merge, callback)
  local candidates = base and { base } or { "origin/main", "main", "origin/master", "master" }
  local function attempt(i)
    local name = candidates[i]
    if not name then
      callback(nil, "No default base found; pass a commit or branch to :Review")
      return
    end
    M.run(
      root,
      { "rev-parse", "--verify", "--end-of-options", name .. "^{commit}" },
      function(out, err)
        if not out then
          if base then
            callback(nil, "Invalid base revision: " .. name .. ": " .. err)
          else
            attempt(i + 1)
          end
          return
        end
        local commit = out:gsub("%s+$", "")
        if not merge then
          callback({ name = name, commit = commit })
          return
        end
        M.run(root, { "merge-base", commit, "HEAD" }, function(ancestor, merge_err)
          if not ancestor then
            callback(
              nil,
              "Cannot find merge base with "
                .. name
                .. "; check HEAD and shared history: "
                .. merge_err
            )
            return
          end
          callback({ name = name, commit = ancestor:gsub("%s+$", "") })
        end)
      end
    )
  end
  attempt(1)
end

local function fields(out)
  local result = {}
  for value in out:gmatch("([^%z]+)%z") do
    result[#result + 1] = value
  end
  return result
end

local function list_files(root, commit, callback)
  M.run(
    root,
    { "diff", "--no-ext-diff", "--no-renames", "--name-status", "-z", commit, "--" },
    function(out, err)
      if not out then
        callback(nil, err)
        return
      end
      local parts, files, seen = fields(out), {}, {}
      for i = 1, #parts, 2 do
        local status, path = parts[i], parts[i + 1]
        if status == "U" then
          callback(nil, "Resolve merge conflicts before starting a review")
          return
        end
        if path then
          files[#files + 1] =
            { path = path, status = status:sub(1, 1), reviewed = false, hunks = {} }
          seen[path] = true
        end
      end
      M.run(
        root,
        { "ls-files", "--others", "--exclude-standard", "-z" },
        function(untracked, untracked_err)
          if not untracked then
            callback(nil, untracked_err)
            return
          end
          for _, path in ipairs(fields(untracked)) do
            if not seen[path] then
              files[#files + 1] = { path = path, status = "?", reviewed = false, hunks = {} }
            end
          end
          table.sort(files, function(a, b)
            return a.path < b.path
          end)
          for _, file in ipairs(files) do
            local stat = vim.uv.fs_lstat(root .. "/" .. file.path)
            file.signature = stat
                and table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":")
              or "deleted"
          end
          callback(files)
        end
      )
    end
  )
end

function M.files(root, commit, callback)
  M.run(root, { "ls-files", "--unmerged", "-z" }, function(out, err)
    if not out then
      callback(nil, err)
      return
    end
    if out ~= "" then
      callback(nil, "Resolve merge conflicts before starting a review")
      return
    end
    list_files(root, commit, callback)
  end)
end

function M.content(root, commit, file, callback)
  if file.status == "A" or file.status == "?" then
    callback("")
    return
  end
  M.run(root, { "show", commit .. ":" .. file.path }, callback)
end
return M
