import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes `expense`: spends from one of this key's own effective budgets
/// (spec section 5, 6.4). Manager only — the "New" menu only offers this to
/// the manager, but [RecordWriter.proposeExpense] refuses it for anyone else
/// anyway. The budget picker only ever lists [effectiveBudgetsFor] this key,
/// the same list `proposeExpense` checks against, so a budget this form
/// never showed can never be chosen.
class ExpenseForm extends StatefulWidget {
  const ExpenseForm({
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
  State<ExpenseForm> createState() => _ExpenseFormState();
}

class _ExpenseFormState extends State<ExpenseForm> {
  final _amount = TextEditingController();
  String? _budgetId;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validator = widget.store.validatorFor(widget.partnership);
    final budgets = effectiveBudgetsFor(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
      grantee: widget.myKey,
    );
    final paisa = parseRupeesToPaisa(_amount.text);
    _budgetId ??= budgets.isEmpty ? null : budgets.keys.first;
    final budgetId = _budgetId;
    final left = budgetId == null ? null : budgets[budgetId];

    if (budgets.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('Record an expense')),
        body: const Center(
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'No approved budget is granted to you yet. Propose or wait '
              'for a budget first.',
            ),
          ),
        ),
      );
    }

    return CreateScaffold(
      title: 'Record an expense',
      canSave: paisa != null && budgetId != null,
      onSyncNow: widget.onSyncNow,
      propose: () =>
          widget.writer.proposeExpense(amount: paisa!, budgetId: budgetId!),
      body: Column(
        children: [
          DropdownButtonFormField<String>(
            initialValue: budgetId,
            decoration: const InputDecoration(labelText: 'From budget'),
            items: [
              for (final entry in budgets.entries)
                DropdownMenuItem(
                  value: entry.key,
                  child: Text('${formatPaisa(entry.value)} left'),
                ),
            ],
            onChanged: (value) => setState(() => _budgetId = value),
          ),
          const SizedBox(height: 16),
          AmountField(
            controller: _amount,
            invalid: _amount.text.isNotEmpty && paisa == null,
          ),
          const SizedBox(height: 16),
          CreatePreviewCard(
            rows: [
              ('Spends', paisa == null ? '—' : formatPaisa(paisa)),
              if (left != null) ('Budget left before this', formatPaisa(left)),
              if (left != null && paisa != null)
                ('Budget left after this', formatPaisa(left - paisa)),
            ],
          ),
        ],
      ),
    );
  }
}
