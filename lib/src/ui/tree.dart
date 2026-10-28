import 'dart:convert';

import '../vcs/vcs.dart';

enum SectionKind {
  unstaged('Unstaged'),
  staged('Staged'),
  commits('Commits');

  final String label;
  const SectionKind(this.label);
}

sealed class TreeNode {
  const TreeNode();
}

class RepoHeaderNode extends TreeNode {
  final Repo? repo;
  final int repoCount;
  const RepoHeaderNode({required this.repo, required this.repoCount});
}

class DividerNode extends TreeNode {
  const DividerNode();
}

class SectionNode extends TreeNode {
  final SectionKind kind;
  final int count;
  final bool expanded;
  const SectionNode({
    required this.kind,
    required this.count,
    required this.expanded,
  });
}

class DirNode extends TreeNode {
  final SectionKind section;
  final String dirPath;
  final String name;
  final int depth;
  final bool expanded;
  final List<String> filePaths;

  const DirNode({
    required this.section,
    required this.dirPath,
    required this.name,
    required this.depth,
    required this.expanded,
    required this.filePaths,
  });
}

class FileNode extends TreeNode {
  final SectionKind section;
  final ChangedFile file;
  final String name;
  final int depth;

  const FileNode({
    required this.section,
    required this.file,
    required this.name,
    required this.depth,
  });
}

class CommitNode extends TreeNode {
  final Commit commit;
  final bool expanded;

  const CommitNode({
    required this.commit,
    required this.expanded,
  });
}

class CommitFileNode extends TreeNode {
  final Commit commit;
  final ChangedFile file;

  const CommitFileNode({
    required this.commit,
    required this.file,
  });
}

class EmptyHintNode extends TreeNode {
  final String text;
  const EmptyHintNode(this.text);
}

class HighlightSpan {
  final int line;
  final int colStart;
  final int colEnd;
  final String group;

  const HighlightSpan({
    required this.line,
    required this.colStart,
    required this.colEnd,
    required this.group,
  });
}

class RenderedTree {
  final List<String> lines;
  final List<TreeNode> nodes;
  final List<HighlightSpan> highlights;

  const RenderedTree({
    required this.lines,
    required this.nodes,
    required this.highlights,
  });
}

class SidebarTreeState {
  final Set<SectionKind> collapsedSections = {};
  final Set<String> collapsedDirs = {};
  final Set<String> expandedCommits = {};
  final Map<String, List<ChangedFile>> commitFilesCache = {};

  bool isSectionExpanded(SectionKind kind) => !collapsedSections.contains(kind);

  void toggleSection(SectionKind kind) {
    if (!collapsedSections.remove(kind)) {
      collapsedSections.add(kind);
    }
  }

  String _dirKey(SectionKind section, String dirPath) => '${section.name}:$dirPath';

  bool isDirExpanded(SectionKind section, String dirPath) =>
      !collapsedDirs.contains(_dirKey(section, dirPath));

  void toggleDir(SectionKind section, String dirPath) {
    final key = _dirKey(section, dirPath);
    if (!collapsedDirs.remove(key)) {
      collapsedDirs.add(key);
    }
  }

  bool isCommitExpanded(String commitId) => expandedCommits.contains(commitId);

  bool toggleCommit(String commitId) {
    if (expandedCommits.contains(commitId)) {
      expandedCommits.remove(commitId);
      return false;
    } else {
      expandedCommits.add(commitId);
      return true;
    }
  }

  RenderedTree build({
    required Repo? activeRepo,
    required int totalRepos,
    required RepoStatus status,
    required List<Commit> commits,
    int width = 36,
  }) {
    final lines = <String>[];
    final nodes = <TreeNode>[];
    final highlights = <HighlightSpan>[];

    void addLine(
      String text,
      TreeNode node, [
      List<(int, int, String)> lineHighlights = const [],
    ]) {
      final lineIdx = lines.length;
      lines.add(text);
      nodes.add(node);
      for (final (start, end, group) in lineHighlights) {
        highlights.add(HighlightSpan(
          line: lineIdx,
          colStart: start,
          colEnd: end,
          group: group,
        ));
      }
    }

    // 1. Top Repository Dropdown Header
    if (activeRepo == null) {
      final header = ' Repo: [No repository found ▾]';
      addLine(
        header,
        RepoHeaderNode(repo: null, repoCount: totalRepos),
        [(0, _byteLen(header), 'ViffRepoHeader')],
      );
    } else {
      final label =
          ' Repo: [${activeRepo.name} (${activeRepo.vcs.name} • ${activeRepo.head}) ▾]';
      addLine(
        label,
        RepoHeaderNode(repo: activeRepo, repoCount: totalRepos),
        [(0, _byteLen(label), 'ViffRepoHeader')],
      );
    }

    final divider = '─' * (width > 8 ? width : 32);
    addLine(
      divider,
      const DividerNode(),
      [(0, _byteLen(divider), 'ViffDivider')],
    );

    if (activeRepo == null) {
      const hint = '  Press R to rescan workspace';
      addLine(hint, const EmptyHintNode(hint), [(0, _byteLen(hint), 'ViffMuted')]);
      return RenderedTree(lines: lines, nodes: nodes, highlights: highlights);
    }

    // 2. Unstaged Section
    _buildFileSection(
      kind: SectionKind.unstaged,
      files: status.unstaged,
      addLine: addLine,
    );

    // 3. Staged Section (ONLY if activeRepo.vcs.hasStagingArea is true)
    if (activeRepo.vcs.hasStagingArea) {
      _buildFileSection(
        kind: SectionKind.staged,
        files: status.staged,
        addLine: addLine,
      );
    }

    // 4. Commits Section
    final commitsExpanded = isSectionExpanded(SectionKind.commits);
    final commitsChevron = commitsExpanded ? '▾' : '▸';
    final commitsHeader = '$commitsChevron ${SectionKind.commits.label} (${commits.length})';
    addLine(
      commitsHeader,
      SectionNode(
        kind: SectionKind.commits,
        count: commits.length,
        expanded: commitsExpanded,
      ),
      [(0, _byteLen(commitsHeader), 'ViffSectionHeader')],
    );

    if (commitsExpanded) {
      if (commits.isEmpty) {
        const emptyText = '  (no commits)';
        addLine(
          emptyText,
          const EmptyHintNode(emptyText),
          [(0, _byteLen(emptyText), 'ViffMuted')],
        );
      } else {
        for (final commit in commits) {
          final isExp = isCommitExpanded(commit.id);
          final chevron = isExp ? '▾' : '▸';
          final prefix = '  $chevron ';
          final shortId = commit.shortId;
          final subject = ' ${commit.message}';
          final meta = ' (${commit.author}, ${commit.date})';
          final lineText = '$prefix$shortId$subject$meta';

          final pBytes = _byteLen(prefix);
          final idBytes = _byteLen(shortId);
          final subjBytes = _byteLen(subject);
          final metaBytes = _byteLen(meta);

          addLine(
            lineText,
            CommitNode(commit: commit, expanded: isExp),
            [
              (pBytes, pBytes + idBytes, 'ViffCommitHash'),
              (pBytes + idBytes + subjBytes, pBytes + idBytes + subjBytes + metaBytes, 'ViffMuted'),
            ],
          );

          if (isExp) {
            final changedFiles = commitFilesCache[commit.id] ?? const [];
            if (changedFiles.isEmpty) {
              const noFiles = '      (no files)';
              addLine(
                noFiles,
                const EmptyHintNode(noFiles),
                [(0, _byteLen(noFiles), 'ViffMuted')],
              );
            } else {
              for (final f in changedFiles) {
                final indent = '      ';
                final code = f.status.code;
                final pathPart = ' ${f.path}';
                final full = '$indent$code$pathPart';
                final iBytes = _byteLen(indent);
                final cBytes = _byteLen(code);
                addLine(
                  full,
                  CommitFileNode(commit: commit, file: f),
                  [
                    (iBytes, iBytes + cBytes, statusHighlightGroup(f.status)),
                  ],
                );
              }
            }
          }
        }
      }
    }

    return RenderedTree(lines: lines, nodes: nodes, highlights: highlights);
  }

  void _buildFileSection({
    required SectionKind kind,
    required List<ChangedFile> files,
    required void Function(String, TreeNode, [List<(int, int, String)>]) addLine,
  }) {
    final expanded = isSectionExpanded(kind);
    final chevron = expanded ? '▾' : '▸';
    final header = '$chevron ${kind.label} (${files.length})';
    addLine(
      header,
      SectionNode(kind: kind, count: files.length, expanded: expanded),
      [(0, _byteLen(header), 'ViffSectionHeader')],
    );

    if (!expanded) return;

    if (files.isEmpty) {
      const emptyText = '  (clean)';
      addLine(
        emptyText,
        const EmptyHintNode(emptyText),
        [(0, _byteLen(emptyText), 'ViffMuted')],
      );
      return;
    }

    final root = _DirTrieNode(name: '', path: '');
    final sorted = List<ChangedFile>.from(files)
      ..sort((a, b) => a.path.compareTo(b.path));

    for (final file in sorted) {
      final parts = file.path.split('/').where((p) => p.isNotEmpty).toList();
      if (parts.isEmpty) continue;
      var current = root;
      current.allFilePaths.add(file.path);
      for (var i = 0; i < parts.length - 1; i++) {
        final seg = parts[i];
        final nextPath = current.path.isEmpty ? seg : '${current.path}/$seg';
        current = current.dirs.putIfAbsent(
          seg,
          () => _DirTrieNode(name: seg, path: nextPath),
        );
        current.allFilePaths.add(file.path);
      }
      current.files.add((parts.last, file));
    }

    void renderTrie(_DirTrieNode dirNode, int depth) {
      final dirEntries = dirNode.dirs.values.toList()
        ..sort((a, b) => a.name.compareTo(b.name));

      for (final subDir in dirEntries) {
        final isExp = isDirExpanded(kind, subDir.path);
        final indent = '  ' * depth;
        final dirChevron = isExp ? '▾' : '▸';
        final lineText = '$indent$dirChevron ${subDir.name}/';
        addLine(
          lineText,
          DirNode(
            section: kind,
            dirPath: subDir.path,
            name: subDir.name,
            depth: depth,
            expanded: isExp,
            filePaths: subDir.allFilePaths,
          ),
          [(0, _byteLen(lineText), 'ViffDirectory')],
        );
        if (isExp) {
          renderTrie(subDir, depth + 1);
        }
      }

      for (final (fileName, file) in dirNode.files) {
        final indent = '  ' * depth;
        final badge = file.status.code;
        final renameSuffix =
            file.oldPath != null ? ' ← ${file.oldPath}' : '';
        final lineText = '$indent  $badge $fileName$renameSuffix';
        final badgeStart = _byteLen('$indent  ');
        final badgeEnd = badgeStart + _byteLen(badge);
        addLine(
          lineText,
          FileNode(
            section: kind,
            file: file,
            name: fileName,
            depth: depth,
          ),
          [
            (badgeStart, badgeEnd, statusHighlightGroup(file.status)),
          ],
        );
      }
    }

    renderTrie(root, 1);
  }

  static String statusHighlightGroup(FileStatus status) {
    return switch (status) {
      FileStatus.modified => 'ViffStatusModified',
      FileStatus.added => 'ViffStatusAdded',
      FileStatus.deleted => 'ViffStatusDeleted',
      FileStatus.renamed => 'ViffStatusRenamed',
      FileStatus.untracked => 'ViffStatusUntracked',
      FileStatus.conflicted => 'ViffStatusConflicted',
    };
  }

  static int _byteLen(String s) => utf8.encode(s).length;
}

class _DirTrieNode {
  final String name;
  final String path;
  final Map<String, _DirTrieNode> dirs = {};
  final List<(String, ChangedFile)> files = [];
  final List<String> allFilePaths = [];

  _DirTrieNode({required this.name, required this.path});
}
