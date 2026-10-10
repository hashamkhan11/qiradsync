import '../storage/record_writer.dart';

/// Plain English for a refusal that has no special handling on the screen
/// that calls this. [WriteRefusal.notSynced], [WriteRefusal.chainBehindRelay]
/// and [WriteRefusal.summaryChanged] usually get their own banner with a
/// button instead (a "Sync now" button, or the new numbers); this is the
/// fallback text, and what the generic confirm screen uses for everything.
String refusalText(WriteRefusal refusal) {
  switch (refusal) {
    case WriteRefusal.notSynced:
    case WriteRefusal.chainBehindRelay:
      return 'This phone must sync before it can answer.';
    case WriteRefusal.answerEarlierFirst:
      return 'Answer the earlier settlement first.';
    case WriteRefusal.alreadyAnswered:
      return 'Already answered.';
    case WriteRefusal.alreadyDecided:
      return 'Already decided by the other partner.';
    case WriteRefusal.notAnswerable:
      return 'This cannot be answered.';
    case WriteRefusal.partnershipNotActive:
      return 'The partnership is not active yet.';
    case WriteRefusal.consentNotShown:
    case WriteRefusal.summaryChanged:
      return 'The numbers changed. Check them again before answering.';
    case WriteRefusal.wrongRole:
      return 'Your role cannot propose this.';
    case WriteRefusal.noEffectiveBudget:
      return 'Choose a budget that is approved and granted to you.';
    case WriteRefusal.notReversible:
      return 'This cannot be reversed.';
    case WriteRefusal.emptyCut:
      return 'Nothing new to settle since the last settlement.';
  }
}
