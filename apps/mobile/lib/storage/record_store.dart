import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite/sqflite.dart';

/// The phone's local record store (spec 7.3).
///
/// It keeps the exact text of every record it did not reject, in SQLite.
/// It also holds one live [Validator]. The store never saves the ledger
/// itself: on open, it feeds the saved texts back through the validator to
/// rebuild the ledger. The saved text is the only fact; everything else is
/// calculated again. (CLAUDE.md rule 4.)
///
/// All texts go through [receive], the single entry point. A rejected text
/// never reaches the disk.
class RecordStore {
  RecordStore._(this._db, this.validator);

  final Database _db;

  /// Holds the ledger, pending records and equivocation flags.
  final Validator validator;

  /// Opens the store at [path], creating it if needed, and rebuilds the
  /// validator from every saved text.
  static Future<RecordStore> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(version: 1, onCreate: _createTables),
    );
    final store = RecordStore._(db, Validator());
    // Replaying in saved order gives the same ledger as the first run. The
    // validator's result does not depend on arrival order (spec section 8).
    for (final text in await store._savedTexts()) {
      await store.validator.receiveText(text);
    }
    return store;
  }

  /// Runs [text] through the validator and keeps it unless it was rejected.
  Future<ReceiveOutcome> receive(String text) async {
    final outcome = await validator.receiveText(text);
    if (_isKept(outcome)) await _insert(text);
    return outcome;
  }

  /// Every saved text, in the order it was first kept.
  Future<List<String>> savedTexts() => _savedTexts();

  Future<void> close() => _db.close();

  /// Rejected texts are never saved. Accepted, pending, chain-invalid and
  /// equivocating records are all kept: a pending record is released later,
  /// and both versions of an equivocation are evidence.
  static bool _isKept(ReceiveOutcome outcome) {
    switch (outcome) {
      case ReceiveOutcome.accepted:
      case ReceiveOutcome.pending:
      case ReceiveOutcome.chainInvalid:
      case ReceiveOutcome.equivocating:
      case ReceiveOutcome.duplicateIgnored:
        return true;
      case ReceiveOutcome.rejectedSchema:
      case ReceiveOutcome.rejectedNotCanonical:
      case ReceiveOutcome.rejectedSignature:
      case ReceiveOutcome.rejectedMembership:
      case ReceiveOutcome.idConflict:
        return false;
    }
  }

  Future<void> _insert(String text) async {
    final json = jsonDecode(text) as Map<String, dynamic>;
    await _db.insert('records', {
      // Same hash as the relay (SHA-256 of the exact text). UNIQUE, so a
      // repeated text is stored once.
      'hash': recordHash(json),
      'id': json['id'],
      'partnership': json['partnership'],
      'author': json['author'],
      'seq': json['seq'],
      'text': text,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<List<String>> _savedTexts() async {
    final rows = await _db.query('records', columns: ['text'], orderBy: 'n');
    return [for (final row in rows) row['text']! as String];
  }

  static Future<void> _createTables(Database db, int version) async {
    // `n` gives the saved order. Replay depends on it.
    await db.execute('''
      CREATE TABLE records (
        n INTEGER PRIMARY KEY AUTOINCREMENT,
        hash TEXT NOT NULL UNIQUE,
        id TEXT NOT NULL,
        partnership TEXT NOT NULL,
        author TEXT NOT NULL,
        seq INTEGER NOT NULL,
        text TEXT NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX records_by_position ON records (partnership, author, seq)',
    );
    // Same rule as the relay: records are never edited or deleted. The
    // triggers enforce it even if a later bug tries.
    await db.execute('''
      CREATE TRIGGER records_block_update BEFORE UPDATE ON records
      BEGIN SELECT RAISE(ABORT, 'records are append-only'); END
    ''');
    await db.execute('''
      CREATE TRIGGER records_block_delete BEFORE DELETE ON records
      BEGIN SELECT RAISE(ABORT, 'records are append-only'); END
    ''');
  }
}
