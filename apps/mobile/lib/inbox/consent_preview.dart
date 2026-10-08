import 'package:qirad_core/qirad_core.dart';
import 'package:uuid/uuid.dart';

/// An unsaved approve of [targetId], built on the current ledger, only to
/// read its consent summary before the real answer is written.
///
/// [RecordWriter.answer] builds the same kind of record and checks it the
/// same way, inside the write transaction (spec 6.7). This preview and that
/// real check read the same core functions, so they never disagree about
/// what the numbers are — only about whether the ledger has changed in
/// between, which is exactly what the optimistic check is for.
Record previewApprove({
  required Iterable<Record> ledger,
  required String author,
  required String partnership,
  required String targetId,
}) {
  return buildRecord(
    ledger: ledger,
    author: author,
    partnership: partnership,
    id: const Uuid().v4(),
    type: 'approve',
    body: const {},
    time: recordTimeText(DateTime.now()),
    refersTo: targetId,
  );
}

/// The display time in whole seconds, UTC (spec 3). This is only ever shown
/// to a person, never used to decide anything (hard rule 3): a preview
/// record is never saved, and the real record gets its own time when it is
/// actually written.
String recordTimeText(DateTime moment) =>
    '${moment.toUtc().toIso8601String().split('.').first}Z';
