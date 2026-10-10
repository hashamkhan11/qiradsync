import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes `settlement`: closes the open period at this phone's current
/// chain vector (spec 6.7). Manager only — the "New" menu only offers this
/// to the manager, but [RecordWriter.proposeSettlement] refuses it for
/// anyone else anyway. Shows the open period's result and each partner's
/// share before the Save button does anything, and
/// [WriteRefusal.emptyCut] gets its own explanation here (plain English,
/// not just [refusalText]'s one line), because "nothing new to settle" is
/// easy to misread as an error rather than as the expected outcome.
class SettlementForm extends StatelessWidget {
  const SettlementForm({
    super.key,
    required this.store,
    required this.writer,
    required this.partnership,
    required this.onSyncNow,
  });

  final RecordStore store;
  final RecordWriter writer;
  final String partnership;
  final Future<void> Function() onSyncNow;

  @override
  Widget build(BuildContext context) {
    final validator = store.validatorFor(partnership);
    final periods = periodShares(
      validator.usableRecords,
      partnershipKeys: validator.partnershipKeys!,
    );
    final open = periods.isEmpty ? null : periods.last;

    return CreateScaffold(
      title: 'Settle the open period',
      canSave: open != null,
      onSyncNow: onSyncNow,
      propose: writer.proposeSettlement,
      body: Column(
        children: [
          if (open == null)
            const Text('Nothing to settle yet.')
          else
            CreatePreviewCard(
              rows: [
                ('Open period result', formatPaisa(open.result)),
                ('Investor share', formatPaisa(open.shares.investor)),
                ('Manager share', formatPaisa(open.shares.manager)),
              ],
            ),
          const SizedBox(height: 12),
          const _EmptyCutExplainer(),
        ],
      ),
    );
  }
}

/// Shown once, under the preview: plain English for what
/// [WriteRefusal.emptyCut] means, so it reads as "there is nothing to do",
/// not as a failure, if Save refuses this way.
class _EmptyCutExplainer extends StatelessWidget {
  const _EmptyCutExplainer();

  @override
  Widget build(BuildContext context) {
    return Text(
      'If Save says there is nothing new to settle, it means no sale, '
      'expense, investment or withdrawal has happened since the last '
      'settlement — there is nothing to add it for yet.',
      style: Theme.of(context).textTheme.bodySmall,
    );
  }
}
