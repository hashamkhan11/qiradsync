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
    // No clock here: the ratio comes from the records alone (hard rule 3).
    final dashboard = buildDashboard(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
    );
    final ratio = dashboard.ratio;
    final money = dashboard.money;
    final shares = dashboard.shares;
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
