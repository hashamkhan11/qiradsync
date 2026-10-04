import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Scans a join code with the camera and returns its text, or `null` if the
/// user goes back.
///
/// The camera is asked for only here, when the user taps "Scan" on the
/// onboarding screen. The scanner starts, and the system asks for permission.
/// If the user says no, the screen explains and offers to type the code.
/// Nothing is pinned here: the caller shows the safety code first (spec 2.1).
class ScanJoinCodeScreen extends StatefulWidget {
  const ScanJoinCodeScreen({super.key});

  @override
  State<ScanJoinCodeScreen> createState() => _ScanJoinCodeScreenState();
}

class _ScanJoinCodeScreenState extends State<ScanJoinCodeScreen> {
  /// Set on the first code, so one QR code cannot pop the screen twice.
  bool _found = false;

  void _onDetect(BarcodeCapture capture) {
    if (_found) return;
    final text = capture.barcodes.firstOrNull?.rawValue;
    if (text == null || text.isEmpty) return;
    _found = true;
    Navigator.of(context).pop(text);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan join code')),
      body: MobileScanner(
        onDetect: _onDetect,
        errorBuilder: (context, error) => _CameraProblem(error: error),
      ),
    );
  }
}

/// What to show when the camera cannot be used. The paste option stays open.
class _CameraProblem extends StatelessWidget {
  const _CameraProblem({required this.error});

  final MobileScannerException error;

  @override
  Widget build(BuildContext context) {
    final denied = error.errorCode == MobileScannerErrorCode.permissionDenied;
    final message = denied
        ? 'Camera access is off, so the code cannot be scanned. You can allow '
              'the camera in the phone settings, or type the code instead.'
        : 'The camera could not start. You can type the code instead.';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Type the code instead'),
            ),
          ],
        ),
      ),
    );
  }
}
