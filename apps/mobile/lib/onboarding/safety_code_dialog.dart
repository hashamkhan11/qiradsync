import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

/// Shows the safety code for this pair of keys, and asks the partner to check it.
///
/// Both phones compute the same code from the same two keys, in the same order
/// (investor, then manager; spec 2.1). Returns `true` only on "Codes match".
/// Cancel, the back button, or any other dismissal returns `false`, and the
/// caller must then save nothing. The pins are saved only after a `true`.
Future<bool> confirmSafetyCode(
  BuildContext context, {
  required String investorKey,
  required String managerKey,
}) async {
  final code = safetyCode(investorKey: investorKey, managerKey: managerKey);
  final confirmed = await showDialog<bool>(
    context: context,
    // A tap outside the dialog must not count as a match.
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      title: const Text('Check the safety code'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            "Read this code aloud to your partner, or compare it in person. "
            "Continue only if it matches the code on their phone.",
          ),
          const SizedBox(height: 16),
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Codes match'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
