import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'budget_confirm_screen.dart';
import 'generic_confirm_screen.dart';
import 'partnership_create_confirm_screen.dart';
import 'reversal_confirm_screen.dart';
import 'settlement_confirm_screen.dart';
import 'withdrawal_confirm_screen.dart';

/// The list of records waiting for this partner's answer (spec 5, 6.7).
///
/// This screen does no maths. `approvalsInbox` (qirad_core) decides what is
/// pending and why an approve may be blocked; this screen only shows that
/// list and opens the right confirmation screen when an item is tapped.
class InboxScreen extends StatefulWidget {
  const InboxScreen({
    super.key,
    required this.store,
    required this.writer,
    required this.myKey,
    required this.partnership,
    required this.onSyncNow,
  });

  final RecordStore store;
  final RecordWriter writer;
  final String myKey;
  final String partnership;
  final Future<void> Function() onSyncNow;

  @override
  State<InboxScreen> createState() => _InboxScreenState();
}

class _InboxScreenState extends State<InboxScreen> {
  @override
  Widget build(BuildContext context) {
    final validator = widget.store.validatorFor(widget.partnership);
    final keys = validator.partnershipKeys ?? const <String>{};
    final items = approvalsInbox(
      validator.usableRecords,
      partnershipKeys: keys,
      myKey: widget.myKey,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
      body: items.isEmpty
          ? const Center(child: Text('Nothing is waiting for you.'))
          : ListView.separated(
              itemCount: items.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final item = items[index];
                return ListTile(
                  title: Text(_titleFor(item)),
                  subtitle: item.blockedReason == null
                      ? null
                      : Text(
                          item.blockedReason!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
                        ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(item),
                );
              },
            ),
    );
  }

  String _titleFor(InboxItem item) {
    switch (item.kind) {
      case InboxKind.settlement:
        return 'Settlement proposal';
      case InboxKind.withdrawal:
        final amount = item.target.body['amount'];
        return amount is int
            ? 'Withdrawal request: ${formatPaisa(amount)}'
            : 'Withdrawal request';
      case InboxKind.budget:
        return 'Budget proposal';
      case InboxKind.ratio:
        return 'Ratio change proposal';
      case InboxKind.partnershipStart:
        return 'Start of the partnership';
      case InboxKind.reversal:
        return 'Reversal';
    }
  }

  Future<void> _open(InboxItem item) async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (context) => switch (item.kind) {
          InboxKind.settlement => SettlementConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
          InboxKind.withdrawal => WithdrawalConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
          InboxKind.partnershipStart => PartnershipCreateConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
          InboxKind.reversal => ReversalConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
          InboxKind.budget => BudgetConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
          _ => GenericConfirmScreen(
            writer: widget.writer,
            targetId: item.target.id,
            title: _titleFor(item),
          ),
        },
      ),
    );
    if (changed == true && mounted) setState(() {});
  }
}
