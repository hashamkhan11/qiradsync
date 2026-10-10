import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

const _reversibleTypes = {'invest', 'sale', 'expense', 'withdraw_request'};

/// Proposes a `reversal` of a chosen record (spec section 5). Either
/// partner may propose this. The target picker only ever lists the types
/// spec section 5 allows to be reversed, the same list
/// [RecordWriter.proposeReversal] checks against, so a record this form
/// never showed can never be chosen.
class ReversalForm extends StatefulWidget {
  const ReversalForm({
    super.key,
    required this.store,
    required this.writer,
    required this.myKey,
    required this.partnership,
    required this.onSyncNow,
  });

  final RecordStore store;
  final RecordWriter writer;
  final String myKey;
  final String partnership;
  final Future<void> Function() onSyncNow;

  @override
  State<ReversalForm> createState() => _ReversalFormState();
}

class _ReversalFormState extends State<ReversalForm> {
  String? _targetId;

  @override
  Widget build(BuildContext context) {
    final validator = widget.store.validatorFor(widget.partnership);
    final targets = validator.usableRecords
        .where((r) => _reversibleTypes.contains(r.type))
        .toList();
    _targetId ??= targets.isEmpty ? null : targets.first.id;
    final targetId = _targetId;
    final target = targets.where((r) => r.id == targetId).firstOrNull;

    if (targets.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Reverse a record')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text('Nothing on this phone can be reversed yet.'),
          ),
        ),
      );
    }

    return CreateScaffold(
      title: 'Reverse a record',
      canSave: targetId != null,
      onSyncNow: widget.onSyncNow,
      propose: () => widget.writer.proposeReversal(targetId: targetId!),
      body: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: targetId,
            decoration: const InputDecoration(labelText: 'Record to reverse'),
            items: [
              for (final record in targets)
                DropdownMenuItem(
                  value: record.id,
                  child: Text(_describe(record)),
                ),
            ],
            onChanged: (value) => setState(() => _targetId = value),
          ),
          const SizedBox(height: 16),
          if (target != null)
            CreatePreviewCard(
              rows: [('Reverses', _describe(target))],
            ),
        ],
      ),
    );
  }

  String _describe(Record record) {
    final amount = record.body['amount'];
    final amountText = amount is int ? formatPaisa(amount) : '';
    final by = record.author == widget.myKey ? 'you' : 'the other partner';
    return '${record.type} $amountText by $by';
  }
}

extension on Iterable<Record> {
  Record? get firstOrNull => isEmpty ? null : first;
}
