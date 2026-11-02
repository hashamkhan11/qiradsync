import 'package:flutter/material.dart';

import '../theme/ledger_widgets.dart';
import '../theme/qirad_theme.dart';

/// A short message. [emphasis] (an error worth interrupting for, e.g. "the
/// only sensible answer is Reject") gets the same filled warning treatment
/// as every other interrupt-worthy banner in the app; anything else is a
/// plain bordered note, not a card, so it never reads as a problem.
class InboxBanner extends StatelessWidget {
  const InboxBanner(this.text, {super.key, this.emphasis = false});

  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    if (emphasis) return LedgerWarningCard(message: text);
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        border: Border.all(color: theme.colorScheme.outline),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Text(
        text,
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// A message with a "Sync now" button (spec 7.4): shown whenever an answer
/// is blocked, or was refused, because this phone cannot yet show, or
/// cannot yet write, a record it trusts as complete.
class InboxSyncBanner extends StatelessWidget {
  const InboxSyncBanner({
    super.key,
    required this.message,
    required this.syncing,
    required this.onSyncNow,
  });

  final String message;
  final bool syncing;
  final VoidCallback onSyncNow;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(
                  color: theme.colorScheme.onErrorContainer,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: syncing ? null : onSyncNow,
              child: Text(syncing ? 'Syncing…' : 'Sync now'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One labelled figure in a consent summary. Tabular, like every other
/// amount in the app (hard rule 1), and in the error colour when [changed]
/// is true, so the partner sees exactly which figure the writer disagreed
/// with (spec 6.7, summaryChanged).
class InboxSummaryRow extends StatelessWidget {
  const InboxSummaryRow({
    super.key,
    required this.label,
    required this.value,
    this.changed = false,
  });

  final String label;
  final String value;
  final bool changed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = qiradFigureStyle(context, weight: FontWeight.w600)
        .copyWith(color: changed ? theme.colorScheme.error : null);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
          const SizedBox(width: 12),
          Text(value, style: valueStyle),
        ],
      ),
    );
  }
}
