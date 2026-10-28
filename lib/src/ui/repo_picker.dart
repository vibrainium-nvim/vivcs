import 'package:nvim/nvim.dart';

import '../vcs/vcs.dart';

/// Floating dropdown window for selecting a repository from the discovered list.
class RepoPicker {
  final Nvim nvim;
  int? _win;
  List<Repo> _repos = const [];
  Future<void> Function(int index)? _onSelect;

  RepoPicker(this.nvim);

  bool get isOpen => _win != null;

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
    await nvim.bufSetOption(buf, 'filetype', 'viff-picker');

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

    await nvim.bufSetKeymap(
      buf,
      'n',
      '<CR>',
      "<Cmd>lua require('vibrainium').action('picker_confirm')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('vibrainium').action('picker_close')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<Esc>',
      "<Cmd>lua require('vibrainium').action('picker_close')<CR>",
    );
  }

  Future<void> confirm() async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) {
      await close();
      return;
    }
    final (row, _) = await nvim.winGetCursor(win);
    final idx = row - 1;
    final callback = _onSelect;
    final repoCount = _repos.length;
    await close();
    if (callback != null && idx >= 0 && idx < repoCount) {
      await callback(idx);
    }
  }

  Future<void> close() async {
    final win = _win;
    _win = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
