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
  final Set<int> validWins = {1};
  final Map<int, Map<String, Object?>> winConfigs = {};
  final Map<int, Map<String, Object?>> winOptions = {};
  final Map<int, (int, int)> cursors = {};
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
        return null;
      case 'nvim_create_buf':
        final id = _nextBuf++;
        bufLines[id] = [];
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
        return null;
      case 'nvim_buf_set_keymap':
        return null;
      case 'nvim_buf_clear_namespace':
        return null;
      case 'nvim_buf_set_extmark':
        return 1;
      case 'nvim_open_win':
        final config = (params[2] as Map).cast<String, Object?>();
        final win = _nextWin++;
        validWins.add(win);
        winConfigs[win] = config;
        cursors[win] = (1, 0);
        return MsgpackExt(1, MsgpackCodec.encode(win));
      case 'nvim_win_is_valid':
        return validWins.contains(params[0] as int);
      case 'nvim_win_close':
        validWins.remove(params[0] as int);
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
      case 'nvim_set_current_win':
        return null;
      case 'nvim_list_wins':
        return validWins.toList();
      case 'nvim_call_function':
        if (params[0] == 'getcwd') return cwd;
        return null;
      case 'nvim_get_option_value':
        if (params[0] == 'columns') return 120;
        if (params[0] == 'lines') return 40;
        return null;
      case 'nvim_notify':
        notifications.add(params[0].toString());
        return null;
      case 'nvim_command':
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
  group('ViffSidebar integration', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('viff_test_');
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

      final sidebar = ViffSidebar(
        nvim: Nvim(server.clientSession),
        vcsList: [git, svn],
      );

      await server.serverSession.request('viff_action', ['open']);
      expect(sidebar.repos, hasLength(2));
      expect(sidebar.activeRepo?.name, 'alpha_git');
      expect(server.winConfigs[100]!['style'], 'minimal');
      expect(server.winOptions[100]!['number'], isFalse);
      expect(server.winOptions[100]!['relativenumber'], isFalse);
      expect(server.winOptions[100]!['signcolumn'], 'no');
      expect(server.winOptions[100]!['foldcolumn'], '0');
      expect(server.winOptions[100]!['statuscolumn'], '');

      // Verify Git repo shows Staged section
      final gitLines = server.bufLines[1]!;
      expect(gitLines.first, contains('alpha_git (git • main) ▾'));
      expect(gitLines.any((l) => l.contains('Staged')), isTrue);

      // Move cursor to the unstaged file line and trigger stage
      final fileLineIdx = gitLines.indexWhere((l) => l.contains('M a.dart'));
      expect(fileLineIdx, greaterThan(0));
      server.cursors[100] = (fileLineIdx + 1, 0);
      await server.serverSession.request('viff_action', ['stage']);
      expect(stagedCalls, hasLength(1));
      expect(stagedCalls.first, ['add', '--', 'lib/a.dart']);

      // Open Repo Picker from line 1 (<CR> on RepoHeaderNode) and switch to beta_svn
      server.cursors[100] = (1, 0);
      await server.serverSession.request('viff_action', ['enter']);
      // Floating picker window is win 101; select 2nd repo (row 2)
      server.cursors[101] = (2, 0);
      await server.serverSession.request('viff_action', ['picker_confirm']);

      expect(sidebar.activeRepo?.name, 'beta_svn');
      final svnLines = server.bufLines[1]!;
      expect(svnLines.first, contains('beta_svn (svn • r99) ▾'));
      expect(svnLines.any((l) => l.contains('Staged')), isFalse);
      expect(svnLines.any((l) => l.contains('M svn_file.dart')), isTrue);

      // Verify hot reload RPC action succeeds and notifies Neovim
      await server.serverSession.request('viff_action', ['reload']);
      expect(server.notifications, contains('[viff] Hot reloaded'));

      await server.dispose();
    });
  });
}
