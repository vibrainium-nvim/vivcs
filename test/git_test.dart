import 'package:test/test.dart';
import 'package:vivcs/vivcs.dart';

void main() {
  group('Git VCS', () {
    test('parses porcelain v1 -z status into unstaged and staged lists', () {
      const raw = 'M  lib/staged.dart\x00'
          ' M lib/unstaged.dart\x00'
          'MM lib/both.dart\x00'
          '?? lib/new_file.dart\x00'
          'R  lib/renamed_new.dart\x00lib/renamed_old.dart\x00';

      final status = Git.parsePorcelainStatus(raw);

      expect(status.staged, [
        const ChangedFile(path: 'lib/staged.dart', status: FileStatus.modified),
        const ChangedFile(path: 'lib/both.dart', status: FileStatus.modified),
        const ChangedFile(
          path: 'lib/renamed_new.dart',
          status: FileStatus.renamed,
          oldPath: 'lib/renamed_old.dart',
        ),
      ]);

      expect(status.unstaged, [
        const ChangedFile(path: 'lib/unstaged.dart', status: FileStatus.modified),
        const ChangedFile(path: 'lib/both.dart', status: FileStatus.modified),
        const ChangedFile(path: 'lib/new_file.dart', status: FileStatus.untracked),
      ]);
    });

    test('parses git log and diff-tree output', () {
      const logOutput =
          'abcdef1234567890\x00abcdef1\x00Alice\x002 hours ago\x00Initial commit\x1e'
          '1234567890abcdef\x001234567\x00Bob\x001 day ago\x00Add sidebar\x1e';

      final commits = Git.parseGitLog(logOutput);
      expect(commits, hasLength(2));
      expect(commits[0].shortId, 'abcdef1');
      expect(commits[0].author, 'Alice');
      expect(commits[0].message, 'Initial commit');
      expect(commits[1].shortId, '1234567');

      const diffTreeOutput =
          'M\x00lib/viff.dart\x00A\x00lib/new.dart\x00R100\x00lib/old.dart\x00lib/moved.dart\x00';
      final files = Git.parseDiffTree(diffTreeOutput);
      expect(files, [
        const ChangedFile(path: 'lib/viff.dart', status: FileStatus.modified),
        const ChangedFile(path: 'lib/new.dart', status: FileStatus.added),
        const ChangedFile(
          path: 'lib/moved.dart',
          status: FileStatus.renamed,
          oldPath: 'lib/old.dart',
        ),
      ]);
    });

    test('executes stage, unstage, and commit commands', () async {
      final executed = <(String, List<String>)>[];
      final git = Git(
        run: (exe, args, {required workingDirectory}) async {
          executed.add((exe, args));
          return const CommandResult(exitCode: 0, stdout: 'main\n', stderr: '');
        },
      );

      expect(git.hasStagingArea, isTrue);
      expect(await git.headLabel('/repo'), 'main');

      await git.stage('/repo', ['a.dart']);
      await git.unstage('/repo', ['a.dart']);
      await git.commit('/repo', 'feat: add sidebar');

      expect(executed[1].$1, 'git');
      expect(executed[1].$2, ['add', '--', 'a.dart']);
      expect(executed[2].$1, 'git');
      expect(executed[2].$2, ['reset', 'HEAD', '--', 'a.dart']);
      expect(executed[3].$1, 'git');
      expect(executed[3].$2, ['commit', '-m', 'feat: add sidebar']);
    });
  });
}
