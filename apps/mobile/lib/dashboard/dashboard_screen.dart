import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import 'format.dart';

/// The home screen for one partnership: the money totals and each partner's
/// share of the result (spec 6.5, 6.6).
///
/// Every number comes from `buildDashboard` on the usable records. The screen
/// only formats them, so no maths lives in the widget.
class DashboardScreen extends StatelessWidget {
  const DashboardScreen({
    super.key,
    required this.store,
    required this.partnership,
  });

  final RecordStore store;
  final String partnership;

  @override
  Widget build(BuildContext context) {
    final validator = store.validatorFor(partnership);
    final usable = validator.usableRecords;
    final keys = validator.partnershipKeys!;
    // No clock here: the ratio comes from the records alone (hard rule 3).
    final dashboard = buildDashboard(usable, partnershipKeys: keys);
    final ratio = dashboard.ratio;
    final money = dashboard.money;
    final shares = dashboard.shares;
    final parties = partiesOf(usable);
    final withdrawn = totalProfitWithdrawn(usable, partnershipKeys: keys);
    final periods = periodShares(usable, partnershipKeys: keys);
    // Spec 6.7: "owed back" only counts closed periods, so before the first
    // settlement there is nothing settled to compare withdrawals against.
    final beforeFirstSettlement = periods.every((p) => p.open);
    final openPeriod = periods.isEmpty ? null : periods.last;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Dashboard')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Figure(label: 'Capital', value: formatPaisa(money.capital)),
          _Figure(label: 'Cash balance', value: formatPaisa(money.cashBalance)),
          _Figure(label: 'Result', value: formatPaisa(money.result)),
          const Divider(height: 32),
          Text('Shares of the result', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (shares == null || ratio == null)
            const Text(
              'No active ratio yet. The manager must approve the start.',
            )
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
          // a well-formed create: `partiesOf` reads the create's body alone,
          // with no approval check, so it is non-null even before the manager
          // approves. `ratio` already carries that approval check (it comes
          // from `activeRatio`, spec 6.6), so it is the right guard here too.
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
