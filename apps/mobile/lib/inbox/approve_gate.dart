/// Whether an inbox confirm screen (settlement or withdrawal) should show
/// its Approve button right now (spec 6.7's informed-consent rule: a
/// partner is never offered Approve without the numbers behind it).
///
/// One function, used by every confirm screen, so the rule cannot drift
/// between them — the same reuse principle as `cutProblem` in
/// `approvals_inbox.dart`, and deny-by-default: any reason the inbox gives
/// not to approve, or any summary this screen does not yet have, is enough
/// to hide the button. Nothing here is a special case for one kind of item.
///
/// - [summary] is the consent summary this screen has already computed
///   (`SettlementConsent?` or `WithdrawalConsent?`). `null` means there is
///   nothing to show yet, whatever the reason — the caller passes the
///   value itself, not a bool, so a screen can never compute this with the
///   summary and the "do I have one" check out of step.
/// - [blockedReason] is the matching [InboxItem.blockedReason] (`null` when
///   the inbox does not block this item). Withdrawals are never blocked by
///   the inbox today, so a withdrawal screen always passes `null` here.
/// - [needsSync] is set once a write to this record was refused because
///   this phone's own chain is behind the relay (spec 7.4) — approving
///   again before syncing would only be refused the same way.
bool canShowApprove({
  required Object? summary,
  required String? blockedReason,
  required bool needsSync,
}) {
  return summary != null && blockedReason == null && !needsSync;
}
