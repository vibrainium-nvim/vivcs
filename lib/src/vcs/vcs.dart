import 'dart:io';

enum FileStatus {
  modified('M'),
  added('A'),
  deleted('D'),
  renamed('R'),
  untracked('?'),
  conflicted('U');

  final String code;
  const FileStatus(this.code);
}

class ChangedFile {
  final String path;
  final FileStatus status;
  final String? oldPath;

  const ChangedFile({
    required this.path,
    required this.status,
    this.oldPath,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChangedFile &&
          other.path == path &&
          other.status == status &&
          other.oldPath == oldPath;

  @override
  int get hashCode => Object.hash(path, status, oldPath);

  @override
  String toString() => '${status.code} $path';
}

class RepoStatus {
  final List<ChangedFile> unstaged;
  final List<ChangedFile> staged;

  const RepoStatus({
    this.unstaged = const [],
    this.staged = const [],
  });
}

class Commit {
  final String id;
  final String shortId;
  final String author;
  final String date;
  final String message;

  const Commit({
    required this.id,
    required this.shortId,
    required this.author,
    required this.date,
    required this.message,
  });
}

class Repo {
  final String name;
  final String path;
  final Vcs vcs;
  final String head;

  const Repo({
    required this.name,
    required this.path,
    required this.vcs,
    required this.head,
  });
}

class CommandResult {
  final int exitCode;
  final String stdout;
  final String stderr;

  const CommandResult({
    required this.exitCode,
    required this.stdout,
    required this.stderr,
  });
}

typedef CommandRunner = Future<CommandResult> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
});

Future<CommandResult> defaultCommandRunner(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
}) async {
  final result = await Process.run(
    executable,
    arguments,
    workingDirectory: workingDirectory,
  );
  return CommandResult(
    exitCode: result.exitCode,
    stdout: result.stdout.toString(),
    stderr: result.stderr.toString(),
  );
}

/// Modular Version Control System interface.
abstract interface class Vcs {
  String get name;
  bool get hasStagingArea;

  Future<bool> isRepo(Directory dir);
  Future<String> headLabel(String repoPath);
  Future<RepoStatus> status(String repoPath);
  Future<List<Commit>> commits(String repoPath, {int limit = 50});
  Future<List<ChangedFile>> commitFiles(String repoPath, String commitId);
  Future<void> stage(String repoPath, List<String> paths);
  Future<void> unstage(String repoPath, List<String> paths);
  Future<void> commit(String repoPath, String message);
}

const Set<String> _ignoredDirNames = {
  '.git',
  '.svn',
  '.dart_tool',
  'node_modules',
  'build',
  '.idea',
  '.vscode',
};

/// Discovers all repositories under [root] using the provided [vcsList].
Future<List<Repo>> discoverRepos(
  Directory root,
  List<Vcs> vcsList, {
  int maxDepth = 4,
}) async {
  final found = <Repo>[];
  if (!await root.exists()) return found;

  Future<void> walk(Directory dir, int depth) async {
    for (final vcs in vcsList) {
      if (await vcs.isRepo(dir)) {
        final head = await vcs.headLabel(dir.path);
        final name = dir.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .lastOrNull ??
            dir.path;
        found.add(Repo(
          name: name,
          path: dir.path,
          vcs: vcs,
          head: head,
        ));
        break;
      }
    }

    if (depth >= maxDepth) return;

    List<FileSystemEntity> children;
    try {
      children = await dir.list(followLinks: false).toList();
    } catch (_) {
      return;
    }

    children.sort((a, b) => a.path.compareTo(b.path));
    for (final entity in children) {
      if (entity is Directory) {
        final seg = entity.uri.pathSegments
            .where((s) => s.isNotEmpty)
            .lastOrNull;
        if (seg == null || _ignoredDirNames.contains(seg) || seg.startsWith('.')) {
          continue;
        }
        await walk(entity, depth + 1);
      }
    }
  }

  await walk(root, 0);
  return found;
}
