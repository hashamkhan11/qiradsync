import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes `budget_proposal`: a spending limit for one partner (spec
/// section 5, 6.4). Either partner may propose a budget for either partner —
/// the grantee choice here only decides who the budget is *for*; whether
/// that key may later *spend* it is [RecordWriter.proposeExpense]'s rule, not
/// this form's.
class BudgetForm extends StatefulWidget {
  const BudgetForm({
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
  State<BudgetForm> createState() => _BudgetFormState();
}

class _BudgetFormState extends State<BudgetForm> {
  final _amount = TextEditingController();
  String? _grantee;

  @override
  void initState() {
    super.initState();
    _amount.addListener(() => setState(() {}));
    _grantee = widget.myKey;
  }

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final validator = widget.store.validatorFor(widget.partnership);
    final parties = proposedParties(validator.usableRecords)!;
    final paisa = parseRupeesToPaisa(_amount.text);
    final grantee = _grantee!;

    return CreateScaffold(
      title: 'Propose a budget',
      canSave: paisa != null,
      onSyncNow: widget.onSyncNow,
      propose: () =>
          widget.writer.proposeBudget(amount: paisa!, grantee: grantee),
      body: Column(
        children: [
          RadioGroup<String>(
            groupValue: grantee,
            onChanged: (value) => setState(() => _grantee = value),
            child: Column(
              children: [
                RadioListTile<String>(
                  title: const Text('For me'),
                  value: widget.myKey,
                ),
                RadioListTile<String>(
                  title: const Text('For the other partner'),
                  value: parties.investor == widget.myKey
                      ? parties.manager
                      : parties.investor,
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          AmountField(
            controller: _amount,
            invalid: _amount.text.isNotEmpty && paisa == null,
          ),
          const SizedBox(height: 16),
          CreatePreviewCard(
            rows: [
              ('For', grantee == widget.myKey ? 'You' : grantee),
              ('Budget amount', paisa == null ? '—' : formatPaisa(paisa)),
            ],
          ),
        ],
      ),
    );
  }
}
