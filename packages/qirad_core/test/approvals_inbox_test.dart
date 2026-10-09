import 'package:qirad_core/qirad_core.dart';
import 'package:test/test.dart';

import 'support/cut_helper.dart';
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
  String? refersTo,
}) => Record(
  v: 1,
  id: id,
  partnership: 'partnership-unit',
  author: author,
  seq: seq,
  prevHash: '0' * 64,
  type: type,
  body: body,
  refersTo: refersTo,
  note: '',
  time: '2026-10-06T10:00:00Z',
  sig: '',
);

void main() {
  group('approvals inbox (spec 5, 6.7)', () {
    test('the partnership start waits in the manager inbox', () async {
      final (validator, investor, manager, _) =
          await setUpUnapprovedPartnership();

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
        final create = validator.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: create,
              upToManager: sale,
            ),
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
        // Investor value 99: the investor has written only the create, so
        // seq 99 can never exist. No approve of this investor can ever
        // cover it. The manager value covers the sale, so only the
        // investor side of the cut is the point of this test.
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 99, manager.key: sale.seq},
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
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final sale = await manager.next(
        partnership: partnershipId,
        type: 'sale',
        body: {'amount': 600},
      );
      final s1 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': cutUpTo(
            investor,
            manager,
            upToInvestor: create,
            upToManager: sale,
          ),
        },
      );
      final s2 = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': cutUpTo(
            investor,
            manager,
            upToInvestor: create,
            upToManager: s1,
          ),
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

    test(
      'a settlement whose cut covers nothing new cannot be approved',
      () async {
        // The manager's very first settlement, proposing a cut of
        // {investor: 0, manager: 0}. This is schema-valid and `receive()`
        // accepts it, but cut rule 5 (spec 6.7) refuses an empty cut: there
        // is nothing new to settle. `approvalsInbox` must say so itself,
        // instead of showing it as approvable and letting the investor find
        // out only after approving that it went invalid.
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: 0},
          },
        );
        await _receive(validator, [s1]);

        final item = _inboxFor(validator, investor.key).single;
        expect(item.canApprove, isFalse);
        expect(
          item.blockedReason,
          'This settlement covers nothing new. Reject it.',
        );
      },
    );

    test(
      'a settlement whose cut moves backward from the last one cannot be approved',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final create = validator.usableRecords.singleWhere(
          (r) => r.type == 'partnership_create',
        );
        // An investor record after the create, so S1's cut can reach past
        // the create: S2 then regresses to the create alone, which still
        // covers the manager's approve-of-create (so closure has nothing to
        // say), but drops below S1's effective investor value.
        final invest = await investor.next(
          partnership: partnershipId,
          type: 'invest',
          body: {'amount': 100},
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': cutUpTo(
              investor,
              manager,
              upToInvestor: invest,
              upToManager: sale,
            ),
          },
        );
        final approveS1 = await investor.next(
          partnership: partnershipId,
          type: 'approve',
          refersTo: s1.id,
        );
        // Cut rule 4 (dominating) refuses this, even though cutIsHeld
        // passes (the manager value still only names the sale, which is
        // held, and the investor value still names the create, which is
        // held too — just not the invest S1 already covered).
        final s2 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: create.seq, manager.key: sale.seq},
          },
        );
        await _receive(validator, [invest, sale, s1, approveS1, s2]);

        final item = _inboxFor(
          validator,
          investor.key,
        ).singleWhere((i) => i.target.id == s2.id);
        expect(item.canApprove, isFalse);
        expect(
          item.blockedReason,
          'This settlement moves the cut backward. Reject it.',
        );
      },
    );

    test(
      'a settlement whose cut refers outside itself cannot be approved',
      () async {
        // The manager's expense (seq 2) refers to the investor's budget
        // proposal (investor seq 1), but the cut names investor value 0 —
        // so the expense is inside the cut while what it refers to is not.
        // Cut rule 3 (closed) refuses this.
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final budget = await investor.next(
          partnership: partnershipId,
          type: 'budget_proposal',
          body: {'grantee': manager.key, 'amount': 5000},
        );
        final sale = await manager.next(
          partnership: partnershipId,
          type: 'sale',
          body: {'amount': 600},
        );
        final expense = await manager.next(
          partnership: partnershipId,
          type: 'expense',
          body: {'amount': 1000, 'receiptHash': null},
          refersTo: budget.id,
        );
        final s1 = await manager.next(
          partnership: partnershipId,
          type: settlementType,
          body: {
            'cut': {investor.key: 0, manager.key: expense.seq},
          },
        );
        await _receive(validator, [budget, sale, expense, s1]);

        final item = _inboxFor(validator, investor.key).single;
        expect(item.canApprove, isFalse);
        expect(
          item.blockedReason,
          'This settlement refers to a record outside its own cut. Reject it.',
        );
      },
    );

    test('a malformed settlement cannot be approved', () async {
      final (validator, investor, manager, partnershipId) =
          await setUpPartnership();
      // Three keys is not a valid cut shape (spec 6.7, step 4a). This is a
      // business-layer rule, not a schema one, so the record is still
      // accepted and stored (spec section 5 only requires `cut` to be a
      // Map at the schema step) — unlike a settlement with a refersTo,
      // which the schema step itself now refuses outright.
      final create = validator.usableRecords.singleWhere(
        (r) => r.type == 'partnership_create',
      );
      final bad = await manager.next(
        partnership: partnershipId,
        type: settlementType,
        body: {
          'cut': {investor.key: create.seq, manager.key: 0, 'someone-else': 0},
        },
      );
      await _receive(validator, [bad]);

      final item = _inboxFor(validator, investor.key).single;
      expect(item.canApprove, isFalse);
      expect(item.blockedReason, 'Not a valid settlement. Reject it.');
    });

    test(
      'a request the author reverses before it is answered leaves the inbox',
      () async {
        final (validator, investor, manager, partnershipId) =
            await setUpPartnership();
        final withdraw = await investor.next(
          partnership: partnershipId,
          type: 'withdraw_request',
          body: {'amount': 500, 'kind': 'profit'},
        );
        // The investor cancels their own request before the manager answers it.
        // Spec section 5: a partner may reverse their own record at any time,
        // with no approval needed, so this takes effect right away.
        final reversal = await investor.next(
          partnership: partnershipId,
          type: 'reversal',
          refersTo: withdraw.id,
        );
        await _receive(validator, [withdraw, reversal]);

        expect(_inboxFor(validator, manager.key), isEmpty);
      },
    );

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
        // The create must be approved, or nothing but it is effective (spec
        // section 5), and this test is about a settlement, not the create.
        _record(
          id: 'approve-create',
          author: _manager,
          seq: 1,
          type: 'approve',
          refersTo: 'create',
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
