import 'package:flutter/material.dart';

/// A short message. Shown in the error colour when [emphasis] is true, for
/// example when the only sensible answer is Reject.
class InboxBanner extends StatelessWidget {
  const InboxBanner(this.text, {super.key, this.emphasis = false});

  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: emphasis
          ? theme.colorScheme.errorContainer
          : theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          text,
          style: TextStyle(
            color: emphasis
                ? theme.colorScheme.onErrorContainer
                : theme.colorScheme.onSurfaceVariant,
          ),
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
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
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

/// One labelled number in a consent summary. Bold and in the error colour
/// when [changed] is true, so the partner sees exactly which figure the
/// writer disagreed with (spec 6.7, summaryChanged).
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
    final style = TextStyle(
      fontWeight: FontWeight.w600,
      color: changed ? Theme.of(context).colorScheme.error : null,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: style),
        ],
      ),
    );
  }
}
