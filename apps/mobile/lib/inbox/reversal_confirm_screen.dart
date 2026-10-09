import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'approve_gate.dart';
import 'confirm_widgets.dart';
import 'consent_preview.dart';
import 'refusal_text.dart';

/// Shows a reversal's effect and lets the other partner approve or reject it
/// (spec section 5; spec 6.7 "Prior-period adjustments").
///
/// Same optimistic-check pattern as [WithdrawalConfirmScreen]: the numbers
/// shown are frozen until a real mismatch comes back from the writer.
class ReversalConfirmScreen extends StatefulWidget {
  const ReversalConfirmScreen({
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
  State<ReversalConfirmScreen> createState() => _ReversalConfirmScreenState();
}

class _ReversalConfirmScreenState extends State<ReversalConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  ReversalConsent? _shown;
  ReversalConsent? _previous;

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
      // Unlike a withdraw_request, a reversal can never be cancelled by its
      // own author: "a reversal of a reversal" is invalid in v1 (spec
      // section 5, `_reversibleTypes` in effective.dart), so the only way
      // this item leaves the inbox is a real answer.
      return Scaffold(
        appBar: AppBar(title: const Text('Reversal')),
        body: const Center(child: Text('This was already answered.')),
      );
    }
    final item = matches.single;

    _shown ??= reversalConsent(
      usable,
      partnershipKeys: keys,
      reversal: item.target,
      answer: previewApprove(
        ledger: usable,
        author: widget.myKey,
        partnership: widget.partnership,
        targetId: widget.targetId,
      ),
    );
    final summary = _shown;
    // The inbox never blocks a reversal (`approvalsInbox` always gives it
    // `blockedReason: null`), so only the summary and sync state can hide
    // Approve here.
    final showApprove = canShowApprove(
      summary: summary,
      blockedReason: item.blockedReason,
      needsSync: _needsSync,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Reversal')),
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

  List<Widget> _summaryRows(ReversalConsent now, ReversalConsent? previous) {
    final rows = <Widget>[
      InboxSummaryRow(
        label: 'Reversing',
        value: '${now.targetType} (${formatPaisa(now.targetAmount)})',
        changed:
            previous != null &&
            (previous.targetType != now.targetType ||
                previous.targetAmount != now.targetAmount),
      ),
    ];

    if (now.capitalChange != 0) {
      rows.add(
        InboxSummaryRow(
          label: 'Capital change',
          value: formatPaisa(now.capitalChange),
          changed: previous != null && previous.capitalChange != now.capitalChange,
        ),
      );
    }
    rows.add(
      InboxSummaryRow(
        label: 'Cash change',
        value: formatPaisa(now.cashChange),
        changed: previous != null && previous.cashChange != now.cashChange,
      ),
    );

    if (now.periodOpen == true) {
      rows.add(
        InboxSummaryRow(
          label: 'Result change (period ${now.periodIndex})',
          value: formatPaisa(now.resultChange ?? 0),
          changed: previous != null && previous.resultChange != now.resultChange,
        ),
      );
    } else if (now.periodOpen == false) {
      rows.add(
        const Padding(
          padding: EdgeInsets.only(top: 8, bottom: 4),
          child: Text(
            'That period is closed. The correction below is a '
            'prior-period adjustment, applied now (spec 6.7).',
          ),
        ),
      );
      final share = now.shareCorrection;
      if (share != null) {
        rows.add(
          InboxSummaryRow(
            label: 'Investor share correction',
            value: formatPaisa(share.investor),
            changed: previous?.shareCorrection?.investor != share.investor,
          ),
        );
        rows.add(
          InboxSummaryRow(
            label: 'Manager share correction',
            value: formatPaisa(share.manager),
            changed: previous?.shareCorrection?.manager != share.manager,
          ),
        );
      }
      rows.add(
        InboxSummaryRow(
          label: 'Deficit correction change',
          value: formatPaisa(now.deficitCorrectionChange ?? 0),
          changed:
              previous != null &&
              previous.deficitCorrectionChange != now.deficitCorrectionChange,
        ),
      );
    }

    if (now.targetType == 'expense' && now.freedBudgetAmount != null) {
      rows.add(
        InboxSummaryRow(
          label: 'Freed budget',
          value: formatPaisa(now.freedBudgetAmount!),
          changed:
              previous != null &&
              previous.freedBudgetAmount != now.freedBudgetAmount,
        ),
      );
    }

    return rows;
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
      shownReversal: shown,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!, latest: result.latestReversal);
  }

  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this reversal?'),
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

  void _handleRefusal(WriteRefusal refusal, {ReversalConsent? latest}) {
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
