import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'approve_gate.dart';
import 'confirm_widgets.dart';
import 'refusal_text.dart';

/// Shows the new partnership's own fixed content and lets the manager
/// approve or reject it (spec section 2.1, section 5).
///
/// This kind is exempt from the writer's optimistic check (docs/decisions.md):
/// everything shown here is the record's own body, not a calculation, so it
/// cannot go stale between this screen and the write the way a period result
/// or an active ratio can. The one thing that still needs a human check is
/// the safety code, so a required checkbox stands in for that step instead —
/// Approve stays disabled until it is ticked, and ticking it proves nothing
/// to the writer, only to the person reading the screen.
class PartnershipCreateConfirmScreen extends StatefulWidget {
  const PartnershipCreateConfirmScreen({
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
  State<PartnershipCreateConfirmScreen> createState() =>
      _PartnershipCreateConfirmScreenState();
}

class _PartnershipCreateConfirmScreenState
    extends State<PartnershipCreateConfirmScreen> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  bool _codeChecked = false;
  String? _message;

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
      return Scaffold(
        appBar: AppBar(title: const Text('Start of the partnership')),
        body: const Center(child: Text('This was already answered.')),
      );
    }
    final item = matches.single;
    final target = item.target;

    final rawInvestor = target.body['investor'];
    final rawManager = target.body['manager'];
    final investorKey = rawInvestor is String ? rawInvestor : null;
    final managerKey = rawManager is String ? rawManager : null;
    final ratio = ratioOf(target);

    // Unreachable in practice, and unlike the withdrawal screen's defensive
    // case, not even buildable as a hand-built test fixture: the schema step
    // refuses a non-canonical investor/manager key before the record is ever
    // accepted, and `partnershipKeys` (needed for this item to exist in the
    // inbox at all) is only set by that same acceptance. No accepted create
    // can carry a bad key, so this only guards a record built by a future,
    // broken version of this check — the same class of defence-in-depth as
    // the settlement screen's missing-summary case (2026-10-09 learning log).
    String? code;
    if (investorKey != null && managerKey != null) {
      try {
        code = safetyCode(investorKey: investorKey, managerKey: managerKey);
      } on ArgumentError {
        code = null;
      }
    }
    final ready =
        investorKey != null && managerKey != null && ratio != null && code != null;

    final showApprove = canShowApprove(
      summary: ready ? ratio : null,
      blockedReason: item.blockedReason,
      needsSync: _needsSync,
    );

    return Scaffold(
      appBar: AppBar(title: const Text('Start of the partnership')),
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
          if (ready) ...[
            InboxSummaryRow(label: 'Investor', value: investorKey),
            InboxSummaryRow(label: 'Manager', value: managerKey),
            InboxSummaryRow(
              label: 'Investor share',
              value: '${ratio.investor}% (manager ${ratio.manager}%)',
            ),
            const SizedBox(height: 16),
            const Text(
              'Read this code aloud to your partner, or compare it in '
              'person. Tick the box only if it matches the code on their '
              'phone.',
            ),
            const SizedBox(height: 8),
            Center(
              child: SelectableText(
                code,
                key: const Key('safety-code'),
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  fontFamily: 'monospace',
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('code-matches-checkbox'),
              value: _codeChecked,
              onChanged: _writing
                  ? null
                  : (value) => setState(() => _codeChecked = value ?? false),
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text(
                'I compared this code with my partner and it matches.',
              ),
            ),
          ] else if (!_needsSync)
            const Text('No numbers to show yet.'),
          const SizedBox(height: 24),
          Row(
            children: [
              if (showApprove) ...[
                ElevatedButton(
                  onPressed: (_writing || !_codeChecked) ? null : _approve,
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
    setState(() {
      _writing = true;
      _message = null;
    });
    final result = await widget.writer.answer(widget.targetId, approve: true);
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!);
  }

  // Reject always asks first, because it cannot be undone (records are never
  // edited or deleted, hard rule 2).
  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this partnership?'),
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
    final result = await widget.writer.answer(
      widget.targetId,
      approve: false,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    _handleRefusal(result.refusal!);
  }

  void _handleRefusal(WriteRefusal refusal) {
    switch (refusal) {
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
