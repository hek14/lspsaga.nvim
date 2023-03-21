local api, lsp, fn, uv = vim.api, vim.lsp, vim.fn, vim.loop
local config = require('lspsaga').config
local ui = config.ui
local window = require('lspsaga.window')
local libs = require('lspsaga.libs')

local finder = {}
local ctx = {}

local function clean_ctx()
  for k, _ in pairs(ctx) do
    ctx[k] = nil
  end
end

finder.__index = finder
finder.__newindex = function(t, k, v)
  rawset(t, k, v)
end

local function get_titles(index)
  local t = {
    '● Definition',
    '● Implements',
    '● References',
  }
  return t[index]
end

local function methods(index)
  local t = {
    'textDocument/definition',
    'textDocument/implementation',
    'textDocument/references',
  }

  return index and t[index] or t
end

local function get_file_icon(bufnr)
  local res = libs.icon_from_devicon(vim.bo[bufnr].filetype)
  return res
end

local function supports_implement(buf)
  local support = false
  for _, client in ipairs(lsp.get_active_clients({ bufnr = buf })) do
    if client.supports_method('textDocument/implementation') then
      support = true
      break
    end
  end
  return support
end

function finder:lsp_finder()
  -- push a tag stack
  local pos = api.nvim_win_get_cursor(0)
  local main_buf = api.nvim_get_current_buf()
  self.main_win = api.nvim_get_current_win()
  local from = { main_buf, pos[1], pos[2], 0 }
  local items = { { tagname = fn.expand('<cword>'), from = from } }
  fn.settagstack(self.main_win, { items = items }, 't')

  self.request_status = {}

  local params = lsp.util.make_position_params()
  ---@diagnostic disable-next-line: param-type-mismatch
  local meths = methods()
  if not supports_implement(self.main_buf) then
    self.request_status[meths[2]] = true
    ---@diagnostic disable-next-line: param-type-mismatch
    table.remove(meths, 2)
  end
  ---@diagnostic disable-next-line: param-type-mismatch
  for _, method in ipairs(meths) do
    self:do_request(params, method)
  end
  -- make a spinner
  self:loading_bar()
end

function finder:request_done()
  local done = true
  ---@diagnostic disable-next-line: param-type-mismatch
  for _, method in ipairs(methods()) do
    if not self.request_status[method] then
      done = false
      break
    end
  end
  return done
end

function finder:loading_bar()
  local opts = {
    relative = 'cursor',
    height = 2,
    width = 20,
  }

  local content_opts = {
    contents = {},
    buftype = 'nofile',
    border = 'solid',
    highlight = {
      normal = 'FinderNormal',
      border = 'FinderBorder',
    },
    enter = false,
  }

  local spin_buf, spin_win = window.create_win_with_border(content_opts, opts)
  local spin_config = {
    spinner = {
      '█▁▁▁▁▁▁▁▁▁',
      '██▁▁▁▁▁▁▁▁',
      '███▁▁▁▁▁▁▁',
      '████▁▁▁▁▁▁',
      '█████▁▁▁▁▁',
      '██████▁▁▁▁',
      '███████▁▁▁',
      '████████▁▁ ',
      '█████████▁',
      '██████████',
    },
    interval = 50,
    timeout = config.request_timeout,
  }
  api.nvim_buf_set_option(spin_buf, 'modifiable', true)

  local spin_frame = 1
  local spin_timer = uv.new_timer()
  local start_request = uv.now()
  spin_timer:start(
    0,
    spin_config.interval,
    vim.schedule_wrap(function()
      spin_frame = spin_frame == 11 and 1 or spin_frame
      local msg = ' LOADING' .. string.rep('.', spin_frame > 3 and 3 or spin_frame)
      local spinner = ' ' .. spin_config.spinner[spin_frame]
      pcall(api.nvim_buf_set_lines, spin_buf, 0, -1, false, { msg, spinner })
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, 'FinderSpinnerTitle', 0, 0, -1)
      pcall(api.nvim_buf_add_highlight, spin_buf, 0, 'FinderSpinner', 1, 0, -1)
      spin_frame = spin_frame + 1

      if uv.now() - start_request >= spin_config.timeout and not spin_timer:is_closing() then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then
          api.nvim_buf_delete(spin_buf, { force = true })
        end
        window.nvim_close_valid_window(spin_win)
        vim.notify('request timeout')
        self.request_status = nil
        return
      end

      if self:request_done() and not spin_timer:is_closing() then
        spin_timer:stop()
        spin_timer:close()
        if api.nvim_buf_is_loaded(spin_buf) then
          api.nvim_buf_delete(spin_buf, { force = true })
        end
        window.nvim_close_valid_window(spin_win)
        self:render_finder()
        self.request_status = nil
      end
    end)
  )
end

function finder:do_request(params, method)
  if method == methods(3) then
    params.context = { includeDeclaration = true }
  end
  lsp.buf_request_all(self.current_buf, method, params, function(results)
    local result = {}
    for _, res in ipairs(results or {}) do
      if res.result and not (res.result.uri or res.result.targetUri) then
        libs.merge_table(result, res.result)
      elseif res.result and (res.result.uri or res.result.targetUri) then
        result[#result + 1] = res.result
      end
    end

    if method == methods(1) then
      local col = api.nvim_win_get_cursor(0)[2]
      local range = result[1].targetRange or result[1].range
      if col >= range.start.character and col <= range['end'].character then
        self.request_status[method] = true
      end
      return
    end

    self:create_finder_data(result, method)
    self.request_status[method] = true
  end)
end

local function keymap_tip()
  local function gen_str(key)
    if type(key) == 'table' then
      return key[1]
    end
    return key
  end
  local keys = config.finder.keys

  return {
    '[edit] '
      .. gen_str(keys.edit)
      .. ' [vsplit] '
      .. gen_str(keys.vsplit)
      .. ' [split] '
      .. gen_str(keys.split)
      .. ' [tabe] '
      .. gen_str(keys.tabe)
      .. ' [tabnew] '
      .. gen_str(keys.tabnew)
      .. ' [quit] '
      .. gen_str(keys.quit)
      .. ' [jump] '
      .. gen_str(keys.jump_to),
  }
end

local function get_msg(method)
  local idx = libs.tbl_index(methods(), method)
  local t = {
    'No Definition Found',
    'No Implementation  Found',
    'No Reference  Found',
  }
  return t[idx]
end

function finder:create_finder_data(result, method)
  if #result == 1 and result[1].inline then
    return
  end
  if not self.lspdata then
    self.lspdata = {}
  end

  if not self.lspdata[method] then
    self.lspdata[method] = {}
    local title = get_titles(libs.tbl_index(methods(), method))
    self.lspdata[method]['title'] = title .. '  ' .. #result
  end
  local parent = self.lspdata[method]

  local wipe = false
  for _, res in ipairs(result) do
    local uri = res.targetUri or res.uri
    if not uri then
      vim.notify('[Lspsaga] miss uri in server response', vim.logs.level.WARN)
      return
    end
    local bufnr = vim.uri_to_bufnr(uri)
    local fname = vim.uri_to_fname(uri) -- returns lowercase drive letters on Windows
    if not api.nvim_buf_is_loaded(bufnr) then
      wipe = true
      --ignore the FileType event avoid trigger the lsp
      vim.opt.eventignore:append({ 'FileType' })
      fn.bufload(bufnr)
      --restore eventignore
      vim.opt.eventignore:remove({ 'FileType' })
      if not vim.tbl_contains(self.wipe_buffers, bufnr) then
        self.wipe_buffers[#self.wipe_buffers + 1] = bufnr
      end
    end

    if libs.iswin then
      fname = fname:gsub('^%l', fname:sub(1, 1):upper())
    end
    fname = table.concat(libs.get_path_info(bufnr, 2), libs.path_sep)

    local range = res.targetRange or res.range

    local node = {
      bufnr = bufnr,
      fname = fname,
      wipe = wipe,
      expand = false,
      row = range.start.line,
      col = range.start.character,
      winline = -1,
    }

    node.word = api.nvim_buf_get_text(
      node.bufnr,
      node.row,
      node.col,
      node.row + 1,
      range['end'].character,
      {}
    )[1]

    if not parent[node.fname] then
      parent[node.fname] = {}
      node.expand = true
    end
    parent[node.fname][#parent[node.fname] + 1] = node
  end
end

function finder:render_finder()
  self.wipe_buffers = {}
  local icon, icon_group = unpack(get_file_icon(api.nvim_get_current_buf()))
  local indent = (' '):rep(2)
  self.bufnr = api.nvim_create_buf(false, false)
  local virt_hi = 'Finderlines'
  local ns_id = api.nvim_create_namespace('lspsagafinder')

  local width = 0
  for _, data in pairs(self.lspdata) do
    local lines = {}
    local virt_tbl = {}
    lines[#lines + 1] = vim.tbl_get(data, 'title')
    data.title = nil
    for _, buf_data in pairs(data) do
      local count = api.nvim_buf_line_count(self.bufnr)
      count = count == 1 and 0 or count
      for i, item in ipairs(buf_data) do
        if i == 1 then
          local fill = item.expand and indent .. ui.collapse .. ' ' or indent .. ui.expand .. ' '
          local symbol = i == #buf_data and ui.lines[1] or ui.lines[2]
          lines[#lines + 1] = fill .. icon .. item.fname .. ' ' .. #buf_data
          indent = (' '):rep(6)
          item.winline = #lines
          virt_tbl[#virt_tbl + 1] = { { symbol, virt_hi }, { ui.lines[4]:rep(1), virt_hi } }
        end
        if item.expand then
          lines[#lines + 1] = indent .. item.word
          item.winline = item.winline > -1 and item.winline or #lines
        end
      end

      api.nvim_buf_set_lines(self.bufnr, count, count, false, lines)
      for i, item in ipairs(virt_tbl) do
        api.nvim_buf_set_extmark(self.bufnr, ns_id, count + i, 0, {
          virt_text = item,
          virt_text_pos = 'overlay',
        })
      end
      local curwidth = window.get_max_content_length(lines)
      if curwidth > width then
        width = curwidth
      end

      indent = '  '
    end
  end

  if api.nvim_buf_line_count(self.bufnr) == 0 then
    clean_ctx()
    vim.notify('[Lspsaga] finder nothing to show', vim.logs.level.WARN)
    return
  end

  self:create_finder_win(width)
end

function finder:create_finder_win(width)
  self.group = api.nvim_create_augroup('lspsaga_finder', { clear = true })

  local opt = {
    relative = 'editor',
  }

  local max_height = math.floor(vim.o.lines * config.finder.max_height)
  local line_count = api.nvim_buf_line_count(self.bufnr)
  opt.height = line_count > max_height and max_height or line_count
  if opt.height <= 0 or not opt.height or config.finder.force_max_height then
    opt.height = max_height
  end
  opt.width = width

  local winline = fn.winline()
  if vim.o.lines - 6 - opt.height - winline <= 0 then
    api.nvim_win_call(self.main_win, function()
      vim.cmd('normal! zz')
      local keycode = api.nvim_replace_termcodes('6<C-e>', true, false, true)
      api.nvim_feedkeys(keycode, 'x', false)
    end)
  end
  winline = fn.winline()
  opt.row = winline + 1
  local wincol = fn.wincol()
  opt.col = fn.screencol() - math.floor(wincol * 0.4)

  local side_char = window.border_chars()['top'][config.ui.border]
  local normal_right_side = ' '
  local content_opts = {
    contents = {},
    filetype = 'lspsagafinder',
    bufhidden = 'wipe',
    bufnr = self.bufnr,
    enter = true,
    border_side = {
      ['right'] = config.ui.border == 'shadow' and '' or normal_right_side,
      ['righttop'] = config.ui.border == 'shadow' and '' or side_char,
      ['rightbottom'] = config.ui.border == 'shadow' and '' or side_char,
    },
    highlight = {
      border = 'finderBorder',
      normal = 'finderNormal',
    },
  }

  self.restore_opts = window.restore_option()
  _, self.winid = window.create_win_with_border(content_opts, opt)

  -- make sure close preview window by using wincmd
  api.nvim_create_autocmd('WinClosed', {
    buffer = self.bufnr,
    once = true,
    callback = function()
      local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
      if ok then
        pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1)
      end
      self:close_auto_preview_win()
      api.nvim_del_augroup_by_id(self.group)
      self:clean_data()
      clean_ctx()
    end,
  })

  -- self:set_cursor(def_scope, ref_scope, imp_scope)
  -- self:open_preview()

  api.nvim_create_autocmd('CursorMoved', {
    buffer = self.bufnr,
    callback = function()
      -- self:set_cursor(def_scope, ref_scope, imp_scope)
      -- self:open_preview()
    end,
  })

  -- if imp_scope then
  --   for i = imp_scope[1] + 1, imp_scope[2] - 1, 1 do
  --     local virt_texts = {}
  --     api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderFileName', i - 1, 0, -1)
  --     if icon_hl then
  --       api.nvim_buf_add_highlight(self.bufnr, -1, icon_hl, i - 1, 0, 4 + #icon)
  --     end

  --     if i == imp_scope[2] - 1 then
  --       virt_texts[#virt_texts + 1] = { ui.lines[1], virt_hi }
  --       virt_texts[#virt_texts + 1] = { ui.lines[4]:rep(3), virt_hi }
  --     else
  --       virt_texts[#virt_texts + 1] = { ui.lines[2], virt_hi }
  --       virt_texts[#virt_texts + 1] = { ui.lines[4]:rep(3), virt_hi }
  --     end

  --     api.nvim_buf_set_extmark(0, ns_id, i - 1, 0, {
  --       virt_text = virt_texts,
  --       virt_text_pos = 'overlay',
  --     })
  --   end
  -- end

  -- api.nvim_buf_set_extmark(0, ns_id, ref_scope[1] + 1, 0, {
  --   virt_text = { { ui.lines[3], virt_hi } },
  --   virt_text_pos = 'overlay',
  -- })

  -- for i = ref_scope[1] + 1, ref_scope[2] - 1 do
  --   local virt_texts = {}
  --   api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderFileName', i - 1, 0, -1)
  --   if icon_hl then
  --     api.nvim_buf_add_highlight(self.bufnr, -1, icon_hl, i - 1, 0, 4 + #icon)
  --   end

  --   if i == ref_scope[2] - 1 then
  --     virt_texts[#virt_texts + 1] = { ui.lines[1], virt_hi }
  --     virt_texts[#virt_texts + 1] = { ui.lines[4]:rep(3), virt_hi }
  --   else
  --     virt_texts[#virt_texts + 1] = { ui.lines[2], virt_hi }
  --     virt_texts[#virt_texts + 1] = { ui.lines[4]:rep(3), virt_hi }
  --   end

  --   api.nvim_buf_set_extmark(0, ns_id, i - 1, 0, {
  --     virt_text = virt_texts,
  --     virt_text_pos = 'overlay',
  --   })
  -- end

  -- libs.disable_move_keys(self.bufnr)
  -- self:apply_map()
  -- local len = string.len('Definition')

  -- for _, v in ipairs({ def_scope[1] - 1, ref_scope[1] - 1, imp_scope and imp_scope[1] - 1 or nil }) do
  --   api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderIcon', v, 0, 3)
  --   api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderType', v, 4, 4 + len)
  --   api.nvim_buf_add_highlight(self.bufnr, -1, 'FinderCount', v, 4 + len, -1)
  -- end
end

local function unpack_map()
  local map = {}
  for k, v in pairs(config.finder.keys) do
    if k ~= 'jump_to' and k ~= 'close_in_preview' then
      map[k] = v
    end
  end
  return map
end

function finder:apply_map()
  local opts = {
    buffer = self.bufnr,
    nowait = true,
    silent = true,
  }
  local unpacked = unpack_map()

  for action, map in pairs(unpacked) do
    if type(map) == 'string' then
      map = { map }
    end
    for _, key in pairs(map) do
      if key ~= 'quit' then
        vim.keymap.set('n', key, function()
          self:open_link(action)
        end, opts)
      end
    end
  end

  for _, key in pairs(config.finder.keys.quit) do
    vim.keymap.set('n', key, function()
      local ok, buf = pcall(api.nvim_win_get_buf, self.preview_winid)
      if ok then
        pcall(api.nvim_buf_clear_namespace, buf, self.preview_hl_ns, 0, -1)
      end
      window.nvim_close_valid_window({ self.winid, self.preview_winid, self.tip_winid or nil })
      self:clean_data()
      clean_ctx()
    end, opts)
  end

  vim.keymap.set('n', config.finder.keys.jump_to, function()
    if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
      local lnum = api.nvim_win_get_cursor(0)[1]
      api.nvim_set_current_win(self.preview_winid)
      local data = self.short_link[lnum]
      if data then
        api.nvim_win_set_cursor(0, { data.row + 1, data.col })
      end
    end
  end, opts)
end

local finder_ns = api.nvim_create_namespace('finder_select')

function finder:set_cursor(def_scope, ref_scope, imp_scope)
  local curline = api.nvim_win_get_cursor(0)[1]
  local icon = get_file_icon(self.main_buf)[1]
  local col = 4 + #icon

  local def_first = def_scope and def_scope[1] + 1 or -2
  local def_last = def_scope and def_scope[2] - 1 or -2
  local ref_first = ref_scope[1] + 1
  local ref_last = ref_scope[2] - 1

  local imp_first = imp_scope and imp_scope[1] + 1 or -2
  local imp_last = imp_scope and imp_scope[2] - 1 or -2

  local new_pos = {}

  if #new_pos > 0 then
    api.nvim_win_set_cursor(self.winid, new_pos)
  end

  local actual = api.nvim_win_get_cursor(0)[1] - 1
  if new_pos[1] == def_first then
    api.nvim_buf_add_highlight(0, finder_ns, 'FinderSelection', actual, 4 + #icon, -1)
  end

  api.nvim_buf_clear_namespace(0, finder_ns, 0, -1)
  api.nvim_buf_add_highlight(0, finder_ns, 'FinderSelection', actual, 4 + #icon, -1)
end

local function create_preview_window(finder_winid)
  if not finder_winid or not api.nvim_win_is_valid(finder_winid) then
    return
  end

  local opts = {
    relative = 'editor',
    no_size_override = true,
  }

  local winconfig = api.nvim_win_get_config(finder_winid)
  opts.row = winconfig.row[false]
  opts.height = winconfig.height

  local border_side = {}
  local top = window.combine_char()['top'][config.ui.border]
  local bottom = window.combine_char()['bottom'][config.ui.border]

  --in right
  if vim.o.columns - winconfig.col[false] - winconfig.width > config.finder.min_width then
    local adjust = config.ui.border == 'shadow' and -2 or 2
    opts.col = winconfig.col[false] + winconfig.width + adjust
    opts.width = vim.o.columns - opts.col - 2
    border_side = {
      ['lefttop'] = top,
      ['leftbottom'] = bottom,
    }
  --in left
  elseif winconfig.col[false] > config.finder.min_width then
    opts.width = math.floor(winconfig.col[false] * 0.8)
    local adjust = config.ui.border == 'shadow' and -2 or 0
    opts.col = winconfig.col[false] - opts.width - adjust
    border_side = {
      ['righttop'] = top,
      ['rightbottom'] = bottom,
    }
    api.nvim_win_set_config(finder_winid, {
      border = window.combine_border(config.ui.border, {
        ['lefttop'] = '',
        ['left'] = '',
        ['leftbottom'] = '',
      }, 'FinderBorder'),
    })
  end

  local content_opts = {
    contents = {},
    border_side = border_side,
    bufhidden = '',
    highlight = {
      border = 'FinderPreviewBorder',
      normal = 'FinderNormal',
    },
  }

  return window.create_win_with_border(content_opts, opts)
end

local function clear_preview_ns(ns, buf)
  pcall(api.nvim_buf_clear_namespace, buf, ns, 0, -1)
end

function finder:open_preview()
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    local before_buf = api.nvim_win_get_buf(self.preview_winid)
    clear_preview_ns(self.preview_hl_ns, before_buf)
  end

  local current_line = api.nvim_win_get_cursor(self.winid)[1]
  if not self.short_link[current_line] then
    return
  end

  local data = self.short_link[current_line]

  if not self.preview_winid or not api.nvim_win_is_valid(self.preview_winid) then
    self.preview_bufnr, self.preview_winid = create_preview_window(self.winid)
  end

  if not self.preview_winid then
    return
  end

  if data.content then
    if not data.bufnr then
      data.bufnr = self.preview_bufnr
    end
    api.nvim_win_set_buf(self.preview_winid, data.bufnr)
    api.nvim_set_option_value('bufhidden', '', { buf = self.preview_bufnr })
    vim.bo[self.preview_bufnr].modifiable = true
    api.nvim_buf_set_lines(self.preview_bufnr, 0, -1, false, data.content)
    vim.bo[self.preview_bufnr].modifiable = false
    return
  end

  if data.bufnr then
    api.nvim_win_set_buf(self.preview_winid, data.bufnr)
    if config.ui.title and fn.has('nvim-0.9') == 1 then
      local path = vim.split(data.link, libs.path_sep, { trimempty = true })
      local icon = get_file_icon(self.main_buf)
      api.nvim_win_set_config(self.preview_winid, {
        title = {
          { icon[1], icon[2] or 'TitleString' },
          { path[#path], 'TitleString' },
        },
        title_pos = 'center',
      })
    end
    api.nvim_set_option_value('winbar', '', { scope = 'local', win = self.preview_winid })
  end

  api.nvim_set_option_value(
    'winhl',
    'Normal:finderNormal,FloatBorder:finderPreviewBorder',
    { scope = 'local', win = self.preview_winid }
  )

  if data.row then
    api.nvim_win_set_cursor(self.preview_winid, { data.row + 1, data.col })
  end

  local lang = require('nvim-treesitter.parsers').ft_to_lang(vim.bo[self.main_buf].filetype)
  if fn.has('nvim-0.9') then
    vim.treesitter.start(data.bufnr, lang)
  else
    vim.bo[data.bufnr].syntax = 'on'
    pcall(
      ---@diagnostic disable-next-line: param-type-mismatch
      vim.cmd,
      string.format('syntax include %s syntax/%s.vim', '@' .. lang, vim.bo[self.main_buf].filetype)
    )
  end

  libs.scroll_in_preview(self.bufnr, self.preview_winid)

  if not self.preview_hl_ns then
    self.preview_hl_ns = api.nvim_create_namespace('finderPreview')
  end

  if data.row then
    api.nvim_buf_add_highlight(
      data.bufnr,
      self.preview_hl_ns,
      'finderPreviewSearch',
      data.row,
      data.col,
      data._end_col
    )
  end

  vim.keymap.set('n', config.finder.keys.close_in_preview, function()
    window.nvim_close_valid_window({ self.winid, self.preview_winid, self.tip_winid or nil })
    self:clean_data()
    clean_ctx()
  end, { buffer = data.bufnr, nowait = true, silent = true })

  api.nvim_create_autocmd('WinClosed', {
    group = self.group,
    buffer = data.bufnr,
    callback = function(opt)
      local curwin = api.nvim_get_current_win()
      if curwin == self.preview_winid then
        clear_preview_ns(self.preview_hl_ns, opt.buf)

        if self.winid and api.nvim_win_is_valid(self.winid) then
          api.nvim_set_current_win(self.winid)
          vim.defer_fn(function()
            self:open_preview()
          end, 0)
        end

        self.preview_winid = nil
        self.preview_bufnr = nil
      end
    end,
  })
end

function finder:close_auto_preview_win()
  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    api.nvim_win_close(self.preview_winid, true)
    self.preview_winid = nil
  end
end

function finder:open_link(action)
  local current_line = api.nvim_win_get_cursor(0)[1]

  if not self.short_link[current_line] then
    vim.notify('[LspSaga] no file link in current line', vim.log.levels.WARN)
    return
  end

  local data = self.short_link[current_line]

  if self.preview_winid and api.nvim_win_is_valid(self.preview_winid) then
    local pbuf = api.nvim_win_get_buf(self.preview_winid)
    clear_preview_ns(self.preview_hl_ns, pbuf)
  end
  local restore_opts

  if not data.wipe then
    restore_opts = self.restore_opts
  end

  window.nvim_close_valid_window({ self.winid, self.preview_winid, self.tip_winid or nil })
  self:clean_data()

  -- if buffer not saved save it before jump
  if vim.bo.modified then
    vim.cmd('write')
  end

  local special = { 'edit', 'tab', 'tabnew' }
  if vim.tbl_contains(special, action) and not data.wipe then
    local wins = fn.win_findbuf(data.bufnr)
    local winid = wins[#wins] or api.nvim_get_current_win()
    api.nvim_set_current_win(winid)
    api.nvim_win_set_buf(winid, data.bufnr)
  else
    vim.cmd(action .. ' ' .. uv.fs_realpath(data.link))
  end

  if restore_opts then
    restore_opts.restore()
  end

  if data.row then
    api.nvim_win_set_cursor(0, { data.row + 1, data.col })
  end
  local width = #api.nvim_get_current_line()
  if not width or width <= 0 then
    width = 10
  end
  if data.row then
    libs.jump_beacon({ data.row, 0 }, width)
  end
  clean_ctx()
end

function finder:clean_data()
  for _, buf in ipairs(self.wipe_buffers or {}) do
    api.nvim_buf_delete(buf, { force = true })
    pcall(vim.keymap.del, 'n', config.finder.keys.close_in_preview, { buffer = buf })
  end

  for _, id in ipairs(self.match_ids or {}) do
    pcall(vim.fn.matchdelete, id)
  end

  if self.preview_bufnr and api.nvim_buf_is_loaded(self.preview_bufnr) then
    api.nvim_buf_delete(self.preview_bufnr, { force = true })
  end

  if self.group then
    pcall(api.nvim_del_augroup_by_id, self.group)
  end
end

return setmetatable(ctx, finder)
