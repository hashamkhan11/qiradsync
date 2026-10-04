import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qirad_core/qirad_core.dart';

import '../join/join_code.dart';
import '../storage/record_store.dart';
import 'partnership_setup.dart';

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
    try {
      final id = await createPartnership(
        investorKeys: widget.keys,
        managerKey: _managerKey.text.trim(),
        investorPercent: int.tryParse(_investorPercent.text.trim()) ?? -1,
        store: widget.store,
      );
      setState(() {
        _createdPartnership = id;
        _createdCode = JoinCode(
          partnership: id,
          investorKey: widget.keys.publicKeyBase64Url,
        ).encode();
      });
    } on ArgumentError catch (e) {
      // RangeError is a kind of ArgumentError, so one catch covers both.
      setState(() => _error = e.message.toString());
    }
  }

  Future<void> _join() async {
    setState(() => _error = null);
    try {
      final code = JoinCode.parse(_joinCode.text.trim());
      await joinPartnership(
        code: code,
        store: widget.store,
        ownKeys: widget.keys,
      );
      widget.onReady(code.partnership);
    } on FormatException catch (e) {
      setState(() => _error = e.message);
    } on ArgumentError catch (e) {
      setState(() => _error = e.message.toString());
    }
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
              helperText: 'The manager gets the rest.',
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
