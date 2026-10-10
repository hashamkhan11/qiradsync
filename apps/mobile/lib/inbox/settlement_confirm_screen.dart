import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'approve_gate.dart';
import 'confirm_widgets.dart';
import 'consent_preview.dart';
import 'refusal_text.dart';

/// Shows a settlement proposal's numbers and lets the investor approve or
/// reject it (spec 6.7). Only the investor answers a settlement.
///
/// The numbers shown are frozen once they are first read, so an approve
/// always matches what is on screen. If the ledger changes before the write
/// lands — a sync completes, a correction arrives — the writer refuses with
/// [WriteRefusal.summaryChanged] and this screen shows the new numbers,
/// highlighting what changed, and asks again.
class SettlementConfirmScreen extends StatefulWidget {
  const SettlementConfirmScreen({
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
  State<SettlementConfirmScreen> createState() =>
      _SettlementConfirmScreenState();
}

class _SettlementConfirmScreenState extends State<SettlementConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  // The summary the investor is looking at, and what the next Approve will be
  // checked against. It stays the same across rebuilds (for example after
  // Sync now) until a real mismatch comes back from the writer (spec 6.7).
  SettlementConsent? _shown;
  SettlementConsent? _previous;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
      return Scaffold(
        appBar: AppBar(title: const Text('Settlement')),
        body: const Center(child: Text('This was already answered.')),
      );
    }
    final item = matches.single;
    final blockedReason = item.blockedReason;

    _shown ??= settlementConsent(
      usable,
      partnershipKeys: keys,
      proposal: item.target,
      answer: previewApprove(
        ledger: usable,
        author: widget.myKey,
        partnership: widget.partnership,
        targetId: widget.targetId,
      ),
    );
    final summary = _shown;

    // Both of these blocked reasons can never become approvable; reject is
    // the only sensible answer (spec 6.7, approvals_inbox.dart). They only
    // affect how the block is *shown* (styling); whether Approve shows at
    // all is decided in one shared place, `canShowApprove`.
    final mustReject =
        blockedReason != null && blockedReason.endsWith('Reject it.');
    final mustSync = blockedReason == 'Waiting for records to sync.';
    final showApprove = canShowApprove(
      summary: summary,
      blockedReason: blockedReason,
      needsSync: _needsSync,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Settlement')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (mustSync || _needsSync)
            InboxSyncBanner(
              message:
                  blockedReason ?? 'This phone must sync before it can answer.',
              syncing: _syncing,
              onSyncNow: _sync,
            )
          else if (blockedReason != null)
            InboxBanner(blockedReason, emphasis: mustReject),
          if (_message != null) ...[
            const SizedBox(height: 12),
            InboxBanner(_message!, emphasis: true),
          ],
          const SizedBox(height: 16),
          if (summary != null)
            ..._summaryRows(summary, _previous)
          else if (!mustReject && !mustSync && !_needsSync)
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
              mustReject
                  ? FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: theme.colorScheme.error,
                        foregroundColor: theme.colorScheme.onError,
                      ),
                      onPressed: _writing ? null : _confirmReject,
                      child: const Text('Reject'),
                    )
                  : OutlinedButton(
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
    SettlementConsent now,
    SettlementConsent? previous,
  ) {
    return [
      InboxSummaryRow(
        label: 'Period',
        value: '${now.periodIndex}',
        changed: previous != null && previous.periodIndex != now.periodIndex,
      ),
      InboxSummaryRow(
        label: 'Period result',
        value: formatPaisa(now.result),
        changed: previous != null && previous.result != now.result,
      ),
      InboxSummaryRow(
        label: 'Investor share',
        value: formatPaisa(now.shares.investor),
        changed:
            previous != null && previous.shares.investor != now.shares.investor,
      ),
      InboxSummaryRow(
        label: 'Manager share',
        value: formatPaisa(now.shares.manager),
        changed:
            previous != null && previous.shares.manager != now.shares.manager,
      ),
      InboxSummaryRow(
        label: 'Ratio',
        value: '${now.ratio.investor}/${now.ratio.manager}',
        changed: previous != null && previous.ratio != now.ratio,
      ),
      if (now.ratioChanged)
        const Padding(
          padding: EdgeInsets.only(top: 8),
          child: Text(
            'This period splits profit at a different ratio from the one '
            'before it.',
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
      shownSettlement: shown,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!, latest: result.latestSettlement);
  }

  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this settlement?'),
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

  void _handleRefusal(WriteRefusal refusal, {SettlementConsent? latest}) {
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
