import 'dart:io';

import 'vcs.dart';

class Svn implements Vcs {
  final CommandRunner _run;

  const Svn({CommandRunner run = defaultCommandRunner}) : _run = run;

  @override
  String get name => 'svn';

  @override
  bool get hasStagingArea => false;

  @override
  Future<bool> isRepo(Directory dir) async {
    final dotSvnPath = '${dir.path}${Platform.pathSeparator}.svn';
    final type = await FileSystemEntity.type(dotSvnPath, followLinks: false);
    return type == FileSystemEntityType.directory;
  }

  @override
  Future<String> headLabel(String repoPath) async {
    final res = await _run(
      'svn',
      ['info', '--xml'],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) return 'Working Copy';
    final match = RegExp(r'<entry[^>]*\srevision="(\d+)"').firstMatch(res.stdout);
    if (match != null) {
      return 'r${match.group(1)}';
    }
    return 'Working Copy';
  }

  @override
  Future<RepoStatus> status(String repoPath) async {
    final res = await _run(
      'svn',
      ['status', '--xml'],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      return const RepoStatus();
    }
    return parseSvnStatusXml(res.stdout);
  }

  static RepoStatus parseSvnStatusXml(String xml) {
    final entryRegex = RegExp(
      r'<entry\s+path="([^"]+)"[^>]*>([\s\S]*?)<\/entry>',
    );
    final wcStatusRegex = RegExp(r'<wc-status[^>]*\sitem="([^"]+)"');
    final unstaged = <ChangedFile>[];

    for (final match in entryRegex.allMatches(xml)) {
      final rawPath = _unescapeXml(match.group(1)!);
      final body = match.group(2)!;
      final statusMatch = wcStatusRegex.firstMatch(body);
      if (statusMatch == null) continue;

      final item = statusMatch.group(1)!;
      final status = _mapSvnItem(item);
      if (status != null) {
        unstaged.add(ChangedFile(path: rawPath, status: status));
      }
    }

    return RepoStatus(unstaged: unstaged);
  }

  static FileStatus? _mapSvnItem(String item) {
    switch (item) {
      case 'modified':
      case 'replaced':
        return FileStatus.modified;
      case 'added':
        return FileStatus.added;
      case 'deleted':
      case 'missing':
        return FileStatus.deleted;
      case 'unversioned':
        return FileStatus.untracked;
      case 'conflicted':
        return FileStatus.conflicted;
      default:
        return null;
    }
  }

  @override
  Future<List<Commit>> commits(String repoPath, {int limit = 50}) async {
    final res = await _run(
      'svn',
      ['log', '-l', '$limit', '--xml'],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      return const [];
    }
    return parseSvnLogXml(res.stdout);
  }

  static List<Commit> parseSvnLogXml(String xml) {
    final logEntryRegex = RegExp(
      r'<logentry\s+revision="([^"]+)"[^>]*>([\s\S]*?)<\/logentry>',
    );
    final authorRegex = RegExp(r'<author>([\s\S]*?)<\/author>');
    final dateRegex = RegExp(r'<date>([\s\S]*?)<\/date>');
    final msgRegex = RegExp(r'<msg>([\s\S]*?)<\/msg>');

    final list = <Commit>[];
    for (final match in logEntryRegex.allMatches(xml)) {
      final rev = match.group(1)!;
      final body = match.group(2)!;
      final author = _unescapeXml(authorRegex.firstMatch(body)?.group(1)?.trim() ?? 'unknown');
      final rawDate = _unescapeXml(dateRegex.firstMatch(body)?.group(1)?.trim() ?? '');
      final date = rawDate.length >= 10 ? rawDate.substring(0, 10) : rawDate;
      final fullMsg = _unescapeXml(msgRegex.firstMatch(body)?.group(1)?.trim() ?? '');
      final firstLine = fullMsg.split('\n').first.trim();

      list.add(Commit(
        id: rev,
        shortId: 'r$rev',
        author: author,
        date: date,
        message: firstLine.isEmpty ? '(no message)' : firstLine,
      ));
    }
    return list;
  }

  @override
  Future<List<ChangedFile>> commitFiles(String repoPath, String commitId) async {
    final cleanRev = commitId.startsWith('r') ? commitId.substring(1) : commitId;
    final res = await _run(
      'svn',
      ['log', '-r', cleanRev, '-v', '--xml'],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      return const [];
    }
    return parseSvnCommitFilesXml(res.stdout);
  }

  static List<ChangedFile> parseSvnCommitFilesXml(String xml) {
    final pathRegex = RegExp(
      r'<path[^>]*\saction="([MADR])"[^>]*>([\s\S]*?)<\/path>',
    );
    final files = <ChangedFile>[];
    for (final match in pathRegex.allMatches(xml)) {
      final action = match.group(1)!;
      var path = _unescapeXml(match.group(2)!.trim());
      if (path.startsWith('/')) {
        path = path.substring(1);
      }
      final status = switch (action) {
        'A' => FileStatus.added,
        'D' => FileStatus.deleted,
        'R' => FileStatus.renamed,
        _ => FileStatus.modified,
      };
      files.add(ChangedFile(path: path, status: status));
    }
    return files;
  }

  @override
  Future<void> stage(String repoPath, List<String> paths) async {
    throw UnsupportedError('SVN does not have a staging area');
  }

  @override
  Future<void> unstage(String repoPath, List<String> paths) async {
    throw UnsupportedError('SVN does not have a staging area');
  }

  @override
  Future<void> commit(String repoPath, String message) async {
    final res = await _run(
      'svn',
      ['commit', '-m', message],
      workingDirectory: repoPath,
    );
    if (res.exitCode != 0) {
      throw StateError(res.stderr.trim().isNotEmpty ? res.stderr.trim() : res.stdout.trim());
    }
  }

  static String _unescapeXml(String input) {
    return input
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&amp;', '&');
  }
}
