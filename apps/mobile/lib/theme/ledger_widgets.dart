import 'package:flutter/material.dart';

import 'qirad_theme.dart';

/// One ledger row: a label on the left, a tabular-figure amount on the
/// right. Every balance on the dashboard is one of these, so the whole
/// screen reads as one consistent column of figures instead of a list of
/// differently styled rows.
class LedgerFigureRow extends StatelessWidget {
  const LedgerFigureRow({
    super.key,
    required this.label,
    required this.value,
    this.caption,
  });

  final String label;
  final String value;
  final String? caption;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: Theme.of(context).textTheme.bodyMedium),
                if (caption != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      caption!,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: qiradFigureStyle(context)),
        ],
      ),
    );
  }
}

/// A heading for a group of ledger rows ("Shares of the result", "Profit
/// withdrawn", ...), styled the same way everywhere a screen groups figures.
class LedgerSectionLabel extends StatelessWidget {
  const LedgerSectionLabel(this.text, {super.key, this.tag});

  final String text;
  final Widget? tag;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text.toUpperCase(),
      style: Theme.of(context).textTheme.titleMedium,
    );
    if (tag == null) return label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [label, const SizedBox(width: 8), tag!],
    );
  }
}

/// A small open-ring checkmark next to a record's type.
///
/// It means exactly one thing: this record's signature and hash-chain link
/// were checked and hold (spec 6.1 steps 1-3, hard rule 6). It is never
/// shown as decoration — only [RecordStatus.usable] records get it, so its
/// presence is itself a verified fact about that record, not a style choice.
class SealMark extends StatelessWidget {
  const SealMark({super.key, this.size = 15});

  final double size;

  @override
  Widget build(BuildContext context) {
    final seal =
        Theme.of(context).extension<QiradTokens>()?.seal ??
        Theme.of(context).colorScheme.secondary;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: seal, width: 1.3),
      ),
      child: Icon(Icons.check, size: size * 0.62, color: seal),
    );
  }
}

/// The three tones a record or approval status can carry. Semantic color,
/// kept separate from the pine accent (artifact-design: semantic color is
/// not the brand accent) so "this needs attention" always reads the same
/// way regardless of screen.
enum StatusTone { good, warn, wait }

/// A small bordered tag — a rubber-stamp outline, not a filled blob — used
/// for record and approval statuses ("Confirmed", "Not counted", "Pending").
class StatusTag extends StatelessWidget {
  const StatusTag({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final Color color;
    final Color? background;
    switch (tone) {
      case StatusTone.good:
        color = scheme.primary;
        background = null;
      case StatusTone.warn:
        color = scheme.error;
        background = scheme.errorContainer;
      case StatusTone.wait:
        color = scheme.onSurfaceVariant;
        background = null;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
        border: background == null ? Border.all(color: color, width: 1) : null,
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),
    );
  }
}

/// The integrity/equivocation/ratio-changed warning card (spec 6.1 steps
/// 4-5): the one block allowed to look like a card, because it is the one
/// thing meant to interrupt the reader.
class LedgerWarningCard extends StatelessWidget {
  const LedgerWarningCard({super.key, required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          message,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onErrorContainer,
            fontSize: 13,
            height: 1.4,
          ),
        ),
      ),
    );
  }
}
