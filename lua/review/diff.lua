local M = {}

---@class ReviewLine
---@field kind 'context'|'add'|'delete'
---@field text string
---@field no_newline? boolean

---@class ReviewHunk
---@field old_start integer
---@field old_count integer
---@field new_start integer
---@field new_count integer
---@field lines ReviewLine[]

---@param patch string
---@return ReviewHunk[]
function M.parse(patch)
  local hunks, current = {}, nil
  local old_seen, new_seen = 0, 0
  for line in (patch .. "\n"):gmatch("([^\n]*)\n") do
    local os, oc, ns, nc = line:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os then
      current = {
        old_start = tonumber(os),
        old_count = oc == "" and 1 or tonumber(oc),
        new_start = tonumber(ns),
        new_count = nc == "" and 1 or tonumber(nc),
        lines = {},
      }
      hunks[#hunks + 1] = current
      old_seen, new_seen = 0, 0
    elseif current then
      local prefix = line:sub(1, 1)
      local kind = ({ ["+"] = "add", ["-"] = "delete", [" "] = "context" })[prefix]
      if kind and (old_seen < current.old_count or new_seen < current.new_count) then
        current.lines[#current.lines + 1] = { kind = kind, text = line:sub(2) }
        if kind ~= "add" then
          old_seen = old_seen + 1
        end
        if kind ~= "delete" then
          new_seen = new_seen + 1
        end
      elseif prefix == "\\" and current.lines[#current.lines] then
        current.lines[#current.lines].no_newline = true
      end
    end
  end
  return hunks
end

function M.compute(old, new)
  if old:find("\0", 1, true) or new:find("\0", 1, true) then
    return {}, true
  end
  return M.parse(
    vim.diff(old, new, { result_type = "unified", ctxlen = 0, algorithm = "histogram" })
  ),
    false
end

-- A pure deletion's new_start is the line BEFORE the deletion, unlike additions.
function M.row(hunk, count)
  local row = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
  return math.max(0, math.min(row, count - 1))
end
return M
