local diff = require("delta.diff")
local git = require("delta.git")
local buffer = require("delta.buffer")
local M = {}

-- Only index lines that survive unchanged in the buffer may be shown as staged.
-- A later unstaged replacement must not inherit the staged marker underneath it.
function M.rows(staged, unstaged, count)
  local result = { lines = {}, deletions = {} }
  local function unchanged(line)
    for _, hunk in ipairs(unstaged) do
      if
        hunk.old_count > 0
        and line >= hunk.old_start
        and line < hunk.old_start + hunk.old_count
      then
        return false
      end
    end
    return true
  end
  for _, hunk in ipairs(staged) do
    local line = hunk.new_start
    for _, entry in ipairs(hunk.lines) do
      if entry.kind == "add" and unchanged(line) then
        local target = diff.map_line(line, unstaged)
        if target >= 1 and target <= count then
          result.lines[target - 1] = true
        end
      end
      if entry.kind ~= "delete" then
        line = line + 1
      end
    end
    if hunk.new_count == 0 then
      local anchor = hunk.new_start + 1
      local clean = unchanged(anchor)
      for _, change in ipairs(unstaged) do
        if
          change.new_count == 0
          and change.old_start <= anchor
          and change.old_start + change.old_count >= anchor
        then
          clean = false
        end
        if change.old_count == 0 and change.old_start == hunk.new_start then
          clean = false
        end
      end
      if clean then
        local row = math.max(0, math.min(diff.map_line(anchor, unstaged) - 1, count - 1))
        result.deletions[row] = true
      end
    end
  end
  return result
end

function M.load(root, file, buf, callback)
  git.index_entry(root, file.path, function(entry)
    if not entry then
      callback(nil)
      return
    end
    git.index_text(root, entry, function(index_text)
      if not index_text or not vim.api.nvim_buf_is_loaded(buf) then
        callback(nil)
        return
      end
      git.hunk_diff(root, file.path, true, function(patch)
        if not patch or not vim.api.nvim_buf_is_loaded(buf) then
          callback(nil)
          return
        end
        local oid = patch.header:match("\nindex %x+%.%.(%x+)")
        if
          oid and ((entry.oid and oid ~= entry.oid) or (not entry.oid and not oid:match("^0+$")))
        then
          callback(nil)
          return
        end
        local unstaged, binary = diff.compute(buffer.normalize(buf, index_text), buffer.text(buf))
        callback(
          not binary and M.rows(patch.hunks, unstaged, vim.api.nvim_buf_line_count(buf)) or nil
        )
      end)
    end)
  end)
end
return M
