import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'budget_form.dart';
import 'expense_form.dart';
import 'invest_form.dart';
import 'ratio_form.dart';
import 'reversal_form.dart';
import 'sale_form.dart';
import 'settlement_form.dart';
import 'withdrawal_form.dart';

/// The "New" menu: one button per record type this key may propose right
/// now (spec section 5). The list of buttons comes from
/// [allowedCreationActions] alone — the one function the validator and every
/// `RecordWriter.propose*` method also call — so this menu can never offer
/// an action that a propose call would just refuse for having the wrong
/// role.
class NewMenuScreen extends StatelessWidget {
  const NewMenuScreen({
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
  Widget build(BuildContext context) {
    final validator = store.validatorFor(partnership);
    final parties = proposedParties(validator.usableRecords)!;
    final allowed = allowedCreationActions(myKey, parties);

    return Scaffold(
      appBar: AppBar(title: const Text('New')),
      body: ListView(
        children: [
          for (final action in CreationAction.values)
            if (allowed.contains(action))
              ListTile(
                title: Text(_titleFor(action)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => _formFor(action)),
                ),
              ),
        ],
      ),
    );
  }

  String _titleFor(CreationAction action) => switch (action) {
    CreationAction.invest => 'Invest capital',
    CreationAction.sale => 'Record a sale',
    CreationAction.expense => 'Record an expense',
    CreationAction.withdrawCapital => 'Withdraw capital',
    CreationAction.withdrawProfit => 'Withdraw profit',
    CreationAction.budget => 'Propose a budget',
    CreationAction.ratio => 'Propose a new ratio',
    CreationAction.reversal => 'Reverse a record',
    CreationAction.settlement => 'Settle the open period',
  };

  Widget _formFor(CreationAction action) => switch (action) {
    CreationAction.invest => InvestForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.sale => SaleForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.expense => ExpenseForm(
      store: store,
      writer: writer,
      myKey: myKey,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.withdrawCapital => WithdrawalForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
      kind: 'capital',
    ),
    CreationAction.withdrawProfit => WithdrawalForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
      kind: 'profit',
    ),
    CreationAction.budget => BudgetForm(
      store: store,
      writer: writer,
      myKey: myKey,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.ratio => RatioForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.reversal => ReversalForm(
      store: store,
      writer: writer,
      myKey: myKey,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
    CreationAction.settlement => SettlementForm(
      store: store,
      writer: writer,
      partnership: partnership,
      onSyncNow: onSyncNow,
    ),
  };
}
