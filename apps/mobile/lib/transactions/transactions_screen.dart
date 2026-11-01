import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../theme/ledger_widgets.dart';
import '../theme/qirad_theme.dart';
import 'record_detail_screen.dart';

/// Every record this phone has ever stored for this partnership, each with
/// its status (spec 6.1, 6.3, 6.4, 6.7).
///
/// This is deliberately not filtered: a chain-invalid or equivocating
/// record is still evidence the partners may need to see, so it stays on
/// the list with a status that says it is not counted, instead of
/// disappearing. `recordStatuses` (qirad_core) is the only place that
/// decides what each status is; this screen only shows it.
class TransactionsScreen extends StatelessWidget {
  const TransactionsScreen({
    super.key,
    required this.store,
    required this.partnership,
  });

  final RecordStore store;
  final String partnership;

  @override
  Widget build(BuildContext context) {
    final validator = store.validatorFor(partnership);
    final parties = proposedParties(validator.ledger.records);
    final statuses = recordStatuses(
      validator.ledger.records,
      usable: validator.usableRecords,
      chainInvalidIds: validator.chainInvalidIds,
      equivocatingFromSeq: validator.equivocatingFromSeq,
      partnershipKeys: validator.partnershipKeys ?? const <String>{},
    );

    // No particular order is stored (the ledger is a G-Set), so the order
    // shown here must be chosen explicitly: each author's own chain order
    // groups their records together (hard rule: deterministic, no clock).
    final records = validator.ledger.records.toList()
      ..sort((a, b) {
        final byAuthor = a.author.compareTo(b.author);
        return byAuthor != 0 ? byAuthor : a.seq.compareTo(b.seq);
      });
    final byId = {for (final record in records) record.id: record};

    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: records.isEmpty
          ? Center(
              child: Text('No records yet.', style: theme.textTheme.bodyMedium),
            )
          : ListView.separated(
              itemCount: records.length,
              separatorBuilder: (context, index) =>
                  Divider(height: 1, color: theme.colorScheme.outline),
              itemBuilder: (context, index) {
                final record = records[index];
                final status = statuses[record.id]!;
                // The chain and signature check (spec 6.1 steps 1-3) is the
                // only thing the seal mark reports: a record can still fail
                // *this* check (chainInvalid/equivocating) while everything
                // else about it — its amount, its type — is shown as usual.
                final verified =
                    status != RecordStatus.chainInvalid &&
                    status != RecordStatus.equivocating;
                return ListTile(
                  leading: verified
                      ? const SealMark()
                      : Icon(Icons.error_outline, color: theme.colorScheme.error),
                  title: Text(
                    _typeLabel(record.type),
                    style: theme.textTheme.bodyMedium,
                  ),
                  subtitle: Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _roleLabel(record.author, parties),
                          style: theme.textTheme.bodySmall,
                        ),
                        const SizedBox(width: 8),
                        StatusTag(
                          label: statusLabel(status),
                          tone: _toneFor(status),
                        ),
                      ],
                    ),
                  ),
                  trailing: Text(_amountLabel(record), style: qiradFigureStyle(context)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => RecordDetailScreen(
                        record: record,
                        status: status,
                        authorLabel: _roleLabel(record.author, parties),
                        findRecord: (id) => byId[id],
                        statusOf: (id) => statuses[id]!,
                        authorLabelOf: (author) =>
                            _roleLabel(author, parties),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}

/// Which of the three tags a status reads as: counted now, still waiting,
/// or a problem/final-negative outcome (spec 6.1, 6.3, 6.4, 6.7).
StatusTone _toneFor(RecordStatus status) {
  switch (status) {
    case RecordStatus.effective:
      return StatusTone.good;
    case RecordStatus.pendingApproval:
    case RecordStatus.ignoredResponse:
    case RecordStatus.cancelledByReversal:
    case RecordStatus.notCounted:
      return StatusTone.wait;
    case RecordStatus.rejected:
    case RecordStatus.overBudget:
    case RecordStatus.invalidResponse:
    case RecordStatus.chainInvalid:
    case RecordStatus.equivocating:
      return StatusTone.warn;
  }
}

String _typeLabel(String type) => type.replaceAll('_', ' ');

String _roleLabel(String author, Parties? parties) {
  switch (partnerRole(author, parties)) {
    case 'investor':
      return 'Investor';
    case 'manager':
      return 'Manager';
    default:
      return 'Unknown';
  }
}

/// The record's own amount, when its body has one. Many types (approve,
/// reject, partnership_create, ...) have none, so "—" is the honest answer.
String _amountLabel(Record record) {
  final amount = record.body['amount'];
  return amount is int ? formatPaisa(amount) : '—';
}
