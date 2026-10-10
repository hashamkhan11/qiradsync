import 'package:flutter/material.dart';

import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes `ratio_proposal`: a new profit-share split, effective from a
/// chosen date (spec section 5). Either partner may propose this. The date
/// is display only (hard rule 3) — it says when the new split should start,
/// but nothing here decides anything from the clock.
class RatioForm extends StatefulWidget {
  const RatioForm({
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
  State<RatioForm> createState() => _RatioFormState();
}

class _RatioFormState extends State<RatioForm> {
  final _investorPercent = TextEditingController();
  DateTime? _effectiveFrom;

  @override
  void initState() {
    super.initState();
    _investorPercent.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _investorPercent.dispose();
    super.dispose();
  }

  int? get _investor {
    final value = int.tryParse(_investorPercent.text.trim());
    if (value == null || value < 0 || value > 100) return null;
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final investor = _investor;
    final manager = investor == null ? null : 100 - investor;
    final effectiveFrom = _effectiveFrom;
    final canSave = investor != null && effectiveFrom != null;

    return CreateScaffold(
      title: 'Propose a new ratio',
      canSave: canSave,
      onSyncNow: widget.onSyncNow,
      propose: () => widget.writer.proposeRatio(
        investorPercent: investor!,
        managerPercent: manager!,
        effectiveFrom: _dateText(effectiveFrom!),
      ),
      body: Column(
        children: [
          TextField(
            controller: _investorPercent,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: "Investor's share (%)",
            ),
          ),
          const SizedBox(height: 16),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(
              effectiveFrom == null
                  ? 'Choose the effective date'
                  : 'Effective from ${_dateText(effectiveFrom)}',
            ),
            trailing: const Icon(Icons.calendar_today),
            onTap: _pickDate,
          ),
          const SizedBox(height: 16),
          CreatePreviewCard(
            rows: [
              (
                'New ratio',
                investor == null ? '—' : '$investor/$manager',
              ),
              (
                'Effective from',
                effectiveFrom == null ? '—' : _dateText(effectiveFrom),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _pickDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _effectiveFrom ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: DateTime(now.year + 5),
    );
    if (picked != null) setState(() => _effectiveFrom = picked);
  }

  static String _dateText(DateTime date) =>
      '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}
