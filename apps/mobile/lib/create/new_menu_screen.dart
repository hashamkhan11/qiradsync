import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import '../theme/ledger_widgets.dart';
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

  /// Groups this menu's buttons for display only — the same grouping the
  /// mockup used (Capital / Trading / Agreements / Corrections). This is a
  /// presentation choice, not a rule: which actions appear at all, and in
  /// what underlying order, still comes only from [allowedCreationActions].
  static const _sections = <String, List<CreationAction>>{
    'Capital': [
      CreationAction.invest,
      CreationAction.withdrawCapital,
      CreationAction.withdrawProfit,
    ],
    'Trading': [CreationAction.sale, CreationAction.expense],
    'Agreements': [
      CreationAction.budget,
      CreationAction.ratio,
      CreationAction.settlement,
    ],
    'Corrections': [CreationAction.reversal],
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final validator = store.validatorFor(partnership);
    final parties = proposedParties(validator.usableRecords)!;
    final allowed = allowedCreationActions(myKey, parties);

    return Scaffold(
      appBar: AppBar(title: const Text('New')),
      body: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        children: [
          for (final section in _sections.entries)
            if (section.value.any(allowed.contains)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 16, bottom: 4),
                child: LedgerSectionLabel(section.key),
              ),
              for (final action in section.value)
                if (allowed.contains(action))
                  ListTile(
                    leading: Icon(_iconFor(action), color: theme.colorScheme.primary),
                    title: Text(_titleFor(action), style: theme.textTheme.bodyMedium),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (context) => _formFor(action)),
                    ),
                  ),
              Divider(height: 1, color: theme.colorScheme.outline),
            ],
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

  IconData _iconFor(CreationAction action) => switch (action) {
    CreationAction.invest => Icons.savings_outlined,
    CreationAction.sale => Icons.sell_outlined,
    CreationAction.expense => Icons.receipt_long_outlined,
    CreationAction.withdrawCapital => Icons.south_west,
    CreationAction.withdrawProfit => Icons.south_west,
    CreationAction.budget => Icons.account_balance_wallet_outlined,
    CreationAction.ratio => Icons.balance_outlined,
    CreationAction.reversal => Icons.undo,
    CreationAction.settlement => Icons.fact_check_outlined,
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
