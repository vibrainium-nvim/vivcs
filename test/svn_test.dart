import 'package:test/test.dart';
import 'package:vivcs/vivcs.dart';

void main() {
  group('Svn VCS', () {
    test('hasStagingArea is false and parses svn status XML', () {
      const svn = Svn();
      expect(svn.hasStagingArea, isFalse);

      const xml = '''
<?xml version="1.0" encoding="UTF-8"?>
<status>
  <target path=".">
    <entry path="src/main.dart">
      <wc-status props="none" item="modified" revision="42"/>
    </entry>
    <entry path="src/new.dart">
      <wc-status props="none" item="unversioned"/>
    </entry>
    <entry path="src/old.dart">
      <wc-status props="none" item="deleted" revision="42"/>
    </entry>
  </target>
</status>
''';

      final status = Svn.parseSvnStatusXml(xml);
      expect(status.staged, isEmpty);
      expect(status.unstaged, [
        const ChangedFile(path: 'src/main.dart', status: FileStatus.modified),
        const ChangedFile(path: 'src/new.dart', status: FileStatus.untracked),
        const ChangedFile(path: 'src/old.dart', status: FileStatus.deleted),
      ]);
    });

    test('parses svn log XML and commit files XML', () {
      const logXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<log>
  <logentry revision="105">
    <author>teja</author>
    <date>2026-10-26T12:00:00.000000Z</date>
    <msg>Fix parser edge case</msg>
  </logentry>
</log>
''';
      final commits = Svn.parseSvnLogXml(logXml);
      expect(commits, hasLength(1));
      expect(commits.first.shortId, 'r105');
      expect(commits.first.author, 'teja');
      expect(commits.first.date, '2026-10-26');
      expect(commits.first.message, 'Fix parser edge case');

      const filesXml = '''
<?xml version="1.0" encoding="UTF-8"?>
<log>
  <logentry revision="105">
    <paths>
      <path kind="file" action="M">/trunk/src/main.dart</path>
      <path kind="file" action="A">/trunk/src/added.dart</path>
    </paths>
  </logentry>
</log>
''';
      final files = Svn.parseSvnCommitFilesXml(filesXml);
      expect(files, [
        const ChangedFile(path: 'trunk/src/main.dart', status: FileStatus.modified),
        const ChangedFile(path: 'trunk/src/added.dart', status: FileStatus.added),
      ]);
    });
  });
}
