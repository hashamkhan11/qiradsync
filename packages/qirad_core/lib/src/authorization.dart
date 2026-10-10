import 'settlement.dart';

/// Spec section 5's "Allowed author" column: true when [author] may write a
/// record of [type]. [kind] matters only for `withdraw_request`, where
/// "capital" is investor-only and "profit" is open to either partner
/// (decision 2026-10-10).
///
/// This is the one place the rule is decided. Our threat model assumes the
/// other partner may be dishonest and can sign *any* record type with their
/// own valid key, without going through this app at all — so the app's own
/// menus (which only ever offer the actions a role may take) are not a real
/// restriction on their own. Three callers share this one function so none
/// of them can drift from the others: the validator (`Validator._passesMembership`,
/// spec 6.1 step 3) rejects a wrong-role record on receive, the same as a
/// record from an outside key; every `RecordWriter.propose*` method
/// (apps/mobile) refuses to even build one; and the "New" menu's
/// [allowedCreationActions] uses it to decide which buttons to offer.
bool canAuthor(String type, String author, Parties parties, {String? kind}) {
  switch (type) {
    case 'partnership_create':
    case 'invest':
      return author == parties.investor;
    case 'sale':
    case 'expense':
    case 'settlement':
      return author == parties.manager;
    case 'withdraw_request':
      if (kind == 'capital') return author == parties.investor;
      return true;
    default:
      // budget_proposal, ratio_proposal, reversal, approve, reject: either.
      return true;
  }
}

/// The record types a person can propose from the app's "New" menu — every
/// `RecordWriter.propose*` method has exactly one matching action here,
/// `withdraw_request` splits into two because its allowed author depends on
/// [kind].
enum CreationAction {
  invest,
  sale,
  expense,
  withdrawCapital,
  withdrawProfit,
  budget,
  ratio,
  reversal,
  settlement,
}

/// The record type (and `kind`, for a withdrawal) that [action]'s form
/// proposes. Exposed so a caller can run [canAuthor] for one action without
/// a second, hand-written type/kind mapping.
(String type, String? kind) recordKindFor(CreationAction action) {
  switch (action) {
    case CreationAction.invest:
      return ('invest', null);
    case CreationAction.sale:
      return ('sale', null);
    case CreationAction.expense:
      return ('expense', null);
    case CreationAction.withdrawCapital:
      return ('withdraw_request', 'capital');
    case CreationAction.withdrawProfit:
      return ('withdraw_request', 'profit');
    case CreationAction.budget:
      return ('budget_proposal', null);
    case CreationAction.ratio:
      return ('ratio_proposal', null);
    case CreationAction.reversal:
      return ('reversal', null);
    case CreationAction.settlement:
      return ('settlement', null);
  }
}

/// The actions spec section 5 lets [author] take right now, derived from
/// [canAuthor] alone so the "New" menu can never offer a button that a
/// `propose*` call would just refuse for having the wrong role.
Set<CreationAction> allowedCreationActions(String author, Parties parties) {
  final allowed = <CreationAction>{};
  for (final action in CreationAction.values) {
    final (type, kind) = recordKindFor(action);
    if (canAuthor(type, author, parties, kind: kind)) allowed.add(action);
  }
  return allowed;
}
