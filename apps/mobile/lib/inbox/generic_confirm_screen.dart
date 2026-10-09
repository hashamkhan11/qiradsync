import 'package:flutter/material.dart';

import '../storage/record_writer.dart';
import 'refusal_text.dart';

/// A plain approve/reject screen for any inbox kind that has no dedicated
/// screen yet: currently ratio only. Settlement, withdrawal, reversal, budget
/// and partnership start already have their own screens, because spec 6.7
/// requires a consent summary first. This one stays as the fallback so a
/// kind is never silently unanswerable while its own screen is still being
/// built.
class GenericConfirmScreen extends StatefulWidget {
  const GenericConfirmScreen({
    super.key,
    required this.writer,
    required this.targetId,
    required this.title,
  });

  final RecordWriter writer;
  final String targetId;
  final String title;

  @override
  State<GenericConfirmScreen> createState() => _GenericConfirmScreenState();
}

class _GenericConfirmScreenState extends State<GenericConfirmScreen> {
  bool _writing = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  _message!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ),
            Row(
              children: [
                ElevatedButton(
                  onPressed: _writing ? null : _approve,
                  child: const Text('Approve'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: _writing ? null : _confirmReject,
                  child: const Text('Reject'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _approve() => _answer(true);

  // Reject always asks first, because it cannot be undone (records are
  // never edited or deleted, hard rule 2).
  Future<void> _confirmReject() async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reject this?'),
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
    if (sure == true) await _answer(false);
  }

  Future<void> _answer(bool approve) async {
    setState(() {
      _writing = true;
      _message = null;
    });
    final result = await widget.writer.answer(
      widget.targetId,
      approve: approve,
    );
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    setState(() => _message = refusalText(result.refusal!));
  }
}
