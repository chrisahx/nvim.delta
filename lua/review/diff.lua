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

-- Serialize one hunk without altering Git's file header or newline markers.
function M.patch(hunk)
  local lines = {
    string.format(
      "@@ -%d,%d +%d,%d @@",
      hunk.old_start,
      hunk.old_count,
      hunk.new_start,
      hunk.new_count
    ),
  }
  local prefixes = { add = "+", delete = "-", context = " " }
  for _, line in ipairs(hunk.lines) do
    lines[#lines + 1] = prefixes[line.kind] .. line.text
    if line.no_newline then
      lines[#lines + 1] = "\\ No newline at end of file"
    end
  end
  return table.concat(lines, "\n") .. "\n"
end

-- Undo a zero-context hunk in a text snapshot, preserving final-newline state.
function M.revert(current, hunk)
  local records = {}
  for content, newline in current:gmatch("([^\n]*)(\n?)") do
    if content ~= "" or newline ~= "" then
      records[#records + 1] = content .. newline
    end
  end
  local start = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
  for _ = 1, hunk.new_count do
    table.remove(records, start + 1)
  end
  local offset = 0
  for _, line in ipairs(hunk.lines) do
    if line.kind == "delete" then
      offset = offset + 1
      table.insert(records, start + offset, line.text .. (line.no_newline and "" or "\n"))
    end
  end
  return table.concat(records)
end

-- Map an index line to the working buffer through freshly computed unstaged hunks.
function M.map_line(line, hunks)
  local offset = 0
  for _, hunk in ipairs(hunks) do
    local first = hunk.old_count == 0 and hunk.old_start + 1 or hunk.old_start
    if line < first then
      break
    end
    if hunk.old_count > 0 and line < first + hunk.old_count then
      local target = hunk.new_count == 0 and hunk.new_start + 1 or hunk.new_start
      return target + math.min(line - first, math.max(0, hunk.new_count - 1))
    end
    offset = offset + hunk.new_count - hunk.old_count
  end
  return math.max(1, line + offset)
end

-- A pure deletion's new_start is the line BEFORE the deletion, unlike additions.
function M.row(hunk, count)
  local row = hunk.new_count == 0 and hunk.new_start or hunk.new_start - 1
  return math.max(0, math.min(row, count - 1))
end
return M
