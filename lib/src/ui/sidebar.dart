import 'dart:io';

import 'package:viff/viff.dart';

import '../vcs/vcs.dart';
import 'commit_box.dart';
import 'context_menu.dart';
import 'repo_picker.dart';
import 'tree.dart';

class VivcsSidebar {
  final Nvim nvim;
  final List<Vcs> vcsList;
  final int sidebarWidth;
  final Map<String, String> extraKeymaps;
  late final ViffController viff;

  final SidebarTreeState treeState = SidebarTreeState();
  late final RepoPicker _repoPicker = RepoPicker(nvim);
  late final CommitBox _commitBox = CommitBox(nvim);
  late final VcsContextMenu _contextMenu = VcsContextMenu(nvim);

  static const Set<String> _nonEditorFiletypes = {
    'viworkspace',
    'viff',
    'viff-picker',
    'viff-menu',
    'vivcs',
    'vivcs-picker',
    'vivcs-menu',
    'viproblems',
    'viproblems-detail',
    'vibrainium-tabbar',
    'vibrainium-bottom-tabbar',
    'viworkspace-prompt',
    'viworkspace-confirm',
    'viworkspace-menu',
    'visearch-padding',
    'visearch-prompt',
    'visearch-results',
    'visearch-preview',
    'visearch-dropdown',
  };

  int? _nsId;
  int? _buf;
  int? _win;
  int? _lastActiveEditorWin;
  int? _lastSeenAlternateWin;
  String? _lastActiveEditorBufPath;
  Set<int> _excludedWindows = const {};
  bool _highlightsInitialized = false;

  List<Repo> _repos = [];
  int _activeRepoIndex = 0;
  RepoStatus _status = const RepoStatus();
  List<Commit> _commits = const [];
  RenderedTree? _rendered;
  DateTime? _lastClickTime;
  int? _lastClickRow;
  DateTime? _lastDoubleClickTime;

  VivcsSidebar({
    required this.nvim,
    required this.vcsList,
    this.sidebarWidth = 38,
    this.extraKeymaps = const {},
    ViffController? viff,
    bool bindRpc = true,
  }) {
    this.viff = viff ?? ViffController(nvim: nvim);
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
      if (_lastActiveEditorWin != lastActiveEditorWin) {
        _lastSeenAlternateWin = null;
      }
      _lastActiveEditorWin = lastActiveEditorWin;
    }
    viff.updateWindowContext(
      excludedWins: {
        if (_win != null) _win!,
        ..._excludedWindows,
      },
      lastActiveEditorWin: _lastActiveEditorWin,
    );
  }

  Repo? get activeRepo =>
      (_activeRepoIndex >= 0 && _activeRepoIndex < _repos.length)
          ? _repos[_activeRepoIndex]
          : null;

  List<Repo> get repos => List.unmodifiable(_repos);

  RenderedTree? get renderedTree => _rendered;
  RepoPicker get repoPicker => _repoPicker;
  VcsContextMenu get contextMenu => _contextMenu;

  Future<Object?> handleAction(
    String rawAction, [
    List<Object?> params = const [],
  ]) async {
    final action = rawAction.startsWith('vcs.')
        ? rawAction.substring('vcs.'.length)
        : rawAction;

    if (action.startsWith('menu_select:')) {
      final idx = int.tryParse(action.substring('menu_select:'.length));
      if (idx != null) {
        await _contextMenu.selectIndex(idx);
      }
      return true;
    }

    if (rawAction.startsWith('viff.') || rawAction.startsWith('diff.')) {
      return viff.handleAction(rawAction);
    }

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
      case 'diff_inline':
        await handleOpenDiff(mode: DiffViewMode.inline);
        return true;
      case 'diff_sbs':
        await handleOpenDiff(mode: DiffViewMode.sideBySide);
        return true;
      case 'open_plain':
        await handleOpenPlainFile();
        return true;
      case 'copy_review':
        await viff.copyAllReviews();
        return true;
      case 'click':
        await handleClick(doubleClick: false);
        return true;
      case 'double_click':
        await handleClick(doubleClick: true);
        return true;
      case 'context_menu':
        await _rememberActiveEditorWin();
        final clickedPos = NvimMouseRouter.parseActionParams(params);
        await openContextMenu(mousePos: clickedPos);
        return true;
      case 'menu_click':
        await _contextMenu.handleClick();
        return true;
      case 'menu_confirm':
        await _contextMenu.confirm();
        return true;
      case 'menu_close':
        final expectedBuf =
            params.length > 1 ? int.tryParse(params[1]?.toString() ?? '') : null;
        await _contextMenu.cancel(expectedBufId: expectedBuf);
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
      case 'picker_click':
        await _repoPicker.handleClick();
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
    final action = (method == 'vibrainium_action' || method == 'vivcs_action') &&
            params.isNotEmpty
        ? params.first.toString()
        : method;
    return handleAction(action, params);
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
    await _contextMenu.close();
    await viff.closeModals();
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
      await nvim.notify(
        '[Vibrainium] Hot reload unavailable (running AOT or non-JIT)',
        level: 3,
      );
    }
  }

  Future<void> onHotReloaded() async {
    _highlightsInitialized = false;
    nvim.resetRightMouseRouterForHotReload();
    final buf = _buf;
    if (buf != null && await nvim.bufIsValid(buf)) {
      await _bindSidebarKeys(buf);
    }
    if (await isOpen()) {
      await _ensureHighlights();
      await refresh(rescanRepos: false);
    }
    await viff.onHotReloaded();
    await nvim.notify('[Vibrainium] Hot reloaded');
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
    await _rememberActiveEditorWin();
    if (_repoPicker.isOpen) {
      await _repoPicker.close();
      final win = _win;
      if (win != null && await nvim.winIsValid(win)) {
        await nvim.setCurrentWin(win);
      }
      return;
    }
    await _contextMenu.close();
    await _repoPicker.open(
      repos: _repos,
      activeIndex: _activeRepoIndex,
      onSelect: selectRepo,
    );
  }

  Future<void> openCommitBox() async {
    await _rememberActiveEditorWin();
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

  Future<(int, int)?> _syncCursorFromMouse(
    int win, {
    MousePosition? mousePos,
  }) async {
    await _rememberActiveEditorWin();
    final resolvedMouse = mousePos ?? await nvim.getMousePos();
    final maxLine = (_rendered?.nodes.length ?? 1).clamp(1, 999999);
    if (resolvedMouse != null) {
      if (resolvedMouse.winId == win &&
          (resolvedMouse.line >= 1 || resolvedMouse.winRow >= 1)) {
        final targetLine = resolvedMouse.line >= 1
            ? resolvedMouse.line.clamp(1, maxLine)
            : maxLine;
        final currentWin = await nvim.getCurrentWin();
        if (currentWin != win) {
          await nvim.setCurrentWin(win);
        }
        await nvim.winSetCursor(win, targetLine, 0);
        final winRow =
            resolvedMouse.winRow > 0 ? resolvedMouse.winRow : targetLine;
        return (targetLine, winRow);
      }
      if (resolvedMouse.winId > 0 &&
          resolvedMouse.winId != win &&
          await nvim.winIsValid(resolvedMouse.winId)) {
        return null;
      }
      if (resolvedMouse.screenRow > 0) {
        final (winTop0, _) = await nvim.winGetPosition(win);
        final topLine = await nvim.winGetTopLine(win);
        final winRow = (resolvedMouse.screenRow - winTop0).clamp(1, 999);
        final targetLine = (topLine + winRow - 1).clamp(1, maxLine);
        final currentWin = await nvim.getCurrentWin();
        if (currentWin != win) {
          await nvim.setCurrentWin(win);
        }
        await nvim.winSetCursor(win, targetLine, 0);
        return (targetLine, winRow);
      }
    }
    final (row1, _) = await nvim.winGetCursor(win);
    return (row1, row1);
  }

  Future<void> handleClick({required bool doubleClick}) async {
    await _rememberActiveEditorWin();
    await _contextMenu.close();
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) return;

    final synced = await _syncCursorFromMouse(win);
    if (synced == null) return;
    final (row1, _) = synced;
    final node = await _nodeUnderCursor();
    final now = DateTime.now();

    if (!doubleClick) {
      if (node is RepoHeaderNode) {
        _lastClickTime = null;
        _lastClickRow = null;
        await openRepoPicker();
        return;
      }

      if (_lastClickRow == row1 &&
          _lastClickTime != null &&
          now.difference(_lastClickTime!) <=
              const Duration(milliseconds: 400)) {
        _lastClickTime = null;
        _lastClickRow = null;
        _lastDoubleClickTime = now;
        await handleEnter();
        return;
      }

      _lastClickRow = row1;
      _lastClickTime = now;
      return;
    }

    _lastClickTime = null;
    _lastClickRow = null;
    if (_lastDoubleClickTime != null &&
        now.difference(_lastDoubleClickTime!) <=
            const Duration(milliseconds: 250)) {
      return;
    }
    _lastDoubleClickTime = now;
    await handleEnter();
  }

  Future<void> _focusSidebar() async {
    final win = _win;
    if (win != null && await nvim.winIsValid(win)) {
      await nvim.setCurrentWin(win);
    }
  }

  Future<void> openContextMenu({MousePosition? mousePos}) async {
    final win = _win;
    if (win == null || !await nvim.winIsValid(win)) return;
    await _contextMenu.close();
    final synced = await _syncCursorFromMouse(win, mousePos: mousePos);
    if (synced == null) return;
    final (_, winRow) = synced;
    final node = await _nodeUnderCursor();
    final repo = activeRepo;
    final hasStaging = repo?.vcs.hasStagingArea ?? false;

    final items = <VcsContextMenuItem>[
      if (node is FileNode || node is CommitFileNode) ...[
        VcsContextMenuItem(
          label: 'Open Diff',
          shortcut: '<CR>',
          onSelect: () async {
            await _focusSidebar();
            await handleEnter();
          },
        ),
        VcsContextMenuItem(
          label: 'Open Side-by-Side Diff',
          shortcut: 'D',
          onSelect: () async {
            await _focusSidebar();
            await handleOpenDiff(mode: DiffViewMode.sideBySide);
          },
        ),
        VcsContextMenuItem(
          label: 'Open File',
          shortcut: 'o',
          onSelect: () async {
            await _focusSidebar();
            await handleOpenPlainFile();
          },
        ),
      ],
      if (node is FileNode && hasStaging && node.section == SectionKind.unstaged)
        VcsContextMenuItem(
          label: 'Stage File',
          shortcut: 's',
          onSelect: () async {
            await _focusSidebar();
            await handleStage(stage: true);
          },
        ),
      if (node is FileNode && hasStaging && node.section == SectionKind.staged)
        VcsContextMenuItem(
          label: 'Unstage File',
          shortcut: 'u',
          onSelect: () async {
            await _focusSidebar();
            await handleStage(stage: false);
          },
        ),
      if (node is DirNode && hasStaging && node.section == SectionKind.unstaged)
        VcsContextMenuItem(
          label: 'Stage Directory',
          shortcut: 's',
          onSelect: () async {
            await _focusSidebar();
            await handleStage(stage: true);
          },
        ),
      if (node is DirNode && hasStaging && node.section == SectionKind.staged)
        VcsContextMenuItem(
          label: 'Unstage Directory',
          shortcut: 'u',
          onSelect: () async {
            await _focusSidebar();
            await handleStage(stage: false);
          },
        ),
      if (node is SectionNode || node is DirNode || node is CommitNode)
        VcsContextMenuItem(
          label: switch (node) {
            SectionNode(:final expanded) ||
            DirNode(:final expanded) ||
            CommitNode(:final expanded) =>
              expanded ? 'Collapse' : 'Expand',
            _ => 'Toggle',
          },
          shortcut: '<CR>',
          onSelect: () async {
            await _focusSidebar();
            await handleEnter();
          },
        ),
      if (hasStaging) ...[
        VcsContextMenuItem(
          label: 'Stage All',
          shortcut: 'S',
          onSelect: () async {
            await _focusSidebar();
            await handleStageAll(stage: true);
          },
        ),
        VcsContextMenuItem(
          label: 'Unstage All',
          shortcut: 'U',
          onSelect: () async {
            await _focusSidebar();
            await handleStageAll(stage: false);
          },
        ),
      ],
      if (repo != null)
        VcsContextMenuItem(
          label: 'Commit...',
          shortcut: 'c',
          onSelect: () async {
            await _focusSidebar();
            await openCommitBox();
          },
        ),
      if (_repos.isNotEmpty)
        VcsContextMenuItem(
          label: 'Select Repository...',
          shortcut: 'r',
          onSelect: () async {
            await _focusSidebar();
            await openRepoPicker();
          },
        ),
      VcsContextMenuItem(
        label: 'Copy Review Comments',
        shortcut: 'gY',
        onSelect: () async {
          await _focusSidebar();
          await viff.copyAllReviews();
        },
      ),
      VcsContextMenuItem(
        label: 'Refresh',
        shortcut: 'R',
        onSelect: () async {
          await _focusSidebar();
          await refresh(rescanRepos: true);
        },
      ),
    ];

    final title = switch (node) {
      FileNode(:final name) => name,
      CommitFileNode(:final file) => file.path,
      DirNode(:final name) => name,
      SectionNode(:final kind) => kind.label,
      CommitNode(:final commit) => commit.shortId,
      RepoHeaderNode(:final repo) => repo?.name ?? 'Repository',
      _ => repo?.name ?? 'VCS',
    };

    await _contextMenu.open(
      items: items,
      title: title,
      anchorWin: win,
      row: winRow,
      col: 2,
      onCancel: _focusSidebar,
    );
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
      case FileNode():
      case CommitFileNode():
        await _openDiffForNode(node);
      case DividerNode() || EmptyHintNode():
        break;
    }
  }

  Future<void> handleOpenDiff({DiffViewMode? mode}) async {
    final node = await _nodeUnderCursor();
    if (node == null) return;
    await _openDiffForNode(node, mode: mode);
  }

  Future<void> handleOpenPlainFile() async {
    final node = await _nodeUnderCursor();
    final repo = activeRepo;
    if (node == null || repo == null) return;
    switch (node) {
      case FileNode(:final file):
        await _openFileInMainWindow('${repo.path}/${file.path}');
      case CommitFileNode(:final file):
        await _openFileInMainWindow('${repo.path}/${file.path}');
      default:
        break;
    }
  }

  Future<void> _openDiffForNode(
    TreeNode node, {
    DiffViewMode? mode,
  }) async {
    final repo = activeRepo;
    if (repo == null) return;
    await _rememberActiveEditorWin();
    viff.updateWindowContext(
      excludedWins: {
        if (_win != null) _win!,
        ..._excludedWindows,
      },
      lastActiveEditorWin: _lastActiveEditorWin,
    );

    if (node is FileNode) {
      final file = node.file;
      if (node.section == SectionKind.staged) {
        final target = VcsStagedDiffTarget(
          repoName: repo.name,
          repoPath: repo.path,
          vcsName: repo.vcs.name,
          headLabel: repo.head,
          filePath: file.path,
          oldPath: file.oldPath,
          onUnstageHunk: (hunk) async {
            if (file.status == FileStatus.added ||
                file.status == FileStatus.deleted) {
              await repo.vcs.unstage(repo.path, [file.path]);
              return;
            }
            try {
              final patch = hunk.toUnifiedPatch(
                oldPath: file.oldPath ?? file.path,
                newPath: file.path,
              );
              await repo.vcs.applyHunkPatch(
                repo.path,
                patch,
                cached: true,
                reverse: true,
              );
            } catch (_) {
              await repo.vcs.unstage(repo.path, [file.path]);
            }
          },
          onRefreshVcs: () => refresh(rescanRepos: false),
        );

        await viff.openDiff(
          target: target,
          mode: mode,
          loadOldLines: () async {
            if (file.status == FileStatus.added) return const [];
            final raw = await repo.vcs.fileContentAt(
              repo.path,
              file.oldPath ?? file.path,
              revision: 'HEAD',
            );
            return DiffEngine.splitLines(raw);
          },
          loadNewLines: () async {
            if (file.status == FileStatus.deleted) return const [];
            final raw = await repo.vcs.fileContentAt(
              repo.path,
              file.path,
              revision: ':0',
            );
            return DiffEngine.splitLines(raw);
          },
        );
      } else {
        final target = VcsUnstagedDiffTarget(
          repoName: repo.name,
          repoPath: repo.path,
          vcsName: repo.vcs.name,
          headLabel: repo.head,
          filePath: file.path,
          oldPath: file.oldPath,
          hasStagingArea: repo.vcs.hasStagingArea,
          onStageHunk: (hunk) async {
            if (file.status == FileStatus.untracked ||
                file.status == FileStatus.added ||
                file.status == FileStatus.deleted) {
              await repo.vcs.stage(repo.path, [file.path]);
              return;
            }
            try {
              final patch = hunk.toUnifiedPatch(
                oldPath: file.oldPath ?? file.path,
                newPath: file.path,
              );
              await repo.vcs.applyHunkPatch(
                repo.path,
                patch,
                cached: true,
              );
            } catch (_) {
              await repo.vcs.stage(repo.path, [file.path]);
            }
          },
          onRefreshVcs: () => refresh(rescanRepos: false),
        );

        await viff.openDiff(
          target: target,
          mode: mode,
          loadOldLines: () async {
            if (file.status == FileStatus.untracked ||
                file.status == FileStatus.added) {
              return const [];
            }
            final raw = await repo.vcs.fileContentAt(
              repo.path,
              file.oldPath ?? file.path,
            );
            return DiffEngine.splitLines(raw);
          },
          loadNewLines: () async {
            if (file.status == FileStatus.deleted) return const [];
            final diskFile = File('${repo.path}/${file.path}');
            if (await diskFile.exists()) {
              return DiffEngine.splitLines(await diskFile.readAsString());
            }
            return const [];
          },
        );
      }
      if (viff.rightWindowId != null) {
        _lastActiveEditorWin = viff.rightWindowId;
      }
    } else if (node is CommitFileNode) {
      final file = node.file;
      final commit = node.commit;

      final target = VcsCommitDiffTarget(
        repoName: repo.name,
        repoPath: repo.path,
        vcsName: repo.vcs.name,
        commitId: commit.id,
        commitShortId: commit.shortId,
        commitAuthor: commit.author,
        commitDate: commit.date,
        commitMessage: commit.message,
        parentRevision: '${commit.shortId}~1',
        filePath: file.path,
        oldPath: file.oldPath,
      );

      await viff.openDiff(
        target: target,
        mode: mode,
        loadOldLines: () async {
          if (file.status == FileStatus.added) return const [];
          final raw = await repo.vcs.fileContentAt(
            repo.path,
            file.oldPath ?? file.path,
            revision: '${commit.id}~1',
          );
          return DiffEngine.splitLines(raw);
        },
        loadNewLines: () async {
          if (file.status == FileStatus.deleted) return const [];
          final raw = await repo.vcs.fileContentAt(
            repo.path,
            file.path,
            revision: commit.id,
          );
          return DiffEngine.splitLines(raw);
        },
      );
      if (viff.rightWindowId != null) {
        _lastActiveEditorWin = viff.rightWindowId;
      }
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

  Future<bool> _isReplaceableMainWin(int? w) async {
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
      if (buftype == 'terminal' ||
          buftype == 'quickfix' ||
          buftype == 'prompt') {
        return false;
      }
    }
    return true;
  }

  Future<void> _rememberActiveEditorWin() async {
    final current = await nvim.getCurrentWin();
    final alt = await nvim.getAlternateWin();
    if (await _isEligibleEditorWin(current)) {
      _lastActiveEditorWin = current;
      _lastSeenAlternateWin = alt;
    } else if (await _isEligibleEditorWin(alt)) {
      if (_lastActiveEditorWin == null ||
          !await _isEligibleEditorWin(_lastActiveEditorWin) ||
          (_lastSeenAlternateWin != null && alt != _lastSeenAlternateWin)) {
        _lastActiveEditorWin = alt;
      }
      _lastSeenAlternateWin = alt;
    }

    final editorWin = _lastActiveEditorWin;
    if (editorWin != null && await nvim.winIsValid(editorWin)) {
      final buf = await nvim.winGetBuf(editorWin);
      if (buf > 0 && await nvim.bufIsValid(buf)) {
        final name = (await nvim.bufGetName(buf)).trim();
        if (name.isNotEmpty) {
          _lastActiveEditorBufPath = name;
        }
      }
    }
  }

  Future<void> _openFileInMainWindow(String fullPath) async {
    await _rememberActiveEditorWin();

    int? targetWin;
    final candidates = <int?>[
      _lastActiveEditorWin,
      await nvim.getAlternateWin(),
      await nvim.getCurrentWin(),
    ];
    for (final candidate in candidates) {
      if (await _isEligibleEditorWin(candidate)) {
        targetWin = candidate;
        break;
      }
    }

    List<int>? allWins;
    if (targetWin == null) {
      allWins = await nvim.listWins();
      final activePath = _lastActiveEditorBufPath;
      if (activePath != null && activePath.isNotEmpty) {
        for (final w in allWins) {
          if (await _isEligibleEditorWin(w)) {
            final b = await nvim.winGetBuf(w);
            if (b > 0) {
              final name = (await nvim.bufGetName(b)).trim();
              if (name.isNotEmpty && name == activePath) {
                targetWin = w;
                break;
              }
            }
          }
        }
      }
      if (targetWin == null) {
        for (final w in allWins) {
          if (await _isEligibleEditorWin(w)) {
            targetWin = w;
            break;
          }
        }
      }
    }

    if (targetWin == null) {
      for (final candidate in candidates) {
        if (await _isReplaceableMainWin(candidate)) {
          targetWin = candidate;
          break;
        }
      }
    }

    if (targetWin == null) {
      allWins ??= await nvim.listWins();
      for (final w in allWins) {
        if (await _isReplaceableMainWin(w)) {
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
    _nsId ??= await nvim.createNamespace('vivcs_sidebar');
    if (_highlightsInitialized) return;
    _highlightsInitialized = true;

    const groups = <String, Map<String, Object?>>{
      'VivcsRepoHeader': {'bold': true, 'link': 'Title'},
      'VivcsDivider': {'link': 'WinSeparator'},
      'VivcsSectionHeader': {'bold': true, 'link': 'Title'},
      'VivcsDirectory': {'bold': true, 'link': 'Directory'},
      'VivcsStatusModified': {'bold': true, 'link': 'Changed'},
      'VivcsStatusAdded': {'bold': true, 'link': 'Added'},
      'VivcsStatusDeleted': {'bold': true, 'link': 'Removed'},
      'VivcsStatusRenamed': {'bold': true, 'link': 'Special'},
      'VivcsStatusUntracked': {'bold': true, 'link': 'Question'},
      'VivcsStatusConflicted': {'bold': true, 'link': 'ErrorMsg'},
      'VivcsCommitHash': {'bold': true, 'link': 'Identifier'},
      'VivcsMuted': {'link': 'Comment'},
    };

    for (final entry in groups.entries) {
      await nvim.setHl(0, entry.key, entry.value);
    }

    try {
      await nvim.execLua(r'''
local function set_bold_from(group, target)
  local ok, base = pcall(vim.api.nvim_get_hl, 0, { name = target, link = false })
  local spec = { bold = true, cterm = { bold = true } }
  if ok and type(base) == 'table' then
    spec.fg = base.fg
    spec.bg = base.bg
    spec.sp = base.sp
    spec.ctermfg = base.ctermfg
    spec.ctermbg = base.ctermbg
  end
  pcall(vim.api.nvim_set_hl, 0, group, spec)
end
set_bold_from('VivcsRepoHeader', 'Title')
set_bold_from('VivcsSectionHeader', 'Title')
''');
    } catch (_) {}
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
      await nvim.bufSetOption(buf, 'filetype', 'vivcs');
      await _bindSidebarKeys(buf);
    }
    return buf;
  }

  Future<void> _createSidebarWin() async {
    final buf = await ensureBuffer();

    final win = await nvim.openWin(buf, true, {
      'win': -1,
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
      'o': 'open_plain',
      'd': 'diff_inline',
      'D': 'diff_sbs',
      'gY': 'copy_review',
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

    const mouseMappings = <String, String>{
      '<LeftMouse>': 'vcs.click',
      '<2-LeftMouse>': 'vcs.double_click',
    };

    for (final entry in mouseMappings.entries) {
      await nvim.bufSetKeymap(
        buf,
        'n',
        entry.key,
        "<LeftMouse><Cmd>lua require('vibrainium').action('${entry.value}')<CR>",
      );
    }

    await nvim.registerRightClickBuffer(buf, 'vcs.context_menu');
  }
}
