import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'approve_gate.dart';
import 'confirm_widgets.dart';
import 'refusal_text.dart';

/// Shows a budget proposal's numbers and lets the other partner approve or
/// reject it (spec section 5, 6.4).
///
/// Same optimistic-check pattern as [WithdrawalConfirmScreen]: the numbers
/// shown are frozen until a real mismatch comes back from the writer.
/// `budgetConsent` reads the ledger as it stands now, with no candidate
/// answer added — a proposal only becomes a budget once approved, so there
/// is nothing to preview the effect of yet.
class BudgetConfirmScreen extends StatefulWidget {
  const BudgetConfirmScreen({
    super.key,
    required this.store,
    required this.writer,
    required this.myKey,
    required this.partnership,
    required this.targetId,
    required this.onSyncNow,
  });

  final RecordStore store;
  final RecordWriter writer;
  final String myKey;
  final String partnership;
  final String targetId;
  final Future<void> Function() onSyncNow;

  @override
  State<BudgetConfirmScreen> createState() => _BudgetConfirmScreenState();
}

class _BudgetConfirmScreenState extends State<BudgetConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  BudgetConsent? _shown;
  BudgetConsent? _previous;

  @override
  Widget build(BuildContext context) {
    final validator = widget.store.validatorFor(widget.partnership);
    final usable = validator.usableRecords;
    final keys = validator.partnershipKeys ?? const <String>{};
    final items = approvalsInbox(
      usable,
      partnershipKeys: keys,
      myKey: widget.myKey,
    );
    final matches = items.where((item) => item.target.id == widget.targetId);

    if (matches.isEmpty) {
      // A budget_proposal cannot be reversed (spec section 5: closing one
      // early raises a cross-author ordering question, so it is future
      // work), so it can never be cancelled by its own author. The only way
      // this item leaves the inbox is a real answer.
      return Scaffold(
        appBar: AppBar(title: const Text('Budget proposal')),
        body: const Center(child: Text('This was already answered.')),
      );
    }
    final item = matches.single;

    _shown ??= budgetConsent(
      usable,
      partnershipKeys: keys,
      proposal: item.target,
    );
    final summary = _shown;
    // The inbox never blocks a budget proposal (`approvalsInbox` always
    // gives it `blockedReason: null`), so only the summary and sync state
    // can hide Approve here.
    final showApprove = canShowApprove(
      summary: summary,
      blockedReason: item.blockedReason,
      needsSync: _needsSync,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Budget proposal')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_needsSync)
            InboxSyncBanner(
              message: 'This phone must sync before it can answer.',
              syncing: _syncing,
              onSyncNow: _sync,
            ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            InboxBanner(_message!, emphasis: true),
          ],
          const SizedBox(height: 16),
          if (summary != null)
            ..._summaryRows(summary, _previous)
          else if (!_needsSync)
            const Text('No numbers to show yet.'),
          const SizedBox(height: 24),
          Row(
            children: [
              if (showApprove) ...[
                ElevatedButton(
                  onPressed: _writing ? null : _approve,
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 12),
              ],
              OutlinedButton(
                onPressed: _writing ? null : _confirmReject,
                child: const Text('Reject'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _summaryRows(BudgetConsent now, BudgetConsent? previous) {
    final grantee = now.grantee == widget.myKey ? 'You' : now.grantee;
    return [
      InboxSummaryRow(
        label: 'Grantee',
        value: grantee,
        changed: previous != null && previous.grantee != now.grantee,
      ),
      InboxSummaryRow(
        label: 'Amount',
        value: formatPaisa(now.amount),
        changed: previous != null && previous.amount != now.amount,
      ),
      InboxSummaryRow(
        label: 'Cash balance now',
        value: formatPaisa(now.cashBalance),
        changed: previous != null && previous.cashBalance != now.cashBalance,
      ),
      InboxSummaryRow(
        label: 'Other open budgets',
        value: formatPaisa(now.openBudgets),
        changed: previous != null && previous.openBudgets != now.openBudgets,
      ),
      if (now.overCommitted)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'Approving this would let open budgets exceed the cash '
            'actually available. This is allowed, but worth checking.',
          ),
        ),
    ];
  }

  Future<void> _sync() async {
    setState(() {
      _syncing = true;
      _message = null;
    });
    await widget.onSyncNow();
    if (!mounted) return;
    setState(() {
      _syncing = false;
      _needsSync = false;
    });
  }

  Future<void> _approve() async {
    final shown = _shown;
    if (shown == null) return;
    setState(() {
      _writing = true;
      _message = null;
    });
    final result = await widget.writer.answer(
      widget.targetId,
      approve: true,
      shownBudget: shown,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!, latest: result.latestBudget);
  }

  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this budget proposal?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reject'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    setState(() {
      _writing = true;
      _message = null;
    });
    final result = await widget.writer.answer(widget.targetId, approve: false);
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!);
  }

  void _handleRefusal(WriteRefusal refusal, {BudgetConsent? latest}) {
    switch (refusal) {
      case WriteRefusal.summaryChanged:
      case WriteRefusal.consentNotShown:
        setState(() {
          _previous = _shown;
          _shown = latest;
          _message = 'The numbers changed. Check them again before approving.';
        });
        break;
      case WriteRefusal.chainBehindRelay:
      case WriteRefusal.notSynced:
        setState(() {
          _needsSync = true;
          _message = 'This phone must sync before it can answer.';
        });
        break;
      default:
        setState(() => _message = refusalText(refusal));
    }
  }
}
