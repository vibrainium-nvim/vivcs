import 'package:nvim/nvim.dart';

/// Floating window for writing and submitting a commit message.
class CommitBox {
  final Nvim nvim;
  int? _buf;
  int? _win;
  Future<void> Function(String message)? _onSubmit;

  CommitBox(this.nvim);

  bool get isOpen => _win != null;

  Future<void> open({
    required String repoName,
    required Future<void> Function(String message) onSubmit,
  }) async {
    await close();
    _onSubmit = onSubmit;

    final buf = await nvim.createBuf(listed: false, scratch: true);
    _buf = buf;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetOption(buf, 'buftype', 'nofile');
    await nvim.bufSetOption(buf, 'bufhidden', 'wipe');
    await nvim.bufSetOption(buf, 'filetype', 'gitcommit');
    await nvim.bufSetLines(buf, lines: ['']);

    final editorWidth = await nvim.getEditorWidth();
    final editorHeight = await nvim.getEditorHeight();
    final width = (editorWidth * 0.5).round().clamp(40, 72);
    const height = 6;
    final row = ((editorHeight - height) / 2).floor().clamp(1, editorHeight);
    final col = ((editorWidth - width) / 2).floor().clamp(1, editorWidth);

    final win = await nvim.openWin(buf, true, {
      'relative': 'editor',
      'row': row,
      'col': col,
      'width': width,
      'height': height,
      'style': 'minimal',
      'border': 'rounded',
      'title': ' Commit ($repoName) — <C-s> submit, q cancel ',
      'title_pos': 'center',
    });
    _win = win;

    await nvim.bufSetKeymap(
      buf,
      'n',
      '<C-s>',
      "<Cmd>lua require('vibrainium').action('commit_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'i',
      '<C-s>',
      "<Esc><Cmd>lua require('vibrainium').action('commit_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<CR>',
      "<Cmd>lua require('vibrainium').action('commit_submit')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      'q',
      "<Cmd>lua require('vibrainium').action('commit_close')<CR>",
    );
    await nvim.bufSetKeymap(
      buf,
      'n',
      '<Esc>',
      "<Cmd>lua require('vibrainium').action('commit_close')<CR>",
    );
  }

  Future<void> submit() async {
    final buf = _buf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      await close();
      return;
    }
    final lines = await nvim.bufGetLines(buf);
    final msg = lines.join('\n').trim();
    final callback = _onSubmit;
    await close();
    if (msg.isEmpty) {
      await nvim.notify('Commit aborted: empty message', level: 3);
      return;
    }
    if (callback != null) {
      await callback(msg);
    }
  }

  Future<void> close() async {
    final win = _win;
    _win = null;
    _buf = null;
    if (win != null) {
      try {
        if (await nvim.winIsValid(win)) {
          await nvim.winClose(win, force: true);
        }
      } catch (_) {}
    }
  }
}
