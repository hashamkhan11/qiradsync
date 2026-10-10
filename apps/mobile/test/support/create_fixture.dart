import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mobile/storage/record_store.dart';
import 'package:mobile/storage/record_writer.dart';
import 'package:path/path.dart' as p;
import 'package:qirad_core/qirad_core.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'test_ids.dart';

/// A ready-made partnership for a creation-form widget test: an active
/// partnership, with helpers to write records directly (to set up a scene)
/// and writers for both partners (to drive the form under test).
///
/// Shared across the eight `*_form_test.dart` files so each one only has to
/// describe its own scene, not rebuild a store and a signed create every
/// time.
class CreateFixture {
  CreateFixture._(this.dir, this.store, this.investor, this.manager)
    : partnership = testId('partnership');

  static Future<CreateFixture> open() async {
    sqfliteFfiInit();
    final dir = await Directory.systemTemp.createTemp('qirad_create_test');
    final store = await RecordStore.open(
      factory: databaseFactoryFfi,
      path: p.join(dir.path, 'records.db'),
    );
    final investor = await generateEd25519KeyPair();
    final manager = await generateEd25519KeyPair();
    return CreateFixture._(dir, store, investor, manager);
  }

  final Directory dir;
  final RecordStore store;
  final Ed25519KeyPair investor;
  final Ed25519KeyPair manager;
  final String partnership;
  final List<Record> investorChain = [];
  final List<Record> managerChain = [];

  Future<void> close() async {
    await store.close();
    await dir.delete(recursive: true);
  }

  Future<Record> write(
    Ed25519KeyPair keys,
    List<Record> chain, {
    required String id,
    required String type,
    Map<String, dynamic> body = const {},
    String? refersTo,
  }) async {
    final unsigned = buildRecord(
      ledger: chain,
      author: keys.publicKeyBase64Url,
      partnership: partnership,
      id: testId(id),
      type: type,
      body: body,
      time: '2026-10-10T10:00:00Z',
      refersTo: refersTo,
    );
    final signed = await signRecord(unsigned, keys);
    chain.add(signed);
    return signed;
  }

  Future<void> receive(Record record) async {
    expect(
      await store.receive(canonicalJson(record.toJson())),
      ReceiveOutcome.accepted,
    );
  }

  Future<void> syncedAs({required int investorSeq, required int managerSeq}) =>
      store.saveRelayVector(partnership, {
        investor.publicKeyBase64Url: investorSeq,
        manager.publicKeyBase64Url: managerSeq,
      });

  /// The investor's create, saved with the pins (spec 2.1), with no approve
  /// yet, so the partnership is still pending (spec section 5). Synced, so a
  /// form's write is refused for `partnershipNotActive`, not `notSynced`.
  Future<void> startWithUnapprovedCreate({
    int investorRatio = 50,
    int managerRatio = 50,
  }) async {
    final create = await write(
      investor,
      investorChain,
      id: 'partnership',
      type: 'partnership_create',
      body: {
        'investor': investor.publicKeyBase64Url,
        'manager': manager.publicKeyBase64Url,
        'ratio': {'investor': investorRatio, 'manager': managerRatio},
        'currency': 'PKR',
      },
    );
    expect(
      await store.startPartnership(
        id: partnership,
        investorKey: investor.publicKeyBase64Url,
        managerKey: manager.publicKeyBase64Url,
        createText: canonicalJson(create.toJson()),
      ),
      ReceiveOutcome.accepted,
    );
    await syncedAs(investorSeq: 1, managerSeq: 0);
  }

  /// [startWithUnapprovedCreate], then the manager's approve of it, so the
  /// partnership is active (spec section 5) and creation forms can save.
  Future<void> startWithCreate({
    int investorRatio = 50,
    int managerRatio = 50,
  }) async {
    await startWithUnapprovedCreate(
      investorRatio: investorRatio,
      managerRatio: managerRatio,
    );
    await receive(
      await write(
        manager,
        managerChain,
        id: 'approve-create',
        type: 'approve',
        refersTo: testId('partnership'),
      ),
    );
    await syncedAs(investorSeq: 1, managerSeq: 1);
  }

  RecordWriter investorWriter() => RecordWriter.forTesting(
    keys: investor,
    partnership: partnership,
    store: store,
  );

  RecordWriter managerWriter() => RecordWriter.forTesting(
    keys: manager,
    partnership: partnership,
    store: store,
  );

  Future<List<Record>> savedRecords() async => [
    for (final text in await store.savedTexts(partnership))
      Record.fromJson(jsonDecode(text) as Map<String, dynamic>),
  ];

  /// An unsaved investor approve of [targetId], built on the saved ledger —
  /// only to read a settlement's consent summary before writing the real
  /// approve ([settlementConsentFor]).
  Record previewApprove(String targetId) => buildRecord(
    ledger: store.validatorFor(partnership).usableRecords,
    author: investor.publicKeyBase64Url,
    partnership: partnership,
    id: testId('preview-$targetId'),
    type: 'approve',
    body: const {},
    time: '2026-10-10T10:00:00Z',
    refersTo: targetId,
  );

  /// The summary the investor would be shown for settlement [proposal] now
  /// (spec 6.7) — what a form's own `answer` call needs as `shownSettlement`.
  SettlementConsent? settlementConsentFor(Record proposal) => settlementConsent(
    store.validatorFor(partnership).usableRecords,
    partnershipKeys: {investor.publicKeyBase64Url, manager.publicKeyBase64Url},
    proposal: proposal,
    answer: previewApprove(proposal.id),
  );
}
