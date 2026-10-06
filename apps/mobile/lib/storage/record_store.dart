import 'dart:convert';

import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite/sqflite.dart';

/// The phone's local record store (spec 7.3).
///
/// It keeps the exact text of every record it did not reject, in SQLite.
/// A phone can hold several partnerships (spec 7.1), so the store keeps one
/// [Validator] per registered partnership id. Each text goes to the validator
/// for its own `partnership` field, so the partnerships never mix.
///
/// The store never saves the ledger itself: on open, it feeds the saved texts
/// back through the validators to rebuild the ledgers. The saved text is the
/// only fact; everything else is calculated again (docs/spec.md, section 1).
///
/// A partnership must be registered with [addPartnership] before any of its
/// records is accepted. Incoming data never creates a partnership, so a
/// malicious relay cannot make the phone create unlimited storage.
class RecordStore {
  RecordStore._(this._db, this._validators);

  final Database _db;

  /// One validator per registered partnership id.
  final Map<String, Validator> _validators;

  /// Opens the store at [path], creating it if needed, and rebuilds every
  /// registered partnership's validator from its saved texts.
  static Future<RecordStore> open({
    required DatabaseFactory factory,
    required String path,
  }) async {
    final db = await factory.openDatabase(
      path,
      options: OpenDatabaseOptions(
        version: 2,
        onCreate: _createTables,
        onUpgrade: _upgradeTables,
      ),
    );

    final validators = <String, Validator>{};
    final registered = await db.query(
      'partnerships',
      columns: ['id', 'investor_key', 'manager_key'],
    );
    for (final row in registered) {
      validators[row['id']! as String] = Validator(
        pinnedInvestorKey: row['investor_key']! as String,
        pinnedManagerKey: row['manager_key']! as String,
      );
    }

    final store = RecordStore._(db, validators);
    // Replaying in saved order gives the same ledger as the first run. The
    // validator's result does not depend on arrival order (spec section 8).
    // The replay does not insert again: the rows are already on disk.
    final rows = await db.query(
      'records',
      columns: ['partnership', 'text'],
      orderBy: 'n',
    );
    for (final row in rows) {
      final validator = validators[row['partnership']! as String];
      await validator?.receiveText(row['text']! as String);
    }
    return store;
  }

  /// The partnership ids registered on this device, sorted.
  List<String> get partnerships => _validators.keys.toList()..sort();

  /// Registers [id] on this device, pinned to its two keys (spec 2.1). The
  /// keys come from the join code, so the validator accepts only a create
  /// that names them. Called only when the user creates or joins the
  /// partnership. Calling it again with the same keys changes nothing; with
  /// different keys it throws, because a partnership cannot change its keys.
  Future<void> addPartnership(
    String id, {
    required String investorKey,
    required String managerKey,
  }) async {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    final existing = _validators[id];
    if (existing != null) {
      if (existing.pinnedInvestorKey == investorKey &&
          existing.pinnedManagerKey == managerKey) {
        return;
      }
      throw StateError('partnership $id is already registered with other keys');
    }
    await _db.insert('partnerships', {
      'id': id,
      'investor_key': investorKey,
      'manager_key': managerKey,
    });
    _validators[id] = Validator(
      pinnedInvestorKey: investorKey,
      pinnedManagerKey: managerKey,
    );
  }

  /// Starts a partnership: pins its keys and saves its `partnership_create`,
  /// in one database transaction (spec 2.1).
  ///
  /// The create is checked by a validator that holds the new pins, so it must
  /// pass the same checks as any record. If it is refused, the throw rolls the
  /// transaction back: no partnership row, no pins and no record are left.
  /// The phone only registers the partnership in memory after the commit.
  Future<ReceiveOutcome> startPartnership({
    required String id,
    required String investorKey,
    required String managerKey,
    required String createText,
  }) async {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (_validators.containsKey(id)) {
      throw StateError('partnership $id is already registered');
    }

    final candidate = Validator(
      pinnedInvestorKey: investorKey,
      pinnedManagerKey: managerKey,
    );
    try {
      await _db.transaction((txn) async {
        await txn.insert('partnerships', {
          'id': id,
          'investor_key': investorKey,
          'manager_key': managerKey,
        });
        final outcome = await candidate.receiveText(createText);
        if (!_isKept(outcome)) throw _CreateRefused(outcome);
        await _insertWith(txn, createText, id);
      });
    } on _CreateRefused catch (refused) {
      return refused.outcome;
    }
    _validators[id] = candidate;
    return ReceiveOutcome.accepted;
  }

  /// The live validator (and so the ledger) for a registered partnership.
  Validator validatorFor(String partnership) {
    final validator = _validators[partnership];
    if (validator == null) {
      throw StateError('partnership $partnership is not registered here');
    }
    return validator;
  }

  /// `{ author -> highest seq held without gaps }` for one partnership.
  /// The id is required, so one partnership's vector can never include
  /// another's records (spec 7.1).
  Map<String, int> versionVector(String partnership) =>
      validatorFor(partnership).ledger.versionVector();

  /// Runs [text] through the validator for its partnership and keeps it
  /// unless it was rejected. A text for an unregistered partnership is
  /// refused as `rejectedMembership` and never stored.
  Future<ReceiveOutcome> receive(String text) => _serial(() async {
    final partnership = _partnershipOf(text);
    if (partnership == null) return ReceiveOutcome.rejectedSchema;

    final validator = _validators[partnership];
    if (validator == null) return ReceiveOutcome.rejectedMembership;

    final outcome = await validator.receiveText(text);
    if (!_isKept(outcome)) return outcome;
    try {
      await _insert(text, partnership);
    } catch (_) {
      // Same rule as appendWith: the validator must never hold a record the
      // database does not, or the next own write could fork the chain.
      _validators[partnership] = await _rebuildValidator(partnership);
      rethrow;
    }
    return outcome;
  });

  /// The relay's vector from the latest sync reply for [partnership], or `null`
  /// when this install has never synced it (spec 7.4). Saved after every reply,
  /// so it is never older than the last reply the phone got.
  Future<Map<String, int>?> relayVectorFor(String partnership) async {
    final rows = await _db.query(
      'sync_state',
      columns: ['vector'],
      where: 'partnership = ?',
      whereArgs: [partnership],
    );
    if (rows.isEmpty) return null;
    final decoded = jsonDecode(rows.single['vector']! as String) as Map;
    return {
      for (final entry in decoded.entries)
        entry.key as String: entry.value as int,
    };
  }

  /// Saves the relay's vector from a sync reply (spec 7.2, 7.3 step 3).
  Future<void> saveRelayVector(
    String partnership,
    Map<String, int> vector,
  ) async {
    validatorFor(partnership); // Refuses an unregistered id.
    await _db.insert('sync_state', {
      'partnership': partnership,
      'vector': jsonEncode(vector),
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Builds and saves one record, in one step that cannot be split (spec 7.4).
  ///
  /// [build] gets every saved text of [partnership] and returns the text to
  /// save, or `null` to write nothing. The read, the build and the insert run in
  /// one transaction, inside the store's write queue. So two writes cannot read
  /// the same chain and pick the same seq.
  ///
  /// The validator checks the text before the insert, so it can take the text
  /// before the database does. If anything then fails, the validator is rebuilt
  /// from the database. Without that, the next write would reuse the seq of a
  /// record that was never saved, which is a fork.
  Future<String?> appendWith(
    String partnership,
    Future<String?> Function(List<String> savedTexts) build,
  ) => _serial(() async {
    final validator = validatorFor(partnership);
    String? saved;
    try {
      await _db.transaction((txn) async {
        final rows = await txn.query(
          'records',
          columns: ['text'],
          where: 'partnership = ?',
          whereArgs: [partnership],
          orderBy: 'n',
        );
        final texts = [for (final row in rows) row['text']! as String];
        final text = await build(texts);
        if (text == null) return;

        final outcome = await validator.receiveText(text);
        if (outcome != ReceiveOutcome.accepted) {
          throw StateError('a record this phone built was refused: $outcome');
        }
        await _insertWith(txn, text, partnership);
        saved = text;
      });
    } catch (_) {
      _validators[partnership] = await _rebuildValidator(partnership);
      rethrow;
    }
    return saved;
  });

  /// A fresh validator for [partnership], fed from the saved texts only. It is
  /// the same result as the start-up replay, so it matches the database.
  Future<Validator> _rebuildValidator(String partnership) async {
    // The pins come from the database, the same place the open() replay reads them.
    final pins = (await _db.query(
      'partnerships',
      columns: ['investor_key', 'manager_key'],
      where: 'id = ?',
      whereArgs: [partnership],
    )).single;
    final fresh = Validator(
      pinnedInvestorKey: pins['investor_key']! as String,
      pinnedManagerKey: pins['manager_key']! as String,
    );
    for (final text in await savedTexts(partnership)) {
      await fresh.receiveText(text);
    }
    return fresh;
  }

  /// Upgrades a store from an older version. Version 2 adds the sync state.
  static Future<void> _upgradeTables(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) await _createSyncState(db);
  }

  static Future<void> _createSyncState(Database db) => db.execute('''
      CREATE TABLE sync_state (
        partnership TEXT PRIMARY KEY,
        vector TEXT NOT NULL
      )
    ''');

  /// The one queue for every write to this store. Sync receives and local
  /// writes both go through it. A failed step does not block the next one.
  Future<void> _queue = Future<void>.value();

  Future<T> _serial<T>(Future<T> Function() action) {
    final run = _queue.then((_) => action());
    _queue = run.then<void>((_) {}, onError: (_) {});
    return run;
  }

  /// Every saved text of one partnership, in the order it was first kept.
  Future<List<String>> savedTexts(String partnership) async {
    validatorFor(partnership); // Refuses an unregistered id.
    final rows = await _db.query(
      'records',
      columns: ['text'],
      where: 'partnership = ?',
      whereArgs: [partnership],
      orderBy: 'n',
    );
    return [for (final row in rows) row['text']! as String];
  }

  /// The saved texts of one author in one partnership, from [fromSeq] on, in
  /// seq order. The sync repair step uses this to re-upload what the relay is
  /// missing (spec 7.3 step 3).
  Future<List<String>> savedTextsFrom(
    String partnership, {
    required String author,
    required int fromSeq,
  }) async {
    validatorFor(partnership); // Refuses an unregistered id.
    final rows = await _db.query(
      'records',
      columns: ['text'],
      where: 'partnership = ? AND author = ? AND seq >= ?',
      whereArgs: [partnership, author, fromSeq],
      orderBy: 'seq',
    );
    return [for (final row in rows) row['text']! as String];
  }

  Future<void> close() => _db.close();

  /// The `partnership` field of [text], or null if the text is not a JSON
  /// object with a string in that field. The validator does the full checks
  /// after this; this only picks the validator to ask.
  static String? _partnershipOf(String text) {
    final Object? decoded;
    try {
      decoded = jsonDecode(text);
    } on FormatException {
      return null;
    }
    if (decoded is! Map<String, dynamic>) return null;
    final partnership = decoded['partnership'];
    return partnership is String ? partnership : null;
  }

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

  Future<void> _insert(String text, String partnership) =>
      _insertWith(_db, text, partnership);

  /// Stores one text on [executor], which is the database or a transaction.
  static Future<void> _insertWith(
    DatabaseExecutor executor,
    String text,
    String partnership,
  ) async {
    final json = jsonDecode(text) as Map<String, dynamic>;
    await executor.insert('records', {
      // Same hash as the relay (SHA-256 of the exact text). UNIQUE, so a
      // repeated text is stored once.
      'hash': recordHash(json),
      'id': json['id'],
      'partnership': partnership,
      'author': json['author'],
      'seq': json['seq'],
      'text': text,
    }, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  static Future<void> _createTables(Database db, int version) async {
    // The pins are stored with the id, so a restart pins the same keys.
    await db.execute('''
      CREATE TABLE partnerships (
        id TEXT PRIMARY KEY,
        investor_key TEXT NOT NULL,
        manager_key TEXT NOT NULL
      )
    ''');
    await _createSyncState(db);
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

/// Thrown inside a transaction to roll it back when a create is refused.
/// Private, so it never leaves this file.
class _CreateRefused implements Exception {
  const _CreateRefused(this.outcome);

  final ReceiveOutcome outcome;
}
