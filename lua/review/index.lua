local git = require("review.git")
local M = {}

function M.read(path)
  local fd, err = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil, err
  end
  local stat = vim.uv.fs_fstat(fd)
  local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data, read_err
end

-- Git's normal index.lock protects against other Git writers. Apply to a private
-- alternate index under that lock, then atomically publish it, or abandon it.
-- This also lets closing a session abort an in-flight operation before publication.
function M.apply(root, path, expected, patch, reverse, valid, callback)
  git.run(root, { "rev-parse", "--git-path", "index" }, function(out, err)
    if not out then
      callback(nil, err)
      return
    end
    local index = out:gsub("\n$", "")
    if index:sub(1, 1) ~= "/" then
      index = root .. "/" .. index
    end
    local lock = index .. ".lock"
    local fd, lock_err = vim.uv.fs_open(lock, "wx", 438)
    if not fd then
      callback(nil, "Cannot lock Git index (another Git operation may be running): " .. lock_err)
      return
    end
    vim.uv.fs_close(fd)
    local function finish(ok, message)
      if not ok then
        vim.uv.fs_unlink(lock)
      end
      callback(ok, message)
    end
    local function publish()
      if not valid() then
        finish(nil, "File or session changed; operation cancelled")
        return
      end
      local renamed, rename_err = vim.uv.fs_rename(lock, index)
      if not renamed then
        finish(nil, rename_err)
      else
        finish(true)
      end
    end
    local function check_head(next_step)
      if expected.head == nil then
        next_step()
        return
      end
      git.run(root, { "rev-parse", "--verify", "--quiet", "HEAD" }, function(head)
        local now = head and head:gsub("%s+$", "") or false
        if now ~= expected.head then
          finish(nil, "HEAD changed; retry the operation")
        else
          next_step()
        end
      end)
    end
    local function apply()
      if not valid() then
        finish(nil, "File or session changed; operation cancelled")
        return
      end
      local args = { "apply", "--cached", "--unidiff-zero", "--whitespace=nowarn" }
      if reverse then
        args[#args + 1] = "--reverse"
      end
      args[#args + 1] = "-"
      git.run(root, args, function(result, apply_err)
        if not result then
          finish(nil, apply_err)
          return
        end
        check_head(publish)
      end, { stdin = patch, env = { GIT_INDEX_FILE = lock } })
    end
    git.index_entry(root, path, function(entry, entry_err)
      if not entry then
        finish(nil, entry_err)
        return
      end
      if entry.oid ~= expected.oid or entry.mode ~= expected.mode then
        finish(nil, "Git index changed; retry the operation")
        return
      end
      check_head(function()
        if vim.uv.fs_stat(index) then
          local copied, copy_err = vim.uv.fs_copyfile(index, lock)
          if not copied then
            finish(nil, copy_err)
            return
          end
          apply()
        else
          -- An unborn repository can have no index yet. Git cannot read a zero-byte index.
          -- read-tree creates the proper checksum for the repository's object format.
          -- Use a distinct alternate path; never remove the real index lock.
          local temporary = lock .. ".empty." .. tostring(vim.uv.hrtime())
          git.run(root, { "read-tree", "--empty" }, function(result, init_err)
            if not result then
              vim.uv.fs_unlink(temporary)
              finish(nil, init_err)
              return
            end
            local copied, copy_err = vim.uv.fs_copyfile(temporary, lock)
            vim.uv.fs_unlink(temporary)
            if not copied then
              finish(nil, copy_err)
              return
            end
            apply()
          end, { env = { GIT_INDEX_FILE = temporary } })
        end
      end)
    end)
  end)
end
return M
