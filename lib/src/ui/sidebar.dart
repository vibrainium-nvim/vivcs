import 'dart:io';

import 'package:nvim/nvim.dart';

import '../vcs/vcs.dart';
import 'commit_box.dart';
import 'repo_picker.dart';
import 'tree.dart';

class ViffSidebar {
  final Nvim nvim;
  final List<Vcs> vcsList;
  final int sidebarWidth;
  final Map<String, String> extraKeymaps;

  final SidebarTreeState treeState = SidebarTreeState();
  late final RepoPicker _repoPicker = RepoPicker(nvim);
  late final CommitBox _commitBox = CommitBox(nvim);

  static const Set<String> _nonEditorFiletypes = {
    'viworkspace',
    'viff',
    'viproblems',
    'viproblems-detail',
    'vibrainium-tabbar',
    'vibrainium-bottom-tabbar',
    'viworkspace-prompt',
    'viworkspace-confirm',
    'viworkspace-menu',
  };

  int? _nsId;
  int? _buf;
  int? _win;
  int? _lastActiveEditorWin;
  Set<int> _excludedWindows = const {};
  bool _highlightsInitialized = false;

  List<Repo> _repos = [];
  int _activeRepoIndex = 0;
  RepoStatus _status = const RepoStatus();
  List<Commit> _commits = const [];
  RenderedTree? _rendered;

  ViffSidebar({
    required this.nvim,
    required this.vcsList,
    this.sidebarWidth = 38,
    this.extraKeymaps = const {},
    bool bindRpc = true,
  }) {
    if (bindRpc) {
      nvim.rpc.onRequest = _handleRpc;
      nvim.rpc.onNotification = (method, params) async {
        await _handleRpc(method, params);
      };
    }
  }

  int? get bufferId => _buf;
  int? get windowId => _win;
  int? get lastActiveEditorWin => _lastActiveEditorWin;

  void attachWindow(
    int? win, {
    Set<int> excludedWins = const {},
    int? lastActiveEditorWin,
  }) {
    _win = win;
    _excludedWindows = excludedWins;
    if (lastActiveEditorWin != null && lastActiveEditorWin > 0) {
      _lastActiveEditorWin = lastActiveEditorWin;
    }
  }

  Repo? get activeRepo =>
      (_activeRepoIndex >= 0 && _activeRepoIndex < _repos.length)
          ? _repos[_activeRepoIndex]
          : null;

  List<Repo> get repos => List.unmodifiable(_repos);

  RenderedTree? get renderedTree => _rendered;

  Future<Object?> handleAction(String action) async {
    switch (action) {
      case 'open':
        await open();
        return true;
      case 'close':
        await close();
        return true;
      case 'toggle':
        await toggle();
        return true;
      case 'refresh':
        await refresh(rescanRepos: true);
        return true;
      case 'reload':
        await reload();
        return true;
      case 'repo_picker':
        await openRepoPicker();
        return true;
      case 'enter':
        await handleEnter();
        return true;
      case 'stage':
        await handleStage(stage: true);
        return true;
      case 'unstage':
        await handleStage(stage: false);
        return true;
      case 'stage_all':
        await handleStageAll(stage: true);
        return true;
      case 'unstage_all':
        await handleStageAll(stage: false);
        return true;
      case 'commit':
        await openCommitBox();
        return true;
      case 'next_repo':
        await cycleRepo(1);
        return true;
      case 'prev_repo':
        await cycleRepo(-1);
        return true;
      case 'picker_confirm':
        await _repoPicker.confirm();
        return true;
      case 'picker_close':
        await _repoPicker.close();
        return true;
      case 'commit_submit':
        await _commitBox.submit();
        return true;
      case 'commit_close':
        await _commitBox.close();
        return true;
      default:
        return null;
    }
  }

  Future<Object?> _handleRpc(String method, List<Object?> params) async {
    final action = (method == 'vibrainium_action' || method == 'viff_action') &&
            params.isNotEmpty
        ? params.first.toString()
        : method;
    return handleAction(action);
  }

  Future<bool> isOpen() async {
    final win = _win;
    if (win == null) return false;
    return nvim.winIsValid(win);
  }

  Future<void> toggle() async {
    if (await isOpen()) {
      await close();
    } else {
      await open();
    }
  }

  Future<void> open() async {
    await _rememberActiveEditorWin();
    await _ensureHighlights();
    if (!await isOpen()) {
      await _createSidebarWin();
    }
    await refresh(rescanRepos: _repos.isEmpty);
  }

  Future<void> closeModals() async {
    await _repoPicker.close();
    await _commitBox.close();
  }

  Future<void> close() async {
    await closeModals();
    final win = _win;
    _win = null;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.winClose(win, force: true);
    }
  }

  Future<void> reload() async {
    final ok = await HotReloader.reload();
    if (ok) {
      await onHotReloaded();
    } else {
      await nvim.notify('[viff] Hot reload unavailable (running AOT or non-JIT)', level: 3);
    }
  }

  Future<void> onHotReloaded() async {
    _highlightsInitialized = false;
    final buf = _buf;
    if (buf != null && await nvim.bufIsValid(buf)) {
      await _bindSidebarKeys(buf);
    }
    if (await isOpen()) {
      await _ensureHighlights();
      await refresh(rescanRepos: false);
    }
    await nvim.notify('[viff] Hot reloaded');
  }

  Future<void> refresh({bool rescanRepos = false}) async {
    if (rescanRepos || _repos.isEmpty) {
      final cwd = await nvim.getCwd();
      final prevPath = activeRepo?.path;
      _repos = await discoverRepos(Directory(cwd), vcsList);
      if (prevPath != null) {
        final idx = _repos.indexWhere((r) => r.path == prevPath);
        _activeRepoIndex = idx >= 0 ? idx : 0;
      } else {
        _activeRepoIndex = 0;
      }
    }

    final repo = activeRepo;
    if (repo != null) {
      final head = await repo.vcs.headLabel(repo.path);
      _repos[_activeRepoIndex] = Repo(
        name: repo.name,
        path: repo.path,
        vcs: repo.vcs,
        head: head,
      );
      _status = await repo.vcs.status(repo.path);
      _commits = await repo.vcs.commits(repo.path);
      for (final commitId in treeState.expandedCommits.toList()) {
        treeState.commitFilesCache[commitId] =
            await repo.vcs.commitFiles(repo.path, commitId);
      }
    } else {
      _status = const RepoStatus();
      _commits = const [];
    }

    await render();
  }

  Future<void> selectRepo(int index) async {
    if (index < 0 || index >= _repos.length) return;
    _activeRepoIndex = index;
    treeState.expandedCommits.clear();
    treeState.commitFilesCache.clear();
    await refresh(rescanRepos: false);
    final win = _win;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.setCurrentWin(win);
    }
  }

  Future<void> cycleRepo(int delta) async {
    if (_repos.length <= 1) return;
    final next = (_activeRepoIndex + delta) % _repos.length;
    await selectRepo(next < 0 ? next + _repos.length : next);
  }

  Future<void> openRepoPicker() async {
    await _repoPicker.open(
      repos: _repos,
      activeIndex: _activeRepoIndex,
      onSelect: selectRepo,
    );
  }

  Future<void> openCommitBox() async {
    final repo = activeRepo;
    if (repo == null) return;
    await _commitBox.open(
      repoName: repo.name,
      onSubmit: (message) async {
        try {
          await repo.vcs.commit(repo.path, message);
          await nvim.notify('Committed changes to ${repo.name}');
          await refresh(rescanRepos: false);
        } catch (e) {
          await nvim.notify('Commit failed: $e', level: 4);
        }
      },
    );
  }

  Future<TreeNode?> _nodeUnderCursor() async {
    final win = _win;
    final rendered = _rendered;
    if (win == null || rendered == null || !await nvim.winIsValid(win)) {
      return null;
    }
    final (row1, _) = await nvim.winGetCursor(win);
    final idx = row1 - 1;
    if (idx < 0 || idx >= rendered.nodes.length) return null;
    return rendered.nodes[idx];
  }

  Future<void> handleEnter() async {
    final node = await _nodeUnderCursor();
    final repo = activeRepo;
    if (node == null) return;

    switch (node) {
      case RepoHeaderNode():
        await openRepoPicker();
      case SectionNode(:final kind):
        treeState.toggleSection(kind);
        await render();
      case DirNode(:final section, :final dirPath):
        treeState.toggleDir(section, dirPath);
        await render();
      case CommitNode(:final commit):
        final nowExpanded = treeState.toggleCommit(commit.id);
        if (nowExpanded && repo != null && !treeState.commitFilesCache.containsKey(commit.id)) {
          treeState.commitFilesCache[commit.id] =
              await repo.vcs.commitFiles(repo.path, commit.id);
        }
        await render();
      case FileNode(:final file):
        if (repo != null) {
          await _openFileInMainWindow('${repo.path}/${file.path}');
        }
      case CommitFileNode(:final file):
        if (repo != null) {
          await _openFileInMainWindow('${repo.path}/${file.path}');
        }
      case DividerNode() || EmptyHintNode():
        break;
    }
  }

  Future<void> handleStage({required bool stage}) async {
    final repo = activeRepo;
    if (repo == null) return;
    if (!repo.vcs.hasStagingArea) {
      await nvim.notify('${repo.vcs.name} does not use a staging area');
      return;
    }

    final node = await _nodeUnderCursor();
    if (node == null) return;

    List<String> paths = const [];
    if (node is FileNode) {
      paths = [node.file.path];
    } else if (node is DirNode) {
      paths = node.filePaths;
    } else if (node is SectionNode) {
      if (stage && node.kind == SectionKind.unstaged) {
        await repo.vcs.stage(repo.path, const []);
        await refresh(rescanRepos: false);
        return;
      } else if (!stage && node.kind == SectionKind.staged) {
        await repo.vcs.unstage(repo.path, const []);
        await refresh(rescanRepos: false);
        return;
      }
    }

    if (paths.isEmpty) return;
    if (stage) {
      await repo.vcs.stage(repo.path, paths);
    } else {
      await repo.vcs.unstage(repo.path, paths);
    }
    await refresh(rescanRepos: false);
  }

  Future<void> handleStageAll({required bool stage}) async {
    final repo = activeRepo;
    if (repo == null) return;
    if (!repo.vcs.hasStagingArea) {
      await nvim.notify('${repo.vcs.name} does not use a staging area');
      return;
    }
    if (stage) {
      await repo.vcs.stage(repo.path, const []);
    } else {
      await repo.vcs.unstage(repo.path, const []);
    }
    await refresh(rescanRepos: false);
  }

  Future<bool> _isEligibleEditorWin(int? w) async {
    if (w == null || w <= 0) return false;
    if (w == _win || _excludedWindows.contains(w)) return false;
    if (!await nvim.winIsValid(w)) return false;

    final config = await nvim.winGetConfig(w);
    final relative = config['relative']?.toString() ?? '';
    if (relative.isNotEmpty) return false;

    final buf = await nvim.winGetBuf(w);
    if (buf > 0) {
      final filetype =
          (await nvim.bufGetOption(buf, 'filetype'))?.toString() ?? '';
      if (_nonEditorFiletypes.contains(filetype)) return false;
      final buftype =
          (await nvim.bufGetOption(buf, 'buftype'))?.toString() ?? '';
      if (buftype.isNotEmpty) return false;
    }
    return true;
  }

  Future<void> _rememberActiveEditorWin() async {
    final current = await nvim.getCurrentWin();
    if (await _isEligibleEditorWin(current)) {
      _lastActiveEditorWin = current;
      return;
    }
    final alt = await nvim.getAlternateWin();
    if (await _isEligibleEditorWin(alt)) {
      _lastActiveEditorWin = alt;
    }
  }

  Future<void> _openFileInMainWindow(String fullPath) async {
    await _rememberActiveEditorWin();

    int? targetWin;
    final candidates = <int?>[
      await nvim.getAlternateWin(),
      _lastActiveEditorWin,
      await nvim.getCurrentWin(),
    ];
    for (final candidate in candidates) {
      if (await _isEligibleEditorWin(candidate)) {
        targetWin = candidate;
        break;
      }
    }

    if (targetWin == null) {
      final wins = await nvim.listWins();
      for (final w in wins) {
        if (await _isEligibleEditorWin(w)) {
          targetWin = w;
          break;
        }
      }
    }

    if (targetWin != null) {
      _lastActiveEditorWin = targetWin;
      await nvim.setCurrentWin(targetWin);
    } else {
      await nvim.command('botright vsplit');
      final newWin = await nvim.getCurrentWin();
      if (newWin > 0) {
        _lastActiveEditorWin = newWin;
        await nvim.winSetOption(newWin, 'winfixwidth', false);
        await nvim.winSetOption(newWin, 'winfixheight', false);
        await nvim.winSetOption(newWin, 'number', true);
        await nvim.winSetOption(newWin, 'signcolumn', 'auto');
      }
    }
    final escaped = fullPath.replaceAll(' ', r'\ ');
    await nvim.command('edit $escaped');
  }

  Future<void> render() async {
    final buf = _buf;
    final nsId = _nsId;
    if (buf == null || nsId == null || !await nvim.bufIsValid(buf)) return;

    final rendered = treeState.build(
      activeRepo: activeRepo,
      totalRepos: _repos.length,
      status: _status,
      commits: _commits,
      width: sidebarWidth,
    );
    _rendered = rendered;

    await nvim.bufSetOption(buf, 'modifiable', true);
    await nvim.bufSetLines(buf, lines: rendered.lines);
    await nvim.bufSetOption(buf, 'modifiable', false);

    await nvim.bufClearNamespace(buf, nsId);
    for (final hl in rendered.highlights) {
      await nvim.bufSetExtmark(buf, nsId, hl.line, hl.colStart, {
        'end_col': hl.colEnd,
        'hl_group': hl.group,
      });
    }
  }

  Future<void> _ensureHighlights() async {
    _nsId ??= await nvim.createNamespace('viff_sidebar');
    if (_highlightsInitialized) return;
    _highlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'ViffRepoHeader': {'bold': true, 'link': 'Title'},
      'ViffDivider': {'link': 'WinSeparator'},
      'ViffSectionHeader': {'bold': true, 'link': 'Statement'},
      'ViffDirectory': {'bold': true, 'link': 'Directory'},
      'ViffStatusModified': {'bold': true, 'link': 'Changed'},
      'ViffStatusAdded': {'bold': true, 'link': 'Added'},
      'ViffStatusDeleted': {'bold': true, 'link': 'Removed'},
      'ViffStatusRenamed': {'bold': true, 'link': 'Special'},
      'ViffStatusUntracked': {'bold': true, 'link': 'Question'},
      'ViffStatusConflicted': {'bold': true, 'link': 'ErrorMsg'},
      'ViffCommitHash': {'bold': true, 'link': 'Identifier'},
      'ViffMuted': {'link': 'Comment'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }
  }

  Future<int> ensureBuffer() async {
    await _ensureHighlights();
    var buf = _buf;
    if (buf == null || !await nvim.bufIsValid(buf)) {
      buf = await nvim.createBuf(listed: false, scratch: true);
      _buf = buf;
      await nvim.bufSetOption(buf, 'buftype', 'nofile');
      await nvim.bufSetOption(buf, 'bufhidden', 'hide');
      await nvim.bufSetOption(buf, 'swapfile', false);
      await nvim.bufSetOption(buf, 'filetype', 'viff');
      await _bindSidebarKeys(buf);
    }
    return buf;
  }

  Future<void> _createSidebarWin() async {
    final buf = await ensureBuffer();

    final win = await nvim.openWin(buf, true, {
      'split': 'left',
      'width': sidebarWidth,
      'style': 'minimal',
    });
    _win = win;

    await nvim.winSetOption(win, 'number', false);
    await nvim.winSetOption(win, 'relativenumber', false);
    await nvim.winSetOption(win, 'signcolumn', 'no');
    await nvim.winSetOption(win, 'foldcolumn', '0');
    await nvim.winSetOption(win, 'statuscolumn', '');
    await nvim.winSetOption(win, 'wrap', false);
    await nvim.winSetOption(win, 'cursorline', true);
    await nvim.winSetOption(win, 'winfixwidth', true);
  }

  Future<void> _bindSidebarKeys(int buf) async {
    final mappings = <String, String>{
      '<CR>': 'enter',
      'o': 'enter',
      '<Space>': 'stage',
      's': 'stage',
      'u': 'unstage',
      'S': 'stage_all',
      'U': 'unstage_all',
      'c': 'commit',
      'r': 'repo_picker',
      'R': 'refresh',
      'H': 'reload',
      ']': 'next_repo',
      '[': 'prev_repo',
      'q': 'close',
      ...extraKeymaps,
    };

    for (final entry in mappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }
  }
}
