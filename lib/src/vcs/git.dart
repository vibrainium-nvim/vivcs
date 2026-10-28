import 'dart:io';

import 'vcs.dart';

class Git implements Vcs {
  final CommandRunner _run;

  const Git({CommandRunner run = defaultCommandRunner}) : _run = run;

  @override
  String get name => 'git';

  @override
  bool get hasStagingArea => true;

  @override
  Future<bool> isRepo(Directory dir) async {
    final dotGitPath = '${dir.path}${Platform.pathSeparator}.git';
    final type = await FileSystemEntity.type(dotGitPath, followLinks: false);
    return type != FileSystemEntityType.notFound;
  }

  @override
  Future<String> headLabel(String repoPath) async {
    final sym = await _run(
      'git',
      ['symbolic-ref', '--short', 'HEAD'],
      workingDirectory: repoPath,
    );
    if (sym.exitCode == 0 && sym.stdout.trim().isNotEmpty) {
      return sym.stdout.trim();
    }
    final rev = await _run(
      'git',
      ['rev-parse', '--short', 'HEAD'],
      workingDirectory: repoPath,
    );
    if (rev.exitCode == 0 && rev.stdout.trim().isNotEmpty) {
      return rev.stdout.trim();
    }
    return 'HEAD';
  }

  @override
  Future<RepoStatus> status(String repoPath) async {
    final res = await _run(
      'git',
      ['status', '--porcelain=v1', '-z', '-uall'],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      return const RepoStatus();
    }
    return parsePorcelainStatus(res.stdout);
  }

  static RepoStatus parsePorcelainStatus(String output) {
    if (output.isEmpty) return const RepoStatus();
    final tokens = output.split('\x00');
    final unstaged = <ChangedFile>[];
    final staged = <ChangedFile>[];

    var i = 0;
    while (i < tokens.length) {
      final entry = tokens[i++];
      if (entry.length < 4) continue;

      final x = entry[0];
      final y = entry[1];
      final path = entry.substring(3);
      String? oldPath;
      if ((x == 'R' || x == 'C' || y == 'R' || y == 'C') && i < tokens.length) {
        oldPath = tokens[i++];
      }

      if (x == '?' && y == '?') {
        unstaged.add(ChangedFile(path: path, status: FileStatus.untracked));
        continue;
      }

      if (x == '!' && y == '!') {
        continue;
      }

      if (x == 'U' || y == 'U' || (x == 'A' && y == 'A') || (x == 'D' && y == 'D')) {
        unstaged.add(ChangedFile(path: path, status: FileStatus.conflicted));
        continue;
      }

      if (x != ' ' && x != '?') {
        staged.add(ChangedFile(
          path: path,
          status: _mapCode(x),
          oldPath: oldPath,
        ));
      }

      if (y != ' ' && y != '?') {
        unstaged.add(ChangedFile(
          path: path,
          status: _mapCode(y),
          oldPath: oldPath,
        ));
      }
    }

    return RepoStatus(unstaged: unstaged, staged: staged);
  }

  static FileStatus _mapCode(String code) {
    switch (code) {
      case 'M':
        return FileStatus.modified;
      case 'A':
        return FileStatus.added;
      case 'D':
        return FileStatus.deleted;
      case 'R':
      case 'C':
        return FileStatus.renamed;
      case 'U':
        return FileStatus.conflicted;
      default:
        return FileStatus.modified;
    }
  }

  @override
  Future<List<Commit>> commits(String repoPath, {int limit = 50}) async {
    final res = await _run(
      'git',
      [
        'log',
        '-n',
        '$limit',
        '--pretty=format:%H%x00%h%x00%an%x00%ar%x00%s%x1e',
      ],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0 || res.stdout.trim().isEmpty) {
      return const [];
    }
    return parseGitLog(res.stdout);
  }

  static List<Commit> parseGitLog(String output) {
    final records = output.split('\x1e');
    final list = <Commit>[];
    for (final raw in records) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty) continue;
      final fields = trimmed.split('\x00');
      if (fields.length < 5) continue;
      list.add(Commit(
        id: fields[0],
        shortId: fields[1],
        author: fields[2],
        date: fields[3],
        message: fields[4],
      ));
    }
    return list;
  }

  @override
  Future<List<ChangedFile>> commitFiles(String repoPath, String commitId) async {
    final res = await _run(
      'git',
      [
        'diff-tree',
        '--root',
        '--no-commit-id',
        '--name-status',
        '-r',
        '-z',
        commitId,
      ],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0 || res.stdout.isEmpty) {
      return const [];
    }
    return parseDiffTree(res.stdout);
  }

  static List<ChangedFile> parseDiffTree(String output) {
    final tokens = output.split('\x00');
    final files = <ChangedFile>[];
    var i = 0;
    while (i < tokens.length) {
      final statusToken = tokens[i++];
      if (statusToken.isEmpty || i >= tokens.length) break;
      final code = statusToken[0];
      if (code == 'R' || code == 'C') {
        final oldPath = tokens[i++];
        if (i >= tokens.length) break;
        final newPath = tokens[i++];
        files.add(ChangedFile(
          path: newPath,
          status: FileStatus.renamed,
          oldPath: oldPath,
        ));
      } else {
        final path = tokens[i++];
        files.add(ChangedFile(
          path: path,
          status: _mapCode(code),
        ));
      }
    }
    return files;
  }

  @override
  Future<void> stage(String repoPath, List<String> paths) async {
    if (paths.isEmpty) {
      await _run('git', ['add', '-A'], workingDirectory: repoPath);
    } else {
      await _run('git', ['add', '--', ...paths], workingDirectory: repoPath);
    }
  }

  @override
  Future<void> unstage(String repoPath, List<String> paths) async {
    if (paths.isEmpty) {
      await _run('git', ['reset', 'HEAD'], workingDirectory: repoPath);
    } else {
      await _run('git', ['reset', 'HEAD', '--', ...paths], workingDirectory: repoPath);
    }
  }

  @override
  Future<void> commit(String repoPath, String message) async {
    final res = await _run(
      'git',
      ['commit', '-m', message],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      throw StateError(res.stderr.trim().isNotEmpty ? res.stderr.trim() : res.stdout.trim());
    }
  }
}
