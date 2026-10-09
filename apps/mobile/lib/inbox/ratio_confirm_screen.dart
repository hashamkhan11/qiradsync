import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'approve_gate.dart';
import 'confirm_widgets.dart';
import 'refusal_text.dart';

/// Shows a ratio change proposal's numbers and lets the other partner
/// approve or reject it (spec section 5, 6.6).
///
/// Same optimistic-check pattern as [BudgetConfirmScreen]: no candidate
/// answer is built, because approving only starts a new period at the next
/// settlement — it does not re-split any result by itself. [currentRatio] is
/// calculated from the records as they stand now, so it is exactly the
/// number the writer's optimistic check guards.
class RatioConfirmScreen extends StatefulWidget {
  const RatioConfirmScreen({
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
  State<RatioConfirmScreen> createState() => _RatioConfirmScreenState();
}

class _RatioConfirmScreenState extends State<RatioConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  RatioConsent? _shown;
  RatioConsent? _previous;

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
      // A ratio_proposal cannot be reversed (spec section 5: `_reversibleTypes`
      // does not include it), so it can never be cancelled by its own author.
      // The only way this item leaves the inbox is a real answer.
      return Scaffold(
        appBar: AppBar(title: const Text('Ratio change proposal')),
        body: const Center(child: Text('This was already answered.')),
      );
    }
    final item = matches.single;

    _shown ??= ratioConsent(usable, partnershipKeys: keys, proposal: item.target);
    final summary = _shown;
    // The inbox never blocks a ratio proposal (`approvalsInbox` always gives
    // it `blockedReason: null`), so only the summary and sync state can hide
    // Approve here.
    final showApprove = canShowApprove(
      summary: summary,
      blockedReason: item.blockedReason,
      needsSync: _needsSync,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Ratio change proposal')),
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

  List<Widget> _summaryRows(RatioConsent now, RatioConsent? previous) {
    return [
      InboxSummaryRow(
        label: 'Current ratio',
        value: _ratioText(now.currentRatio),
        changed:
            previous != null && previous.currentRatio != now.currentRatio,
      ),
      InboxSummaryRow(
        label: 'Proposed ratio',
        value: _ratioText(now.proposedRatio),
        changed:
            previous != null && previous.proposedRatio != now.proposedRatio,
      ),
      InboxSummaryRow(
        label: 'Starts',
        value: now.effectiveFrom,
        changed: previous != null && previous.effectiveFrom != now.effectiveFrom,
      ),
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          'This applies after the next settlement, not right away (spec '
          '6.6). The dashboard shows that a change is waiting until then.',
        ),
      ),
    ];
  }

  String _ratioText(Ratio ratio) => '${ratio.investor}/${ratio.manager}';

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
      shownRatio: shown,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!, latest: result.latestRatio);
  }

  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this ratio change?'),
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

  void _handleRefusal(WriteRefusal refusal, {RatioConsent? latest}) {
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
