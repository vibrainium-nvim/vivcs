import 'package:test/test.dart';
import 'package:vivcs/vivcs.dart';

void main() {
  group('SidebarTreeState', () {
    test('renders Unstaged, Staged, and Commits for VCS with staging area', () {
      final tree = SidebarTreeState();
      final repo = const Repo(
        name: 'my_git_repo',
        path: '/work/my_git_repo',
        vcs: Git(),
        head: 'main',
      );

      final rendered = tree.build(
        activeRepo: repo,
        totalRepos: 2,
        status: const RepoStatus(
          unstaged: [
            ChangedFile(path: 'lib/src/app.dart', status: FileStatus.modified),
          ],
          staged: [
            ChangedFile(path: 'pubspec.yaml', status: FileStatus.modified),
          ],
        ),
        commits: const [
          Commit(
            id: 'abc123456',
            shortId: 'abc1234',
            author: 'Teja',
            date: '2h ago',
            message: 'Init project',
          ),
        ],
      );

      expect(rendered.lines[0], contains('my_git_repo (git • main) ▾'));
      expect(rendered.lines, contains('▾ Unstaged (1)'));
      expect(rendered.lines, contains('▾ Staged (1)'));
      expect(rendered.lines, contains('▾ Commits (1)'));
      expect(rendered.lines.any((l) => l.contains('lib/')), isTrue);
      expect(rendered.lines.any((l) => l.contains('src/')), isTrue);
      expect(rendered.lines.any((l) => l.contains('M app.dart')), isTrue);
      expect(rendered.lines.any((l) => l.contains('M pubspec.yaml')), isTrue);
    });

    test('omits Staged section for VCS without staging area (e.g. SVN)', () {
      final tree = SidebarTreeState();
      final repo = const Repo(
        name: 'my_svn_repo',
        path: '/work/my_svn_repo',
        vcs: Svn(),
        head: 'r42',
      );

      final rendered = tree.build(
        activeRepo: repo,
        totalRepos: 1,
        status: const RepoStatus(
          unstaged: [
            ChangedFile(path: 'trunk/main.dart', status: FileStatus.modified),
          ],
        ),
        commits: const [],
      );

      expect(rendered.lines[0], contains('my_svn_repo (svn • r42) ▾'));
      expect(rendered.lines, contains('▾ Unstaged (1)'));
      expect(rendered.lines.any((l) => l.contains('Staged')), isFalse);
      expect(rendered.lines, contains('▾ Commits (0)'));
    });

    test('supports collapsing directories and expanding commits', () {
      final tree = SidebarTreeState();
      final repo = const Repo(
        name: 'demo',
        path: '/demo',
        vcs: Git(),
        head: 'main',
      );

      tree.toggleDir(SectionKind.unstaged, 'lib');
      tree.toggleCommit('c1');
      tree.commitFilesCache['c1'] = const [
        ChangedFile(path: 'README.md', status: FileStatus.added),
      ];

      final rendered = tree.build(
        activeRepo: repo,
        totalRepos: 1,
        status: const RepoStatus(
          unstaged: [
            ChangedFile(path: 'lib/hidden.dart', status: FileStatus.modified),
          ],
        ),
        commits: const [
          Commit(
            id: 'c1',
            shortId: 'c1',
            author: 'Teja',
            date: 'now',
            message: 'Add readme',
          ),
        ],
      );

      expect(rendered.lines.any((l) => l.contains('▸ lib/')), isTrue);
      expect(rendered.lines.any((l) => l.contains('hidden.dart')), isFalse);
      expect(rendered.lines.any((l) => l.contains('A README.md')), isTrue);
    });
  });
}
