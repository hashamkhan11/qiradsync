import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes `sale`: the manager adds income (spec section 5). The "New" menu
/// only offers this to the manager, but [RecordWriter.proposeSale] refuses
/// it for anyone else anyway — this form does not re-check the role.
class SaleForm extends StatefulWidget {
  const SaleForm({
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
  State<SaleForm> createState() => _SaleFormState();
}

class _SaleFormState extends State<SaleForm> {
  final _amount = TextEditingController();

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
    final paisa = parseRupeesToPaisa(_amount.text);
    return CreateScaffold(
      title: 'Record a sale',
      canSave: paisa != null,
      onSyncNow: widget.onSyncNow,
      propose: () => widget.writer.proposeSale(amount: paisa!),
      body: Column(
        children: [
          AmountField(
            controller: _amount,
            invalid: _amount.text.isNotEmpty && paisa == null,
          ),
          const SizedBox(height: 16),
          CreatePreviewCard(
            rows: [('Adds income', paisa == null ? '—' : formatPaisa(paisa))],
          ),
        ],
      ),
    );
  }
}
