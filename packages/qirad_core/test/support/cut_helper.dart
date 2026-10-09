import 'package:qirad_core/qirad_core.dart';

import 'partnership_fixture.dart';

/// Builds a settlement `cut` map (spec 6.7, step 4a) from real records
/// instead of a hand-counted seq number.
///
/// A literal number like `{manager.key: 1}` means something different
/// depending on exactly how many records the fixture sent before the test's
/// own records — a number that was correct yesterday can silently point at
/// the wrong record tomorrow, and the test still runs, just over the wrong
/// scenario. Reading the seq straight off the record the cut is meant to
/// reach removes that risk: the cut's meaning no longer depends on counting.
///
/// Pass the record each side's cut should reach, or leave a side out for
/// "nothing from them yet" (seq 0). [investor] and [manager] are needed for
/// their public keys even when a side has nothing yet.
Map<String, int> cutUpTo(
  ChainAuthor investor,
  ChainAuthor manager, {
  Record? upToInvestor,
  Record? upToManager,
}) => {
  investor.key: upToInvestor?.seq ?? 0,
  manager.key: upToManager?.seq ?? 0,
};
