import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';

/// One record's facts, exactly as stored and signed (spec section 3).
///
/// Shows the same four facts as the list (type, author, amount, status),
/// plus the record's identity (id, seq, time) for when a partner needs to
/// point at one exact record, for example while talking through an
/// integrity banner on the dashboard. Also shows a dedicated signature
/// status (separate from the business [RecordStatus]) and, when this
/// record refers to another, a link to that record's own detail screen.
class RecordDetailScreen extends StatelessWidget {
  const RecordDetailScreen({
    super.key,
    required this.record,
    required this.status,
    required this.authorLabel,
    required this.findRecord,
    required this.statusOf,
    required this.authorLabelOf,
  });

  final Record record;
  final RecordStatus status;
  final String authorLabel;

  /// Looks up another record on this phone by id, for `refersTo`. Returns
  /// null when this phone has not received that record yet.
  final Record? Function(String id) findRecord;
  final RecordStatus Function(String id) statusOf;
  final String Function(String author) authorLabelOf;

  @override
  Widget build(BuildContext context) {
    final amount = record.body['amount'];
    final refersTo = record.refersTo;
    final referenced = refersTo == null ? null : findRecord(refersTo);
    return Scaffold(
      appBar: AppBar(title: Text(record.type.replaceAll('_', ' '))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _Fact(label: 'Type', value: record.type.replaceAll('_', ' ')),
          _Fact(label: 'Author', value: authorLabel),
          _Fact(
            label: 'Amount',
            value: amount is int ? formatPaisa(amount) : '—',
          ),
          _Fact(label: 'Status', value: statusLabel(status)),
          // The business status above can be "effective" or "rejected" even
          // though the signature itself is always valid: a record only
          // ever reaches this screen because it passed signature
          // verification on receipt (spec 6.1 step 2) — an unsigned or
          // wrongly-signed record is never stored at all. This fact says
          // that plainly, instead of leaving it implied by "effective".
          const _Fact(
            label: 'Signature',
            value: 'Valid — checked against the author\'s key on receipt',
          ),
          const Divider(height: 32),
          _Fact(label: 'Id', value: record.id),
          _Fact(label: 'Seq', value: '${record.seq}'),
          _Fact(label: 'Time', value: record.time),
          if (refersTo != null)
            _ReferenceFact(
              refersTo: refersTo,
              referenced: referenced,
              onTap: referenced == null
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (context) => RecordDetailScreen(
                          record: referenced,
                          status: statusOf(referenced.id),
                          authorLabel: authorLabelOf(referenced.author),
                          findRecord: findRecord,
                          statusOf: statusOf,
                          authorLabelOf: authorLabelOf,
                        ),
                      ),
                    ),
            ),
        ],
      ),
    );
  }
}

/// "Refers to" as a tappable link to the referenced record, when this phone
/// has it. Falls back to plain text (the raw id) when the target has not
/// arrived yet — it may still be in flight, so this is not an error.
class _ReferenceFact extends StatelessWidget {
  const _ReferenceFact({
    required this.refersTo,
    required this.referenced,
    required this.onTap,
  });

  final String refersTo;
  final Record? referenced;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final label = referenced == null
        ? refersTo
        : '${referenced!.type.replaceAll('_', ' ')} ($refersTo)';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(width: 90, child: Text('Refers to')),
          Expanded(
            child: onTap == null
                ? Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  )
                : InkWell(
                    onTap: onTap,
                    child: Text(
                      label,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.primary,
                        decoration: TextDecoration.underline,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

class _Fact extends StatelessWidget {
  const _Fact({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 90, child: Text(label)),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
