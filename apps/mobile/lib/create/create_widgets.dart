import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../inbox/confirm_widgets.dart';
import '../inbox/refusal_text.dart';
import '../storage/record_writer.dart';

/// A rupee amount field for a creation form. Money never passes through a
/// `double` (hard rule 1): [controller]'s text is only ever read through
/// [parseRupeesToPaisa], never parsed as a number here.
class AmountField extends StatelessWidget {
  const AmountField({
    super.key,
    required this.controller,
    this.label = 'Amount (Rs)',
    this.invalid = false,
  });

  final TextEditingController controller;
  final String label;
  final bool invalid;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      decoration: InputDecoration(
        labelText: label,
        errorText: invalid ? 'Enter a valid amount' : null,
      ),
    );
  }
}

/// "What will be written" before a creation form's Save button does
/// anything — every form shows this instead of saving blind.
class CreatePreviewCard extends StatelessWidget {
  const CreatePreviewCard({super.key, required this.rows});

  final List<(String, String)> rows;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final (label, value) in rows)
              InboxSummaryRow(label: label, value: value),
          ],
        ),
      ),
    );
  }
}

/// Shared chrome for every creation form (spec section 5): the caller's own
/// fields and preview, plus one Save button that calls [propose], shows a
/// [WriteRefusal] as the same plain text the inbox uses
/// ([refusalText]) — or, for the two sync refusals, the same "Sync now"
/// banner the inbox uses — and pops the screen once the write is saved.
///
/// This is the one place a creation form's submit handling lives, so the
/// eight forms do not each repeat it.
class CreateScaffold extends StatefulWidget {
  const CreateScaffold({
    super.key,
    required this.title,
    required this.body,
    required this.canSave,
    required this.propose,
    required this.onSyncNow,
  });

  final String title;
  final Widget body;
  final bool canSave;
  final Future<WriteResult> Function() propose;
  final Future<void> Function() onSyncNow;

  @override
  State<CreateScaffold> createState() => _CreateScaffoldState();
}

class _CreateScaffoldState extends State<CreateScaffold> {
  bool _writing = false;
  bool _syncing = false;
  bool _needsSync = false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_needsSync)
            InboxSyncBanner(
              message: 'This phone must sync before it can propose this.',
              syncing: _syncing,
              onSyncNow: _sync,
            ),
          if (_message != null) ...[
            const SizedBox(height: 12),
            InboxBanner(_message!, emphasis: true),
          ],
          const SizedBox(height: 16),
          widget.body,
          const SizedBox(height: 24),
          FilledButton(
            onPressed: (_writing || !widget.canSave) ? null : _save,
            child: const Text('Save'),
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

  Future<void> _save() async {
    setState(() {
      _writing = true;
      _message = null;
    });
    final result = await widget.propose();
    if (!mounted) return;
    setState(() => _writing = false);
    if (result.record != null) {
      Navigator.of(context).pop(true);
      return;
    }
    final refusal = result.refusal!;
    switch (refusal) {
      case WriteRefusal.notSynced:
      case WriteRefusal.chainBehindRelay:
        setState(() => _needsSync = true);
        break;
      default:
        setState(() => _message = refusalText(refusal));
    }
  }
}
