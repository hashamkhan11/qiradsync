import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'confirm_widgets.dart';
import 'consent_preview.dart';
import 'refusal_text.dart';

/// Shows a withdrawal request's numbers and lets the other partner approve
/// or reject it (spec 6.7).
///
/// Same optimistic-check pattern as [SettlementConfirmScreen]: the numbers
/// shown are frozen until a real mismatch comes back from the writer.
class WithdrawalConfirmScreen extends StatefulWidget {
  const WithdrawalConfirmScreen({
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
  State<WithdrawalConfirmScreen> createState() =>
      _WithdrawalConfirmScreenState();
}

class _WithdrawalConfirmScreenState extends State<WithdrawalConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  WithdrawalConsent? _shown;
  WithdrawalConsent? _previous;

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
      // Two different reasons land here. A request the requester cancelled
      // with their own reversal (spec section 5) is gone from the inbox the
      // same way an answered one is, but it was never decided — the other
      // partner should be told it was withdrawn, not that they answered it.
      final cancelled = computeEffective(
        usable,
        partnershipKeys: keys,
      ).cancelledIds.contains(widget.targetId);
      return Scaffold(
        appBar: AppBar(title: const Text('Withdrawal')),
        body: Center(
          child: Text(
            cancelled
                ? 'This request was cancelled by the requester.'
                : 'This was already answered.',
          ),
        ),
      );
    }
    final item = matches.single;

    _shown ??= withdrawalConsent(
      usable,
      partnershipKeys: keys,
      request: item.target,
      answer: previewApprove(
        ledger: usable,
        author: widget.myKey,
        partnership: widget.partnership,
        targetId: widget.targetId,
      ),
    );
    final summary = _shown;
    final showApprove = !_needsSync && summary != null;

    return Scaffold(
      appBar: AppBar(title: const Text('Withdrawal')),
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

  List<Widget> _summaryRows(
    WithdrawalConsent now,
    WithdrawalConsent? previous,
  ) {
    return [
      InboxSummaryRow(
        label: 'Amount requested',
        value: '${formatPaisa(now.amount)} (${now.kind})',
        changed:
            previous != null &&
            (previous.amount != now.amount || previous.kind != now.kind),
      ),
      InboxSummaryRow(
        label: 'Settled share so far',
        value: formatPaisa(now.settledShare),
        changed: previous != null && previous.settledShare != now.settledShare,
      ),
      InboxSummaryRow(
        label: 'Profit withdrawn after this',
        value: formatPaisa(now.totalProfitWithdrawn),
        changed:
            previous != null &&
            previous.totalProfitWithdrawn != now.totalProfitWithdrawn,
      ),
      InboxSummaryRow(
        label: 'Ahead of settled profit',
        value: formatPaisa(now.aheadOfSettled),
        changed:
            previous != null && previous.aheadOfSettled != now.aheadOfSettled,
      ),
      InboxSummaryRow(
        label: 'Owed back',
        value: formatPaisa(now.owedBack),
        changed: previous != null && previous.owedBack != now.owedBack,
      ),
      if (now.hasOwedBack)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'A correction reduced a settled share. Some money already '
            'withdrawn is owed back.',
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
      shownWithdrawal: shown,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!, latest: result.latestWithdrawal);
  }

  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this withdrawal?'),
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

  void _handleRefusal(WriteRefusal refusal, {WithdrawalConsent? latest}) {
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
