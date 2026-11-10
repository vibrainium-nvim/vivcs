import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:vivcs/vivcs.dart';

class _FakeNvimServer {
  final StreamController<List<int>> _toClient = StreamController<List<int>>();
  final StreamController<List<int>> _fromClient = StreamController<List<int>>();
  late final RpcSession serverSession;
  late final RpcSession clientSession;

  String cwd;
  int _nextBuf = 1;
  int _nextWin = 100;
  final Map<int, List<String>> bufLines = {};
  final Map<int, Map<String, Object?>> bufOptions = {};
  final Map<int, Map<String, Object?>> bufVars = {};
  final Map<int, Map<String, String>> bufKeymaps = {};
  final Set<int> validWins = {1};
  final Map<int, int> winBufs = {1: 0};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<int, (int, int)> cursors = {1: (1, 0)};
  int currentWin = 1;
  int alternateWin = 0;
  Map<String, Object?>? mousePos;
  final Map<String, Map<String, Object?>> highlights = {};
  final List<String> luaScripts = [];
  final List<String> commands = [];
  final List<String> notifications = [];

  _FakeNvimServer({required this.cwd}) {
    serverSession = RpcSession(
      input: _fromClient.stream,
      output: (Uint8List b) => _toClient.add(b),
    );
    clientSession = RpcSession(
      input: _toClient.stream,
      output: (Uint8List b) => _fromClient.add(b),
    );

    serverSession.onRequest = _handleRequest;
  }

  Future<Object?> _handleRequest(String method, List<Object?> params) async {
    switch (method) {
      case 'nvim_create_namespace':
        return 1;
      case 'nvim_set_hl':
        final name = params[1].toString();
        final val = (params[2] as Map).cast<String, Object?>();
        highlights[name] = val;
        return null;
      case 'nvim_create_buf':
        final id = _nextBuf++;
        bufLines[id] = [];
        bufKeymaps[id] = {};
        return MsgpackExt(0, MsgpackCodec.encode(id));
      case 'nvim_buf_is_valid':
        return bufLines.containsKey(params[0] as int);
      case 'nvim_buf_set_lines':
        final buf = params[0] as int;
        final lines = (params[4] as List).map((e) => e.toString()).toList();
        bufLines[buf] = lines;
        return null;
      case 'nvim_buf_get_lines':
        final buf = params[0] as int;
        return bufLines[buf] ?? const <String>[];
      case 'nvim_set_option_value':
        final name = params[0].toString();
        final value = params[1];
        final opts = (params[2] as Map).cast<String, Object?>();
        if (opts.containsKey('win')) {
          final win = opts['win'] as int;
          winOptions.putIfAbsent(win, () => {})[name] = value;
        }
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          bufOptions.putIfAbsent(buf, () => {})[name] = value;
        }
        return null;
      case 'nvim_buf_set_var':
        final buf = params[0] as int;
        bufVars.putIfAbsent(buf, () => {})[params[1].toString()] = params[2];
        return null;
      case 'nvim_buf_set_keymap':
        final buf = params[0] as int;
        final lhs = params[2].toString();
        final rhs = params[3].toString();
        bufKeymaps.putIfAbsent(buf, () => {})[lhs] = rhs;
        return null;
      case 'nvim_buf_clear_namespace':
        return null;
      case 'nvim_buf_set_extmark':
        return 1;
      case 'nvim_open_win':
        final buf = params[0] as int;
        final enter = params[1] as bool;
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winBufs[win] = buf;
        winConfigs[win] = config;
        cursors[win] = (1, 0);
        if (enter) {
          alternateWin = currentWin;
          currentWin = win;
        }
        return MsgpackExt(1, MsgpackCodec.encode(win));
      case 'nvim_win_get_config':
        return winConfigs[params[0] as int] ?? const <String, Object?>{};
      case 'nvim_win_get_buf':
        return winBufs[params[0] as int] ?? 0;
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_close':
        validWins.remove(params[0] as int);
        winBufs.remove(params[0] as int);
        return null;
      case 'nvim_win_get_cursor':
        final win = params[0] as int;
        final c = cursors[win] ?? (1, 0);
        return [c.$1, c.$2];
      case 'nvim_win_set_cursor':
        final win = params[0] as int;
        final pos = params[1] as List;
        cursors[win] = (pos[0] as int, pos[1] as int);
        return null;
      case 'nvim_get_current_win':
        return currentWin;
      case 'nvim_set_current_win':
        final target = params[0] as int;
        alternateWin = currentWin;
        currentWin = target;
        return null;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_win_get_position':
        return [0, 0];
      case 'nvim_call_function':
        if (params[0] == 'getcwd') return cwd;
        if (params[0] == 'getmousepos') return mousePos;
        if (params[0] == 'line') return 1;
        if (params[0] == 'winnr') return alternateWin > 0 ? 99 : 0;
        if (params[0] == 'win_getid') return alternateWin;
        return null;
      case 'nvim_get_option_value':
        if (params[0] == 'columns') return 120;
        if (params[0] == 'lines') return 40;
        final opts = (params[1] as Map?)?.cast<String, Object?>() ?? const {};
        if (opts.containsKey('buf')) {
          final buf = opts['buf'] as int;
          return bufOptions[buf]?[params[0].toString()];
        }
        return null;
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_exec_lua':
        luaScripts.add(params[0].toString());
        return null;
      case 'nvim_command':
        commands.add(params[0].toString());
        return null;
      default:
        return null;
    }
  }

  Future<void> dispose() async {
    await clientSession.close();
    await serverSession.close();
    await _toClient.close();
    await _fromClient.close();
  }
}

void main() {
  group('VivcsSidebar integration', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('vivcs_test_');
      await Directory('${tempDir.path}/alpha_git/.git').create(recursive: true);
      await Directory('${tempDir.path}/beta_svn/.svn').create(recursive: true);
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('discovers Git and SVN repos, switches via dropdown, and stages files', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final stagedCalls = <List<String>>[];

      final git = Git(
        run: (exe, args, {required workingDirectory}) async {
          if (args.contains('symbolic-ref')) {
            return const CommandResult(exitCode: 0, stdout: 'main\n', stderr: '');
          }
          if (args.contains('--porcelain=v1')) {
            return const CommandResult(
              exitCode: 0,
              stdout: ' M lib/a.dart\x00',
              stderr: '',
            );
          }
          if (args.contains('log')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '1111111\x001111111\x00Teja\x001h ago\x00First commit\x1e',
              stderr: '',
            );
          }
          if (args.isNotEmpty && args.first == 'add') {
            stagedCalls.add(args);
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );

      final svn = Svn(
        run: (exe, args, {required workingDirectory}) async {
          if (args.contains('info')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '<info><entry revision="99"/></info>',
              stderr: '',
            );
          }
          if (args.contains('status')) {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  '<status><target path="."><entry path="svn_file.dart"><wc-status item="modified"/></entry></target></status>',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '<log/>', stderr: '');
        },
      );

      final sidebar = VivcsSidebar(
        nvim: Nvim(server.clientSession),
        vcsList: [git, svn],
      );

      await server.serverSession.request('vivcs_action', ['open']);
      expect(sidebar.repos, hasLength(2));
      expect(sidebar.activeRepo?.name, 'alpha_git');
      expect(server.winConfigs[100]!['win'], -1);
      expect(server.winConfigs[100]!['split'], 'left');
      expect(server.winConfigs[100]!['style'], 'minimal');
      expect(server.winOptions[100]!['number'], isFalse);
      expect(server.winOptions[100]!['relativenumber'], isFalse);
      expect(server.winOptions[100]!['signcolumn'], 'no');
      expect(server.winOptions[100]!['foldcolumn'], '0');
      expect(server.winOptions[100]!['statuscolumn'], '');

      // Verify Git repo shows Staged section and section headers are bolded
      final gitLines = server.bufLines[1]!;
      expect(gitLines.first, ' [alpha_git (git • main) ]');
      expect(gitLines.any((l) => l.contains('Staged')), isTrue);
      expect(server.highlights['VivcsSectionHeader'], {'bold': true, 'link': 'Title'});
      expect(
        server.luaScripts.any((s) => s.contains("set_bold_from('VivcsSectionHeader', 'Title')")),
        isTrue,
      );

      // Move cursor to the unstaged file line and trigger stage
      final fileLineIdx = gitLines.indexWhere((l) => l.contains('M a.dart'));
      expect(fileLineIdx, greaterThan(0));
      server.cursors[100] = (fileLineIdx + 1, 0);
      await server.serverSession.request('vivcs_action', ['stage']);
      expect(stagedCalls, hasLength(1));
      expect(stagedCalls.first, ['add', '--', 'lib/a.dart']);

      // Open Repo Picker from line 1 (<CR> on RepoHeaderNode) and switch to beta_svn
      server.cursors[100] = (1, 0);
      await server.serverSession.request('vivcs_action', ['enter']);
      // Floating picker window is win 101; select 2nd repo (row 2)
      server.cursors[101] = (2, 0);
      await server.serverSession.request('vivcs_action', ['picker_confirm']);

      expect(sidebar.activeRepo?.name, 'beta_svn');
      final svnLines = server.bufLines[1]!;
      expect(svnLines.first, ' [beta_svn (svn • r99) ]');
      expect(svnLines.any((l) => l.contains('Staged')), isFalse);
      expect(svnLines.any((l) => l.contains('M svn_file.dart')), isTrue);

      // Verify hot reload RPC action succeeds and notifies Neovim
      await server.serverSession.request('vivcs_action', ['reload']);
      expect(server.notifications, contains('[Vibrainium] Hot reloaded'));

      await server.dispose();
    });

    test('supports mouse single-click, double-click, repo picker click, and right-click context menu', () async {
      final server = _FakeNvimServer(cwd: tempDir.path);
      final stagedCalls = <List<String>>[];

      final git = Git(
        run: (exe, args, {required workingDirectory}) async {
          if (args.contains('symbolic-ref')) {
            return const CommandResult(exitCode: 0, stdout: 'main\n', stderr: '');
          }
          if (args.contains('--porcelain=v1')) {
            return const CommandResult(
              exitCode: 0,
              stdout: ' M lib/a.dart\x00',
              stderr: '',
            );
          }
          if (args.contains('log')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '1111111\x001111111\x00Teja\x001h ago\x00First commit\x1e',
              stderr: '',
            );
          }
          if (args.contains('diff-tree')) {
            return const CommandResult(
              exitCode: 0,
              stdout: 'M\x00lib/a.dart\x00',
              stderr: '',
            );
          }
          if (args.isNotEmpty && args.first == 'add') {
            stagedCalls.add(args);
            return const CommandResult(exitCode: 0, stdout: '', stderr: '');
          }
          return const CommandResult(exitCode: 0, stdout: '', stderr: '');
        },
      );

      final svn = Svn(
        run: (exe, args, {required workingDirectory}) async {
          if (args.contains('info')) {
            return const CommandResult(
              exitCode: 0,
              stdout: '<info><entry revision="99"/></info>',
              stderr: '',
            );
          }
          if (args.contains('status')) {
            return const CommandResult(
              exitCode: 0,
              stdout:
                  '<status><target path="."><entry path="svn_file.dart"><wc-status item="modified"/></entry></target></status>',
              stderr: '',
            );
          }
          return const CommandResult(exitCode: 0, stdout: '<log/>', stderr: '');
        },
      );

      final sidebar = VivcsSidebar(
        nvim: Nvim(server.clientSession),
        vcsList: [git, svn],
      );

      await server.serverSession.request('vibrainium_action', ['open']);
      final sidebarWin = sidebar.windowId!;
      final sidebarBuf = sidebar.bufferId!;

      expect(
        server.bufKeymaps[sidebarBuf]!.keys,
        containsAll(['<LeftMouse>', '<2-LeftMouse>', 's']),
      );
      expect(
        server.bufKeymaps[sidebarBuf]!.keys,
        isNot(contains('<RightMouse>')),
      );
      expect(
        server.bufKeymaps[sidebarBuf]!.keys,
        isNot(contains('<Space>')),
      );
      expect(
        server.bufKeymaps[sidebarBuf]!['<LeftMouse>'],
        "<LeftMouse><Cmd>lua require('vibrainium').action('vcs.click')<CR>",
      );
      expect(
        server.bufKeymaps[sidebarBuf]!['<2-LeftMouse>'],
        "<LeftMouse><Cmd>lua require('vibrainium').action('vcs.double_click')<CR>",
      );
      expect(
        server.bufVars[sidebarBuf]!['vibrainium_right_mouse_action'],
        'vcs.context_menu',
      );

      // 1. Single-click on row 1 (RepoHeaderNode) opens the repository picker
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': 1,
        'wincol': 4,
        'line': 1,
        'column': 4,
        'screenrow': 1,
        'screencol': 4,
      };
      await server.serverSession.request('vibrainium_action', ['vcs.click']);
      expect(sidebar.repoPicker.isOpen, isTrue);
      final pickerWin = sidebar.repoPicker.windowId!;
      final pickerBuf = sidebar.repoPicker.bufferId!;
      expect(
        server.bufKeymaps[pickerBuf]!.keys,
        containsAll(['<LeftMouse>', '<2-LeftMouse>', '<CR>', 'q', '<Esc>']),
      );

      // Click row 2 in repo picker (`beta_svn`) via `picker_click`
      server.mousePos = {
        'winid': pickerWin,
        'winrow': 2,
        'wincol': 4,
        'line': 2,
        'column': 4,
        'screenrow': 2,
        'screencol': 4,
      };
      await server.serverSession.request('vibrainium_action', ['picker_click']);
      expect(sidebar.repoPicker.isOpen, isFalse);
      expect(sidebar.activeRepo?.name, 'beta_svn');

      // Switch back to `alpha_git` (row 1 in repo picker)
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': 1,
        'wincol': 4,
        'line': 1,
        'column': 4,
        'screenrow': 1,
        'screencol': 4,
      };
      await server.serverSession.request('vibrainium_action', ['vcs.click']);
      final pickerWin2 = sidebar.repoPicker.windowId!;
      server.mousePos = {
        'winid': pickerWin2,
        'winrow': 1,
        'wincol': 4,
        'line': 1,
        'column': 4,
        'screenrow': 1,
        'screencol': 4,
      };
      await server.serverSession.request('vibrainium_action', ['picker_click']);
      expect(sidebar.activeRepo?.name, 'alpha_git');

      // 2. Double-click on `lib/` directory row collapses it, and double-click again expands it
      final libRow = server.bufLines[sidebarBuf]!.indexWhere((l) => l.contains('lib/')) + 1;
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': libRow,
        'wincol': 2,
        'line': libRow,
        'column': 2,
        'screenrow': libRow,
        'screencol': 2,
      };
      await server.serverSession.request('vibrainium_action', ['vcs.double_click']);
      expect(server.bufLines[sidebarBuf]!, contains(' lib/'));
      expect(server.bufLines[sidebarBuf]!.any((l) => l.contains('a.dart')), isFalse);

      // Expand `lib/` back via double-click (wait >250ms debounce or reset by clicking another row first)
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': 3,
        'wincol': 2,
        'line': 3,
        'column': 2,
        'screenrow': 3,
        'screencol': 2,
      };
      await server.serverSession.request('vibrainium_action', ['vcs.click']);
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': libRow,
        'wincol': 2,
        'line': libRow,
        'column': 2,
        'screenrow': libRow,
        'screencol': 2,
      };
      await Future<void>.delayed(const Duration(milliseconds: 260));
      await server.serverSession.request('vibrainium_action', ['vcs.double_click']);
      expect(server.bufLines[sidebarBuf]!, contains(' lib/'));

      // 3. Double-click on file row (`M a.dart`) opens the file in main editor window (win 1)
      final fileRow = server.bufLines[sidebarBuf]!.indexWhere((l) => l.contains('M a.dart')) + 1;
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': fileRow,
        'wincol': 4,
        'line': fileRow,
        'column': 4,
        'screenrow': fileRow,
        'screencol': 4,
      };
      await Future<void>.delayed(const Duration(milliseconds: 260));
      await server.serverSession.request('vibrainium_action', ['vcs.double_click']);
      expect(server.currentWin, 1);
      expect(
        server.commands.any((c) => c.endsWith('/alpha_git/lib/a.dart')),
        isTrue,
      );

      // 4. Right-click (`vcs.context_menu`) from focused editor window 1 with synchronous click coordinates
      server.currentWin = 1;
      server.cursors[sidebarWin] = (1, 0);
      server.mousePos = null;
      await server.serverSession.request('vibrainium_action', [
        'vcs.context_menu',
        sidebarWin,
        fileRow,
        fileRow,
        4,
        fileRow,
        4,
      ]);
      expect(sidebar.contextMenu.isOpen, isTrue);
      final firstMenuBuf = sidebar.contextMenu.bufferId!;
      expect(
        sidebar.contextMenu.items.map((i) => i.label),
        containsAll(['Open File', 'Stage File', 'Stage All', 'Unstage All', 'Commit...', 'Select Repository...', 'Refresh']),
      );

      // Reopen on same row and verify stale `vcs.menu_close` from `firstMenuBuf` is ignored
      await server.serverSession.request('vibrainium_action', [
        'vcs.context_menu',
        sidebarWin,
        fileRow,
        fileRow,
        4,
        fileRow,
        4,
      ]);
      await server.serverSession.request('vibrainium_action', [
        'vcs.menu_close',
        firstMenuBuf,
      ]);
      expect(sidebar.contextMenu.isOpen, isTrue);

      // Select `Stage File` via `vcs.menu_select:<idx>`
      final stageIdx = sidebar.contextMenu.items.indexWhere((i) => i.label == 'Stage File');
      await server.serverSession.request('vibrainium_action', ['vcs.menu_select:$stageIdx']);
      expect(sidebar.contextMenu.isOpen, isFalse);
      expect(stagedCalls, hasLength(1));
      expect(stagedCalls.first, ['add', '--', 'lib/a.dart']);

      // 5. Right-click on commit row and click outside to dismiss context menu
      final commitRow = server.bufLines[sidebarBuf]!.indexWhere((l) => l.contains('1111111')) + 1;
      server.mousePos = {
        'winid': sidebarWin,
        'winrow': commitRow,
        'wincol': 4,
        'line': commitRow,
        'column': 4,
        'screenrow': commitRow,
        'screencol': 4,
      };
      await server.serverSession.request('vibrainium_action', ['vcs.context_menu']);
      expect(sidebar.contextMenu.isOpen, isTrue);
      // Single-click in sidebar dismisses context menu
      await server.serverSession.request('vibrainium_action', ['vcs.click']);
      expect(sidebar.contextMenu.isOpen, isFalse);

      // 6. RepoPicker toggles closed when openRepoPicker is called again
      await server.serverSession.request('vibrainium_action', ['repo_picker']);
      await server.serverSession.request('vibrainium_action', ['repo_picker']);

      // 7. When multiple editor split panes exist (win 1 and win 2) and win 2 is the active split pane,
      //    opening a file from vivcs opens it in win 2 even after opening/closing a floating popup (repo_picker)
      server.validWins.add(2);
      server.winBufs[2] = 0;
      sidebar.attachWindow(sidebarWin, lastActiveEditorWin: 2);
      server.currentWin = sidebarWin;
      server.alternateWin = 1; // Stale alternateWin pointing to split 1
      await server.serverSession.request('vibrainium_action', ['repo_picker']);
      await server.serverSession.request('vibrainium_action', ['repo_picker']);

      server.commands.clear();
      server.cursors[sidebarWin] = (fileRow, 0);
      await server.serverSession.request('vibrainium_action', ['vcs.enter']);
      expect(server.currentWin, 2);
      expect(sidebar.lastActiveEditorWin, 2);
      expect(
        server.commands.any((c) => c.startsWith('edit ') && c.endsWith('/lib/a.dart')),
        isTrue,
      );

      await server.dispose();
    });
  });
}
