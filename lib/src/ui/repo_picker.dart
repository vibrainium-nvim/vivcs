import 'package:nvim/nvim.dart';

import '../vcs/vcs.dart';

/// Floating dropdown window for selecting a repository from the discovered list.
class RepoPicker {
  final Nvim nvim;
  int? _buf;
  int? _win;
  List<Repo> _repos = const [];
  Future<void> Function(int index)? _onSelect;

  RepoPicker(this.nvim);

  bool get isOpen => _win != null;
  int? get windowId => _win;
  int? get bufferId => _buf;

  Future<void> open({
    required List<Repo> repos,
    required int activeIndex,
    required Future<void> Function(int index) onSelect,
  }) async {
    await close();
    if (repos.isEmpty) {
      await nvim.notify('No repositories discovered in workspace');
      return;
    }

    _repos = repos;
    _onSelect = onSelect;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    final lines = <String>[];
    var maxLineLen = 28;
    for (var i = 0; i < repos.length; i++) {
      final r = repos[i];
      final prefix = i == activeIndex ? ' ● ' : '   ';
      final line = '$prefix${r.name} (${r.vcs.name} • ${r.head}) ';
      lines.add(line);
      if (line.length > maxLineLen) {
        maxLineLen = line.length;
      }
    }

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: lines);
    await nvim.bufSetOption(buf, 'modifiable', false);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'vivcs-picker');

    final width = maxLineLen.clamp(28, 60);
    final height = lines.length.clamp(1, 15);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': 1,
      'col': 1,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Select Repository ',
      'title_pos': 'center',
    });
    _win = win;

    await nvim.winSetOption(win, 'cursorline', true);
    final targetRow = (activeIndex >= 0 && activeIndex < lines.length)
        ? activeIndex + 1
        : 1;
    await nvim.winSetCursor(win, targetRow, 0);
    await nvim.command('stopinsert');

    for (final mode in ['n', 'i']) {
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<LeftMouse>',
        "<LeftMouse><Cmd>lua require('vibrainium').action('picker_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<2-LeftMouse>',
        "<LeftMouse><Cmd>lua require('vibrainium').action('picker_click')<CR>",
      );
      await nvim.bufSetKeymap(
        buf,
        mode,
        '<CR>',
        "<Cmd>lua require('vibrainium').action('picker_confirm')<CR>",
      );
      for (final cancelKey in ['<Esc>', '<C-c>']) {
        await nvim.bufSetKeymap(
          buf,
          mode,
          cancelKey,
          "<Cmd>lua require('vibrainium').action('picker_close')<CR>",
        );
      }
    }
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('vibrainium').action('picker_close')<CR>",
    );

    try {
      await nvim.execLua(
        '''
local buf = ...
local grp = vim.api.nvim_create_augroup('VivcsRepoPicker', { clear = true })
vim.api.nvim_create_autocmd({ 'WinLeave', 'BufLeave' }, {
  group = grp,
  buffer = buf,
  once = true,
  callback = function()
    vim.schedule(function()
      require('vibrainium').action('picker_close')
    end)
  end,
})
''',
        [buf],
      );
    } catch (_) {}
  }

  Future<void> handleClick() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final mousePos = await nvim.getMousePos();
    if (mousePos != null) {
      if (mousePos.winId != win) {
        await close();
        return;
      }
      if (mousePos.line >= 1 && mousePos.line <= _repos.length) {
        await selectIndex(mousePos.line - 1);
        return;
      }
    }
    await confirm();
  }

  Future<void> confirm() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final (row, _) = await nvim.winGetCursor(win);
    await selectIndex(row - 1);
  }

  Future<void> selectIndex(int idx) async {
    final callback = _onSelect;
    final repoCount = _repos.length;
    await close();
    if (callback != null && idx >= 0 && idx < repoCount) {
      await callback(idx);
    }
  }

  Future<void> close() async {
    final win = _win;
    final buf = _buf;
    _win = null;
    _buf = null;
    if (buf != null) {
      try {
        await nvim.execLua(
          "pcall(vim.api.nvim_del_augroup_by_name, 'VivcsRepoPicker')",
        );
      } catch (_) {}
    }
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
