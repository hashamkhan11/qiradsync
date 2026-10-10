import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
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

    return Scaffold(
      appBar: AppBar(title: const Text('Transactions')),
      body: records.isEmpty
          ? const Center(child: Text('No records yet.'))
          : ListView.separated(
              itemCount: records.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final record = records[index];
                final status = statuses[record.id]!;
                return ListTile(
                  title: Text(_typeLabel(record.type)),
                  subtitle: Text(
                    '${_roleLabel(record.author, parties)} · '
                    '${statusLabel(status)}',
                  ),
                  trailing: Text(_amountLabel(record)),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (context) => RecordDetailScreen(
                        record: record,
                        status: status,
                        authorLabel: _roleLabel(record.author, parties),
                      ),
                    ),
                  ),
                );
              },
            ),
    );
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
