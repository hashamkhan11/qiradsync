import 'package:flutter/material.dart';
import 'package:qirad_core/qirad_core.dart';

import '../dashboard/format.dart';
import '../storage/record_store.dart';
import '../storage/record_writer.dart';
import 'create_widgets.dart';

/// Proposes a `withdraw_request` (spec section 5). [kind] is `"capital"` or
/// `"profit"`, chosen by which "New" menu button opened this form — the
/// menu offers "Withdraw capital" only to the investor, but
/// [RecordWriter.proposeWithdrawal] refuses a capital withdrawal from anyone
/// else anyway, so this form does not re-check the role.
class WithdrawalForm extends StatefulWidget {
  const WithdrawalForm({
    super.key,
    required this.store,
    required this.writer,
    required this.partnership,
    required this.onSyncNow,
    required this.kind,
  });

  final RecordStore store;
  final RecordWriter writer;
  final String partnership;
  final Future<void> Function() onSyncNow;
  final String kind;

  @override
  State<WithdrawalForm> createState() => _WithdrawalFormState();
}

class _WithdrawalFormState extends State<WithdrawalForm> {
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
      title: widget.kind == 'capital' ? 'Withdraw capital' : 'Withdraw profit',
      canSave: paisa != null,
      onSyncNow: widget.onSyncNow,
      propose: () =>
          widget.writer.proposeWithdrawal(amount: paisa!, kind: widget.kind),
      body: Column(
        children: [
          AmountField(
            controller: _amount,
            invalid: _amount.text.isNotEmpty && paisa == null,
          ),
          const SizedBox(height: 16),
          CreatePreviewCard(
            rows: [
              (
                'Requests a ${widget.kind} withdrawal',
                paisa == null ? '—' : formatPaisa(paisa),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
