import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/partnership_fixture.dart';

const _investor = 'investor-key';
const _manager = 'manager-key';

Future<void> _receive(Validator validator, Iterable<Record> records) async {
  for (final record in records) {
    await validator.receiveText(canonicalJson(record.toJson()));
  }
}

List<InboxItem> _allItems(Validator validator, String myKey) => approvalsInbox(
  validator.usableRecords,
  partnershipKeys: validator.partnershipKeys!,
  myKey: myKey,
);

/// The inbox without the partnership start. Every fixture has an unapproved
/// `partnership_create`, which the manager is asked to approve. These tests are
/// about the other records, so they leave it out. A test below checks it.
List<InboxItem> _inboxFor(Validator validator, String myKey) => _allItems(
  validator,
  myKey,
).where((i) => i.kind != InboxKind.partnershipStart).toList();

Record _record({
  required String id,
  required String author,
  required int seq,
  required String type,
  Map<String, dynamic> body = const {},
}) => Record(
  v: 1,
  id: id,
  partnership: 'partnership-unit',
  author: author,
  seq: seq,
  prevHash: '0' * 64,
  type: type,
  body: body,
  refersTo: null,
  note: '',
  time: '2026-10-06T10:00:00Z',
  sig: '',
);

void main() {
  group('approvals inbox (spec 5, 6.7)', () {
    test('the partnership start waits in the manager inbox', () async {
      final (validator, investor, manager, _) = await setUpPartnership();

      final managerItems = _allItems(validator, manager.key);
      expect(managerItems.single.kind, InboxKind.partnershipStart);
      expect(managerItems.single.canApprove, isTrue);
      expect(_allItems(validator, investor.key), isEmpty);
    });

    test(
      'a withdrawal waits in the manager inbox, not the investor inbox',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        await _receive(validator, [withdraw]);

        final managerItems = _inboxFor(validator, manager.key);
        expect(managerItems.map((i) => i.target.id), [withdraw.id]);
        expect(managerItems.single.kind, InboxKind.withdrawal);
        expect(managerItems.single.canApprove, isTrue);

        // The investor never answers their own request.
        expect(_inboxFor(validator, investor.key), isEmpty);
      },
    );

    test('an answered withdrawal leaves the inbox', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final withdraw = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 500, 'kind': 'profit'},
      );
      final approve = await manager.next(
        partnership: partnershipId,
        type: 'approve',
        refersTo: withdraw.id,
      );
      await _receive(validator, [withdraw, approve]);

      expect(_inboxFor(validator, manager.key), isEmpty);
    });

    test(
      'a held settlement with a valid cut can be approved by the investor',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 1, manager.key: 1},
          },
        );
        await _receive(validator, [sale, s1]);

        final items = _inboxFor(validator, investor.key);
        expect(items.single.kind, InboxKind.settlement);
        expect(items.single.canApprove, isTrue);
        expect(items.single.blockedReason, isNull);

        // The manager wrote the settlement, so it is not in their inbox.
        expect(_inboxFor(validator, manager.key), isEmpty);
      },
    );

    test(
      'a settlement whose cut names an investor record that does not exist cannot be approved',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        // Investor value 99: the investor has written only seq 1, so seq 2 is the
        // next free seq. No approve of this investor can ever cover seq 99.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 99, manager.key: 1},
          },
        );
        await _receive(validator, [sale, s1]);

        final item = _inboxFor(validator, investor.key).single;
        expect(item.canApprove, isFalse);
        expect(
          item.blockedReason,
          'Covers investor records that do not exist. Reject it.',
        );
      },
    );

    test('a second settlement waits until the first one is answered', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 600},
      );
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 1},
        },
      );
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: 1, manager.key: 2},
        },
      );
      await _receive(validator, [sale, s1, s2]);

      final items = _inboxFor(validator, investor.key);
      final first = items.singleWhere((i) => i.target.id == s1.id);
      final second = items.singleWhere((i) => i.target.id == s2.id);
      expect(first.canApprove, isTrue);
      expect(second.canApprove, isFalse);
      expect(second.blockedReason, 'Answer the earlier settlement first.');
    });

    test('a malformed settlement cannot be approved', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // A settlement with a refersTo is malformed (spec 6.7, rule 2).
      final bad = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        refersTo: 'some-record',
        body: {
          'cut': {investor.key: 1, manager.key: 0},
        },
      );
      await _receive(validator, [bad]);

      final item = _inboxFor(validator, investor.key).single;
      expect(item.canApprove, isFalse);
      expect(item.blockedReason, 'Not a valid settlement. Reject it.');
    });

    test('a phone that is not a partner has an empty inbox', () async {
      final (validator, investor, _, partnershipId) = await setUpPartnership();
      final withdraw = await investor.next(
        partnership: partnershipId,
        type: 'withdraw_request',
        body: {'amount': 500, 'kind': 'profit'},
      );
      await _receive(validator, [withdraw]);

      final outsider = await generateEd25519KeyPair();
      expect(_allItems(validator, outsider.publicKeyBase64Url), isEmpty);
    });
  });

  group('approvals inbox with hand-built records (spec 6.7, UI rule)', () {
    // Chains have no gaps, so a stored settlement always has its cut held. This
    // check is kept for defence in depth, and the screen still needs its
    // message, so the case is built by hand here.
    test('a settlement whose cut is not held says to wait for sync', () {
      final records = [
        _record(
          id: 'create',
          author: _investor,
          seq: 1,
          type: 'partnership_create',
          body: {
            'investor': _investor,
            'manager': _manager,
            'ratio': {'investor': 60, 'manager': 40},
          },
        ),
        // Manager seq 3, cut names manager seq 2, which this phone does not hold.
        _record(
          id: 's1',
          author: _manager,
          seq: 3,
          type: settlementType,
          body: {
            'cut': {_investor: 1, _manager: 2},
          },
        ),
      ];

      final items = approvalsInbox(
        records,
        partnershipKeys: {_investor, _manager},
        myKey: _investor,
      ).where((i) => i.kind == InboxKind.settlement).toList();

      expect(items.single.canApprove, isFalse);
      expect(items.single.blockedReason, 'Waiting for records to sync.');
    });
  });
}
