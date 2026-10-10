import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../create/new_menu_screen.dart';
import '../inbox/inbox_screen.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'format.dart';

/// The home screen for one partnership: the money totals and each partner's
/// share of the result (spec 6.5, 6.6).
///
/// Every number comes from `buildDashboard` on the usable records. The screen
/// only formats them, so no maths lives in the widget. The inbox badge count
/// is likewise read fresh from `approvalsInbox` on every build, so it never
/// needs its own stored state here — only a rebuild from above after a sync
/// or a write (spec 7.3).
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.store,
    required this.partnership,
    required this.myKey,
    required this.writer,
    required this.syncing,
    required this.onSyncNow,
  });

  final RecordStore store;
  final String partnership;
  final String myKey;
  final RecordWriter writer;
  final bool syncing;
  final Future<void> Function() onSyncNow;

  @override
  Widget build(BuildContext context) {
    final validator = store.validatorFor(partnership);
    final usable = validator.usableRecords;
    final keys = validator.partnershipKeys!;
    final inboxCount = approvalsInbox(
      usable,
      partnershipKeys: keys,
      myKey: myKey,
    ).length;
    // No clock here: the ratio comes from the records alone (hard rule 3).
    final dashboard = buildDashboard(usable, partnershipKeys: keys);
    final ratio = dashboard.ratio;
    final money = dashboard.money;
    final shares = dashboard.shares;
    final parties = proposedParties(usable);
    final withdrawn = totalProfitWithdrawn(usable, partnershipKeys: keys);
    final periods = periodShares(usable, partnershipKeys: keys);
    final integrityMessages = _integrityMessages(validator, parties);
    // Spec 6.7: "owed back" only counts closed periods, so before the first
    // settlement there is nothing settled to compare withdrawals against.
    final beforeFirstSettlement = periods.every((p) => p.open);
    final openPeriod = periods.isEmpty ? null : periods.last;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Dashboard'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New',
            // Before the create exists, proposedParties is null and there
            // is no role to offer a menu for yet (spec section 5).
            onPressed: parties == null
                ? null
                : () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => NewMenuScreen(
                        store: store,
                        writer: writer,
                        myKey: myKey,
                        partnership: partnership,
                        onSyncNow: onSyncNow,
                      ),
                    ),
                  ),
          ),
          IconButton(
            icon: syncing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.sync),
            tooltip: 'Sync now',
            // Sync trigger: the manual button (spec 7.3). The other two
            // triggers (app open, after a write) live above this screen.
            onPressed: syncing ? null : onSyncNow,
          ),
          IconButton(
            icon: Badge(
              label: Text('$inboxCount'),
              isLabelVisible: inboxCount > 0,
              child: const Icon(Icons.inbox),
            ),
            tooltip: 'Inbox',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => InboxScreen(
                  store: store,
                  writer: writer,
                  myKey: myKey,
                  partnership: partnership,
                  onSyncNow: onSyncNow,
                ),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          for (final message in integrityMessages) ...[
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  message,
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          _Figure(label: 'Capital', value: formatPaisa(money.capital)),
          _Figure(label: 'Cash balance', value: formatPaisa(money.cashBalance)),
          _Figure(label: 'Result', value: formatPaisa(money.result)),
          const Divider(height: 32),
          Text('Shares of the result', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (shares == null || ratio == null)
            Text(_statusMessage(dashboard.partnershipStatus))
          else ...[
            _Figure(
              label: 'Investor (${ratio.ratio.investor}%)',
              value: formatPaisa(shares.investor),
            ),
            _Figure(
              label: 'Manager (${ratio.ratio.manager}%)',
              value: formatPaisa(shares.manager),
            ),
          ],
          const SizedBox(height: 16),
          if (ratio != null) Text('Ratio: ${formatRatio(ratio)}'),
          if (dashboard.ratioChanged) ...[
            const SizedBox(height: 16),
            Card(
              color: theme.colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  'An effective ratio change exists. This split uses the latest '
                  'ratio for all the result, so it may not match the contract '
                  'until settlement is built.',
                  style: TextStyle(color: theme.colorScheme.onErrorContainer),
                ),
              ),
            ),
          ],
          // Both sections below need a genuinely active partnership, not just
          // a well-formed create: `proposedParties` reads the create's body
          // alone, with no approval check, so it is non-null even before the
          // manager approves. `ratio` already carries that approval check (it
          // comes from `activeRatio`, spec 6.6), so it is the right guard here too.
          if (ratio != null && parties != null) ...[
            const Divider(height: 32),
            Text('Profit withdrawn', style: theme.textTheme.titleMedium),
            if (beforeFirstSettlement) ...[
              const SizedBox(height: 4),
              Text(
                'Not yet compared to settled profit.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            _Figure(
              label: 'Investor',
              value: formatPaisa(withdrawn[parties.investor] ?? 0),
            ),
            _Figure(
              label: 'Manager',
              value: formatPaisa(withdrawn[parties.manager] ?? 0),
            ),
          ],
          if (ratio != null && openPeriod != null) ...[
            const Divider(height: 32),
            Row(
              children: [
                Text('Open period', style: theme.textTheme.titleMedium),
                const SizedBox(width: 8),
                Text(
                  '(provisional)',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.error,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _Figure(label: 'Result', value: formatPaisa(openPeriod.result)),
            _Figure(
              label: 'Investor share',
              value: formatPaisa(openPeriod.shares.investor),
            ),
            _Figure(
              label: 'Manager share',
              value: formatPaisa(openPeriod.shares.manager),
            ),
          ],
        ],
      ),
    );
  }
}

/// What to say when there is no active ratio yet (spec section 5): waiting,
/// declined, or (defensively) something else gone wrong with the create.
String _statusMessage(DecisionStatus? status) {
  switch (status) {
    case DecisionStatus.dead:
      return 'The manager declined this partnership.';
    case DecisionStatus.pending:
    case null:
      return 'Waiting for the manager to approve the partnership.';
    case DecisionStatus.active:
      return 'No active ratio yet. The manager must approve the start.';
  }
}

/// Factual, neutral messages about chain problems this phone has found
/// (spec 6.1 steps 4-5). Equivocation and a wrong `prevHash` can come from
/// a bug or a broken device, not only bad intent, so these only state what
/// was found and what to do — they never accuse.
List<String> _integrityMessages(Validator validator, Parties? parties) {
  final messages = <String>[];
  final allRecords = {for (final r in validator.ledger.records) r.id: r};

  // Sorted so the banner's order does not depend on map iteration order,
  // which Dart does not guarantee (hard rule: deterministic, no clock).
  final equivocating = validator.equivocatingFromSeq.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  for (final entry in equivocating) {
    final label = _partnerLabel(entry.key, parties);
    messages.add(
      "Two different versions of $label's record #${entry.value} were "
      'found. Their records from that point are not counted. '
      'Please talk to your partner.',
    );
  }

  final chainInvalid = validator.chainInvalidIds.toList()..sort();
  for (final id in chainInvalid) {
    final record = allRecords[id];
    if (record == null) continue;
    final label = _partnerLabel(record.author, parties);
    messages.add(
      'A record from $label (#${record.seq}) does not fit after their '
      'earlier record, so it is not counted. Please talk to your partner.',
    );
  }

  return messages;
}

/// Names the author of a flagged record, for the integrity banner above.
/// Falls back to "a partner" before the create names who is who.
String _partnerLabel(String key, Parties? parties) {
  if (parties != null && key == parties.investor) return 'the investor';
  if (parties != null && key == parties.manager) return 'the manager';
  return 'a partner';
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}
