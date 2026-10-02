local git = require("review.git")
local diff = require("review.diff")
local buffer = require("review.buffer")
local index = require("review.index")
local M = {}
local names = {
  stage_hunk = "Stage",
  unstage_hunk = "Unstage",
  discard_hunk = "Discard unstaged",
  restore_base_hunk = "Restore from review base",
}
local function notify(message, level)
  vim.notify("review: " .. message, level or vim.log.levels.WARN)
end
local function entry_equal(a, b)
  return a.oid == b.oid and a.mode == b.mode
end

local function context(action)
  local session = require("review.session")
  local s = session.active
  if not s then
    notify("No active review")
    return
  end
  if s.operation then
    notify("Another hunk action is pending")
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local file
  for _, candidate in ipairs(s.files) do
    if candidate.buf == buf then
      file = candidate
      break
    end
  end
  if not file then
    notify("Open a review source file before using a hunk action")
    return
  end
  local destructive = action == "discard_hunk" or action == "restore_base_hunk"
  if destructive and (file.status == "D" or not vim.bo[buf].modifiable or vim.bo[buf].readonly) then
    notify("Discard/restore needs an editable source buffer; fully deleted files are read-only")
    return
  end
  if
    vim.bo[buf].binary
    or (vim.bo[buf].fileencoding ~= "" and vim.bo[buf].fileencoding ~= "utf-8")
    or vim.bo[buf].fileformat == "mac"
  then
    notify("Hunk actions only support ordinary UTF-8 text files")
    return
  end
  if action == "stage_hunk" and file.status ~= "D" and vim.bo[buf].modified then
    notify("Save the buffer before staging (:w); unsaved edits will not be staged")
    return
  end
  local token = {}
  s.operation = token
  local tick, generation = vim.api.nvim_buf_get_changedtick(buf), s.generation
  local format, encoding, bom = vim.bo[buf].fileformat, vim.bo[buf].fileencoding, vim.bo[buf].bomb
  local buffer_name = vim.api.nvim_buf_get_name(buf)
  local path = s.root .. "/" .. file.path
  local disk, disk_err, disk_mode
  if action == "stage_hunk" then
    local stat = vim.uv.fs_lstat(path)
    if stat and stat.type ~= "file" then
      s.operation = nil
      notify("Only regular files can be staged")
      return
    end
    if stat then
      disk_mode = stat.mode
      disk, disk_err = index.read(path)
      if not disk then
        s.operation = nil
        notify(disk_err)
        return
      end
    elseif file.status ~= "D" then
      s.operation = nil
      notify("File is missing; refresh the review")
      return
    end
    if disk and disk:find("\0", 1, true) then
      s.operation = nil
      notify("Binary hunks are not supported")
      return
    end
  end
  local c = {
    session = s,
    file = file,
    buf = buf,
    action = action,
    path = path,
    current = file.status == "D" and "" or buffer.text(buf),
    cursor = vim.api.nvim_win_get_cursor(0)[1],
  }
  if action == "stage_hunk" and disk then
    local visible = buffer.normalize(buf, disk)
    if visible ~= c.current then
      s.operation = nil
      notify("Buffer differs from the filesystem; reload or reconcile and save before staging")
      return
    end
  end
  function c.valid()
    if
      session.active ~= s
      or s.operation ~= token
      or generation ~= s.generation
      or not vim.api.nvim_buf_is_loaded(buf)
      or vim.api.nvim_buf_get_changedtick(buf) ~= tick
      or vim.api.nvim_buf_get_name(buf) ~= buffer_name
      or vim.bo[buf].fileformat ~= format
      or vim.bo[buf].fileencoding ~= encoding
      or vim.bo[buf].bomb ~= bom
    then
      return false
    end
    if file.status ~= "D" and buffer.text(buf) ~= c.current then
      return false
    end
    if action == "stage_hunk" then
      if file.status ~= "D" and vim.bo[buf].modified then
        return false
      end
      local now = vim.uv.fs_lstat(path)
      if disk == nil then
        return now == nil
      end
      return now and now.type == "file" and now.mode == disk_mode and index.read(path) == disk
    end
    return true
  end
  function c.finish(message, level)
    if s.operation == token then
      s.operation = nil
    end
    if session.active == s and message then
      notify(message, level)
    end
  end
  c.disk = disk
  return c
end

local function span(hunk, count, unstaged)
  local first = math.max(1, hunk.new_count == 0 and hunk.new_start + 1 or hunk.new_start)
  local last = hunk.new_count == 0 and first or first + hunk.new_count - 1
  if unstaged then
    first, last = diff.map_line(first, unstaged), diff.map_line(last, unstaged)
  end
  return math.min(first, count), math.min(last, count)
end

local function choose(c, hunks, unstaged, callback)
  if not c.valid() then
    c.finish("File or session changed; retry the action")
    return
  end
  if #hunks == 0 then
    c.finish("No " .. names[c.action]:lower() .. " hunks in this file", vim.log.levels.INFO)
    return
  end
  local count = c.file.status == "D" and math.max(1, #vim.split(c.current, "\n"))
    or vim.api.nvim_buf_line_count(c.buf)
  local candidates = {}
  if c.file.status ~= "D" then
    for _, hunk in ipairs(hunks) do
      local first, last = span(hunk, count, unstaged)
      if c.cursor >= first and c.cursor <= last then
        candidates[#candidates + 1] = hunk
      end
    end
    -- A base-review hunk may contain several independent index hunks.
    if #candidates == 0 and c.file.old then
      local review = diff.compute(buffer.normalize(c.buf, c.file.old), c.current)
      for _, review_hunk in ipairs(review) do
        local first, last = span(review_hunk, count)
        if c.cursor >= first and c.cursor <= last then
          for _, hunk in ipairs(hunks) do
            local start, stop = span(hunk, count, unstaged)
            if stop >= first and start <= last then
              candidates[#candidates + 1] = hunk
            end
          end
          break
        end
      end
    end
  end
  if #candidates == 0 then
    candidates = hunks
  end
  if #candidates == 1 then
    callback(candidates[1])
    return
  end
  vim.ui.select(candidates, {
    prompt = names[c.action] .. " which hunk? (working-buffer line numbers)",
    format_item = function(hunk)
      if hunk.metadata then
        return "File addition/deletion/mode change (no text hunk)"
      end
      local row = span(hunk, count, unstaged)
      local preview = ""
      for _, line in ipairs(hunk.lines) do
        if line.kind ~= "context" then
          preview = line.text
          break
        end
      end
      return string.format("Line %d: -%d +%d  %s", row, hunk.old_count, hunk.new_count, preview)
    end,
  }, function(hunk)
    if not hunk then
      c.finish()
    elseif not c.valid() then
      c.finish("File or session changed; retry the action")
    else
      callback(hunk)
    end
  end)
end

local function confirm(c, hunk, callback)
  vim.ui.select({ "Cancel", names[c.action] }, {
    prompt = string.format(
      "%s in %s (-%d +%d)? Buffer only; :w to save; u to undo.",
      names[c.action],
      vim.inspect(c.file.path),
      hunk.new_count,
      hunk.old_count
    ),
  }, function(_, choice)
    if choice ~= 2 then
      c.finish()
    elseif not c.valid() then
      c.finish("File or session changed; action cancelled")
    else
      callback()
    end
  end)
end

local function restore(c, old, entry)
  if (old:sub(1, 3) == "\239\187\191") ~= vim.bo[c.buf].bomb then
    c.finish("Restoring a change in UTF-8 BOM state is not supported")
    return
  end
  old = buffer.normalize(c.buf, old)
  local hunks, binary = diff.compute(old, c.current)
  if binary then
    c.finish("Binary hunks are not supported")
    return
  end
  choose(c, hunks, nil, function(hunk)
    confirm(c, hunk, function()
      local function apply()
        if not c.valid() then
          c.finish("File or session changed; action cancelled")
          return
        end
        local ok, err = pcall(buffer.revert, c.buf, hunk)
        if not ok then
          c.finish("Cannot restore hunk: " .. tostring(err))
          return
        end
        c.file.reviewed = false
        c.finish("Hunk restored in buffer; :w to save, u to undo", vim.log.levels.INFO)
        require("review.session").update_buffer(c.file)
      end
      if not entry then
        apply()
        return
      end
      git.index_entry(c.session.root, c.file.path, function(now, err)
        if not now then
          c.finish(err)
        elseif not entry_equal(now, entry) then
          c.finish("Git index changed; retry the discard")
        else
          apply()
        end
      end)
    end)
  end)
end

local function change_index(c, entry)
  local cached = c.action == "unstage_hunk"
  local function fetch()
    git.hunk_diff(c.session.root, c.file.path, cached, function(patch, err)
      if not patch then
        c.finish(err)
        return
      end
      if not c.valid() then
        c.finish("File or session changed; retry the action")
        return
      end
      if not cached and patch.header == "" and not entry.oid and c.disk then
        local stat = vim.uv.fs_stat(c.path)
        patch = git.addition(c.file.path, c.disk, bit.band(stat.mode, 73) ~= 0)
      end
      local old_oid, new_oid = patch.header:match("\nindex (%x+)%.%.(%x+)")
      local patch_oid = cached and new_oid or old_oid
      local intent_to_add = not cached
        and patch_oid
        and patch_oid:match("^0+$")
        and patch.header:find("new file mode", 1, true)
      if
        patch_oid
        and not intent_to_add
        and (
          (entry.oid and patch_oid ~= entry.oid) or (not entry.oid and not patch_oid:match("^0+$"))
        )
      then
        c.finish("Git index changed while calculating hunks; retry the action")
        return
      end
      if #patch.hunks == 0 and patch.header ~= "" then
        patch.hunks = {
          {
            metadata = true,
            old_start = 0,
            old_count = 0,
            new_start = 1,
            new_count = 0,
            lines = {},
          },
        }
      end
      local function select_hunk(unstaged)
        choose(c, patch.hunks, unstaged, function(hunk)
          local text = patch.header .. (hunk.metadata and "" or diff.patch(hunk))
          index.apply(
            c.session.root,
            c.file.path,
            entry,
            text,
            cached,
            c.valid,
            function(ok, apply_err)
              c.finish(
                ok and (names[c.action] .. "d hunk") or apply_err,
                ok and vim.log.levels.INFO or vim.log.levels.ERROR
              )
              if ok and require("review.session").active == c.session then
                require("review.session").refresh()
              end
            end
          )
        end)
      end
      if cached and c.file.status ~= "D" then
        git.index_text(c.session.root, entry, function(old, text_err)
          if not old then
            c.finish(text_err)
            return
          end
          local unstaged, binary = diff.compute(buffer.normalize(c.buf, old), c.current)
          if binary then
            c.finish("Binary hunks are not supported")
          else
            select_hunk(unstaged)
          end
        end)
      else
        select_hunk()
      end
    end)
  end
  if cached then
    git.run(c.session.root, { "rev-parse", "--verify", "--quiet", "HEAD" }, function(head)
      entry.head = head and head:gsub("%s+$", "") or false
      fetch()
    end)
  else
    fetch()
  end
end

function M.run(action)
  assert(names[action], "Unknown review hunk action")
  local c = context(action)
  if not c then
    return
  end
  if action == "restore_base_hunk" then
    git.content(c.session.root, c.session.commit, c.file, function(old, err)
      if not old then
        c.finish(err)
      else
        restore(c, old)
      end
    end)
    return
  end
  git.index_entry(c.session.root, c.file.path, function(entry, err)
    if not entry then
      c.finish(err)
      return
    end
    if action == "discard_hunk" then
      git.index_text(c.session.root, entry, function(old, text_err)
        if not old then
          c.finish(text_err)
        else
          restore(c, old, entry)
        end
      end)
    else
      change_index(c, entry)
    end
  end)
end
return M
