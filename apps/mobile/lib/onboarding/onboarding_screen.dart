import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qirad_core/qirad_core.dart';

import '../join/join_code.dart';
import '../storage/record_store.dart';
import 'partnership_setup.dart';
import 'safety_code_dialog.dart';

/// The first screen on a new phone. The partner either starts a partnership
/// (investor) or joins one (manager). Keys and codes are shared as text for
/// now; the QR code comes in a later step.
class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({
    super.key,
    required this.store,
    required this.keys,
    required this.onReady,
  });

  final RecordStore store;
  final Ed25519KeyPair keys;

  /// Called once the partnership is saved and pinned on this phone.
  final void Function(String partnership) onReady;

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _managerKey = TextEditingController();
  final _investorPercent = TextEditingController(text: '60');
  final _joinCode = TextEditingController();

  /// Set after the investor creates a partnership, so the code can be shared.
  String? _createdCode;
  String? _createdPartnership;
  String? _error;

  @override
  void dispose() {
    _managerKey.dispose();
    _investorPercent.dispose();
    _joinCode.dispose();
    super.dispose();
  }

  Future<void> _create() async {
    setState(() => _error = null);
    final investorKey = widget.keys.publicKeyBase64Url;
    final managerKey = _managerKey.text.trim();
    final percent = int.tryParse(_investorPercent.text.trim()) ?? -1;
    try {
      // Check the input before a safety code is shown for it.
      checkNewPartnership(
        investorKey: investorKey,
        managerKey: managerKey,
        investorPercent: percent,
      );
    } on ArgumentError catch (e) {
      // RangeError is a kind of ArgumentError, so one catch covers both.
      setState(() => _error = e.message.toString());
      return;
    }

    // The pins are saved only after the partners confirm the code (spec 2.1).
    final confirmed = await confirmSafetyCode(
      context,
      investorKey: investorKey,
      managerKey: managerKey,
    );
    if (!confirmed || !mounted) return;

    final id = await createPartnership(
      investorKeys: widget.keys,
      managerKey: managerKey,
      investorPercent: percent,
      store: widget.store,
    );
    if (!mounted) return;
    setState(() {
      _createdPartnership = id;
      _createdCode = JoinCode(
        partnership: id,
        investorKey: investorKey,
      ).encode();
    });
  }

  Future<void> _join() async {
    setState(() => _error = null);
    final JoinCode code;
    try {
      code = JoinCode.parse(_joinCode.text.trim());
    } on FormatException catch (e) {
      setState(() => _error = e.message);
      return;
    }
    if (code.investorKey == widget.keys.publicKeyBase64Url) {
      setState(() => _error = 'this is your own key; use the investor phone');
      return;
    }

    // Both phones show the same code, computed from the same two keys.
    final confirmed = await confirmSafetyCode(
      context,
      investorKey: code.investorKey,
      managerKey: widget.keys.publicKeyBase64Url,
    );
    if (!confirmed || !mounted) return;

    try {
      await joinPartnership(
        code: code,
        store: widget.store,
        ownKeys: widget.keys,
      );
    } on StateError catch (e) {
      // The id is already pinned with other keys on this phone.
      setState(() => _error = e.message);
      return;
    }
    if (!mounted) return;
    widget.onReady(code.partnership);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up QiradSync')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text('Your key', style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          const Text('Send this to your partner so they can pin it.'),
          const SizedBox(height: 8),
          SelectableText(widget.keys.publicKeyBase64Url),
          TextButton.icon(
            onPressed: () => _copy(widget.keys.publicKeyBase64Url),
            icon: const Icon(Icons.copy),
            label: const Text('Copy my key'),
          ),
          const Divider(height: 32),
          Text(
            'Start a partnership (I am the investor)',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _managerKey,
            decoration: const InputDecoration(
              labelText: "Manager's key",
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _investorPercent,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Investor share (%)',
              helperText: 'From 1 to 99. The manager gets the rest.',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _createdCode == null ? _create : null,
            child: const Text('Create partnership'),
          ),
          if (_createdCode != null) ...[
            const SizedBox(height: 12),
            const Text('Send this join code to your partner:'),
            const SizedBox(height: 8),
            SelectableText(_createdCode!),
            TextButton.icon(
              onPressed: () => _copy(_createdCode!),
              icon: const Icon(Icons.copy),
              label: const Text('Copy join code'),
            ),
            FilledButton.tonal(
              onPressed: () => widget.onReady(_createdPartnership!),
              child: const Text('Continue'),
            ),
          ],
          const Divider(height: 32),
          Text(
            'Join a partnership (I am the manager)',
            style: theme.textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _joinCode,
            decoration: const InputDecoration(
              labelText: 'Join code from the investor',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(onPressed: _join, child: const Text('Join partnership')),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ],
        ],
      ),
    );
  }

  void _copy(String text) {
    Clipboard.setData(ClipboardData(text: text));
  }
}
