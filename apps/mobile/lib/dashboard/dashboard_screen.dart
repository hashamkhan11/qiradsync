import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../create/new_menu_screen.dart';
import '../inbox/inbox_screen.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import '../theme/ledger_widgets.dart';
import '../transactions/transactions_screen.dart';
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
    required this.lastSyncSucceeded,
    required this.relayVector,
  });

  final RecordStore store;
  final String partnership;
  final String myKey;
  final RecordWriter writer;
  final bool syncing;
  final Future<void> Function() onSyncNow;

  /// Whether the most recent sync attempt in this session reached a
  /// complete result (spec 7.3, 7.4 rule 2).
  final bool lastSyncSucceeded;

  /// The relay's vector as of the last sync reply, or `null` before this
  /// session's first one.
  final Map<String, int>? relayVector;

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
    // "Synced" needs both: this session's own last attempt must have
    // completed, and this phone's own chain must still match what that
    // attempt last saw from the relay (spec 7.4 rule 2) — the same
    // comparison the write gate uses, so the badge never promises a write
    // the gate would then refuse.
    final localTop = validator.ledger.versionVector()[myKey] ?? 0;
    final synced =
        lastSyncSucceeded &&
        store.isCaughtUpWithRelay(
          relayVector: relayVector,
          me: myKey,
          localTop: localTop,
        );
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
            icon: Icon(Icons.add, color: theme.colorScheme.primary),
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
          IconButton(
            icon: const Icon(Icons.receipt_long),
            tooltip: 'Transactions',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) =>
                    TransactionsScreen(store: store, partnership: partnership),
              ),
            ),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.circle,
                size: 6,
                color: synced ? theme.colorScheme.primary : theme.colorScheme.error,
              ),
              const SizedBox(width: 7),
              Text(
                synced ? 'Synced' : 'Not synced',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: synced ? theme.colorScheme.primary : theme.colorScheme.error,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          for (final message in integrityMessages) ...[
            LedgerWarningCard(message: message),
            const SizedBox(height: 12),
          ],
          const LedgerSectionLabel('Position'),
          LedgerFigureRow(label: 'Capital', value: formatPaisa(money.capital)),
          LedgerFigureRow(
            label: 'Cash balance',
            value: formatPaisa(money.cashBalance),
          ),
          LedgerFigureRow(label: 'Result', value: formatPaisa(money.result)),
          Divider(height: 32, color: theme.colorScheme.outline),
          const LedgerSectionLabel('Shares of the result'),
          if (shares == null || ratio == null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _statusMessage(dashboard.partnershipStatus),
                style: theme.textTheme.bodyMedium,
              ),
            )
          else ...[
            LedgerFigureRow(
              label: 'Investor (${ratio.ratio.investor}%)',
              value: formatPaisa(shares.investor),
            ),
            LedgerFigureRow(
              label: 'Manager (${ratio.ratio.manager}%)',
              value: formatPaisa(shares.manager),
            ),
          ],
          if (ratio != null) ...[
            const SizedBox(height: 4),
            Text('Ratio: ${formatRatio(ratio)}', style: theme.textTheme.bodySmall),
          ],
          if (dashboard.ratioChanged) ...[
            const SizedBox(height: 16),
            const LedgerWarningCard(
              message:
                  'An effective ratio change exists. This split uses the latest '
                  'ratio for all the result, so it may not match the contract '
                  'until settlement is built.',
            ),
          ],
          // Both sections below need a genuinely active partnership, not just
          // a well-formed create: `proposedParties` reads the create's body
          // alone, with no approval check, so it is non-null even before the
          // manager approves. `ratio` already carries that approval check (it
          // comes from `activeRatio`, spec 6.6), so it is the right guard here too.
          if (ratio != null && parties != null) ...[
            Divider(height: 32, color: theme.colorScheme.outline),
            const LedgerSectionLabel('Profit withdrawn'),
            LedgerFigureRow(
              label: 'Investor',
              value: formatPaisa(withdrawn[parties.investor] ?? 0),
              caption: beforeFirstSettlement
                  ? 'Not yet compared to settled profit.'
                  : null,
            ),
            LedgerFigureRow(
              label: 'Manager',
              value: formatPaisa(withdrawn[parties.manager] ?? 0),
            ),
          ],
          if (ratio != null && openPeriod != null) ...[
            Divider(height: 32, color: theme.colorScheme.outline),
            LedgerSectionLabel(
              'Open period',
              tag: const StatusTag(label: 'Provisional', tone: StatusTone.wait),
            ),
            LedgerFigureRow(label: 'Result', value: formatPaisa(openPeriod.result)),
            LedgerFigureRow(
              label: 'Investor share',
              value: formatPaisa(openPeriod.shares.investor),
            ),
            LedgerFigureRow(
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
  switch (partnerRole(key, parties)) {
    case 'investor':
      return 'the investor';
    case 'manager':
      return 'the manager';
    default:
      return 'a partner';
  }
}
