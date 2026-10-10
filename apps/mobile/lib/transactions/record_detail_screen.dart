import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';

/// One record's facts, exactly as stored and signed (spec section 3).
///
/// Shows the same four facts as the list (type, author, amount, status),
/// plus the record's identity (id, seq, time) for when a partner needs to
/// point at one exact record, for example while talking through an
/// integrity banner on the dashboard.
class RecordDetailScreen extends StatelessWidget {
  const RecordDetailScreen({
    super.key,
    required this.record,
    required this.status,
    required this.authorLabel,
  });

  final Record record;
  final RecordStatus status;
  final String authorLabel;

  @override
  Widget build(BuildContext context) {
    final amount = record.body['amount'];
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
          const Divider(height: 32),
          _Fact(label: 'Id', value: record.id),
          _Fact(label: 'Seq', value: '${record.seq}'),
          _Fact(label: 'Time', value: record.time),
          if (record.refersTo != null)
            _Fact(label: 'Refers to', value: record.refersTo!),
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
