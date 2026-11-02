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
      padding: const EdgeInsets.symmetric(vertical: 8),
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

/// A rounded, softly-shadowed surface that groups related rows — the
/// modern stand-in for the old flat, hairline-divided list. Every screen
/// that groups ledger rows (the dashboard's position and shares, a
/// transaction row, a menu section) wraps them in one of these instead of
/// each inventing its own card-like container.
///
/// Deliberately not Flutter's [Card]: that widget's theme is reserved for
/// the one card role meant to interrupt the reader (the warning card), so
/// a neutral group gets its own widget instead of fighting that theme.
class LedgerGroupCard extends StatelessWidget {
  const LedgerGroupCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<QiradTokens>()!;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: theme.colorScheme.outline),
        boxShadow: [
          BoxShadow(
            color: tokens.shadow,
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: child,
    );
  }
}

/// A two-tone bar showing each partner's share of the active ratio (spec
/// 6.6) at a glance — the same split the figures below it already state as
/// numbers, drawn so the proportion is visible without reading either one.
class RatioBar extends StatelessWidget {
  const RatioBar({super.key, required this.investorPercent});

  /// 1 to 99 (spec 2.1/6.6: the manager always gets the rest).
  final int investorPercent;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tokens = theme.extension<QiradTokens>()!;
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 10,
        child: Row(
          children: [
            Expanded(
              flex: investorPercent,
              child: Container(color: theme.colorScheme.primary),
            ),
            Expanded(
              flex: 100 - investorPercent,
              child: Container(color: tokens.seal),
            ),
          ],
        ),
      ),
    );
  }
}

/// A filled gold disc with a check mark next to a record's type.
///
/// It means exactly one thing: this record's signature and hash-chain link
/// were checked and hold (spec 6.1 steps 1-3, hard rule 6). It is never
/// shown as decoration — only [RecordStatus.usable] records get it, so its
/// presence is itself a verified fact about that record, not a style choice.
class SealMark extends StatelessWidget {
  const SealMark({super.key, this.size = 22});

  final double size;

  @override
  Widget build(BuildContext context) {
    final tokens = Theme.of(context).extension<QiradTokens>()!;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(shape: BoxShape.circle, color: tokens.seal),
      child: Icon(Icons.check, size: size * 0.62, color: tokens.onSeal),
    );
  }
}

/// The three tones a record or approval status can carry. Semantic color,
/// kept separate from the brand primary (artifact-design: semantic color is
/// not the brand accent) so "this needs attention" always reads the same
/// way regardless of screen.
enum StatusTone { good, warn, wait }

/// A small filled pill — a badge, not a rubber-stamp outline — used for
/// record and approval statuses ("Effective", "Over budget", "Pending").
class StatusTag extends StatelessWidget {
  const StatusTag({super.key, required this.label, required this.tone});

  final String label;
  final StatusTone tone;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<QiradTokens>()!;
    final Color color;
    final Color background;
    switch (tone) {
      case StatusTone.good:
        color = scheme.primary;
        background = tokens.goodBg;
      case StatusTone.warn:
        color = scheme.error;
        background = scheme.errorContainer;
      case StatusTone.wait:
        color = tokens.seal;
        background = tokens.waitBg;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
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
        padding: const EdgeInsets.all(14),
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
