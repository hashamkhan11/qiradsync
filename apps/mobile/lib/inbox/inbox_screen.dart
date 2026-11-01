import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'budget_confirm_screen.dart';
import 'partnership_create_confirm_screen.dart';
import 'ratio_confirm_screen.dart';
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

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Inbox')),
      body: items.isEmpty
          ? Center(
              child: Text(
                'Nothing is waiting for you.',
                style: theme.textTheme.bodyMedium,
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: theme.colorScheme.outline),
              itemBuilder: (context, index) {
                final item = items[index];
                final blocked = item.blockedReason;
                return ListTile(
                  leading: Icon(_iconFor(item.kind), color: theme.colorScheme.primary),
                  title: Text(_titleFor(item), style: theme.textTheme.bodyMedium),
                  subtitle: blocked == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(
                                Icons.error_outline,
                                size: 14,
                                color: theme.colorScheme.error,
                              ),
                              const SizedBox(width: 5),
                              Expanded(
                                child: Text(
                                  blocked,
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.error,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                  trailing: Icon(
                    Icons.chevron_right,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onTap: () => _open(item),
                );
              },
            ),
    );
  }

  /// A kind-specific glyph so the inbox reads at a glance (spec 5, 6.7): no
  /// meaning is carried by the icon alone, since the title text next to it
  /// always names the same thing in words.
  IconData _iconFor(InboxKind kind) {
    switch (kind) {
      case InboxKind.settlement:
        return Icons.fact_check_outlined;
      case InboxKind.withdrawal:
        return Icons.north_east;
      case InboxKind.budget:
        return Icons.account_balance_wallet_outlined;
      case InboxKind.ratio:
        return Icons.balance_outlined;
      case InboxKind.partnershipStart:
        return Icons.flag_outlined;
      case InboxKind.reversal:
        return Icons.undo;
    }
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
          InboxKind.ratio => RatioConfirmScreen(
            store: widget.store,
            writer: widget.writer,
            myKey: widget.myKey,
            partnership: widget.partnership,
            targetId: item.target.id,
            onSyncNow: widget.onSyncNow,
          ),
        },
      ),
    );
    if (changed != true) return;
    // Sync trigger: right after this device writes an answer, so the other
    // partner sees it as soon as possible and this screen's own badge count
    // (recomputed by the parent, since `onSyncNow` updates its state too)
    // reflects it (spec 7.3).
    await widget.onSyncNow();
    if (mounted) setState(() {});
  }
}
