import 'sampling.dart';

/// One paisa is 1/100 of a rupee. Config amounts below are written in rupees
/// (so the numbers read the way a real Mudaraba business would state them)
/// and converted to paisa, the money unit the app's rules actually use, at
/// the point they are sampled.
const int paisaPerRupee = 100;

/// Every knob the workload generator reads, in one place, so a result file
/// can embed the exact config that produced it ([toJson]) and so the two
/// named configs below can be compared field by field.
///
/// Each field's doc comment is the one-line reason for its value; the same
/// text is reused verbatim in `docs/evaluation/README.md`'s parameter table.
class WorkloadConfig {
  const WorkloadConfig({
    required this.name,
    required this.days,
    required this.initialInvestment,
    required this.additionalInvestmentDailyChance,
    required this.additionalInvestmentAmount,
    required this.salesPerDay,
    required this.saleAmount,
    required this.saleMistakeRate,
    required this.expensesPerDay,
    required this.expenseAmount,
    required this.expenseMistakeRate,
    required this.reversalDelayHours,
    required this.budgetRenewalThreshold,
    required this.budgetCoverageDays,
    required this.ratioChangeIntervalDays,
    required this.ratioEffectiveFromLeadDays,
    required this.settlementIntervalDays,
    required this.settlementRejectChance,
    required this.answerDelayHours,
    required this.profitWithdrawalChance,
    required this.profitWithdrawalFraction,
    required this.capitalWithdrawalDailyChance,
    required this.capitalWithdrawalFraction,
    required this.shortOfflinePeriodsPerDay,
    required this.shortOfflinePeriodHours,
    required this.longOfflineEpisodeChancePerWeek,
    required this.longOfflineEpisodeDays,
    required this.relayDelaySeconds,
    required this.duplicateRate,
    required this.reorderChance,
  });

  /// Shown in result files so a chart or table can tell `realistic` and
  /// `stress` runs apart without re-reading their parameters.
  final String name;

  /// How many simulated days this run covers. RQ1 uses short runs (about a
  /// month); RQ3 varies this to reach the record counts it needs.
  final int days;

  /// Rs 500,000-2,000,000: a small Mudaraba business's typical starting
  /// capital — enough to fund real trade, not a token amount.
  final IntRange initialInvestment;

  /// About once every 60 days: an investor occasionally tops up capital
  /// mid-year, but it is not a routine event.
  final double additionalInvestmentDailyChance;

  /// Same size as the initial investment: a top-up is a real capital
  /// injection, not a small adjustment.
  final IntRange additionalInvestmentAmount;

  /// Expected sale entries per day. A manager records daily or per-deal
  /// totals, not every small sale, so this is a handful a day, not dozens.
  final double salesPerDay;

  /// Rs 2,000-100,000 per entry: a daily or per-deal total for a small
  /// trading business, not a single small-ticket sale.
  final IntRange saleAmount;

  /// 1 in 100 sales is later found wrong and reversed: mistakes happen, but
  /// rarely, and only a new reversal record fixes them (spec 6.3).
  final double saleMistakeRate;

  /// Expected expense entries per day: a manager usually logs expenses less
  /// often than sales (fewer, larger outflows against an open budget).
  final double expensesPerDay;

  /// Rs 200-30,000: ordinary running costs up to an occasional large
  /// purchase, drawn from an open budget.
  final IntRange expenseAmount;

  /// 1 in 33 expenses is reversed: a bit more error-prone than sales because
  /// expenses are checked against a budget at entry time.
  final double expenseMistakeRate;

  /// A mistake is noticed and reversed within 1-72 hours, not instantly —
  /// reversals are a real, slightly-delayed correction, not same-second.
  final IntRange reversalDelayHours;

  /// The manager proposes a new budget once the current one has under 20%
  /// left, so refusals in the data come from genuine budget pressure, not
  /// from a timer the generator runs on (the user's explicit requirement).
  final double budgetRenewalThreshold;

  /// A new budget is sized to cover about this many days of expected
  /// expenses, so budgets are realistic amounts, not arbitrary round numbers.
  final int budgetCoverageDays;

  /// How often the investor proposes a new profit-sharing ratio. `realistic`
  /// sets this to about once a year (ratios are rarely renegotiated);
  /// `stress` sets it to about every 45 days to exercise the rule often.
  final int ratioChangeIntervalDays;

  /// A new ratio takes effect 3-7 days after being proposed, modeling a
  /// short real negotiation lead time rather than an instant switch.
  final IntRange ratioEffectiveFromLeadDays;

  /// Settlements happen about once a month: the natural accounting cycle
  /// for this kind of partnership (spec 6.5).
  final int settlementIntervalDays;

  /// About 1 in 10 settlement proposals is rejected (a partner disputes the
  /// numbers) rather than approved, so both outcomes appear in the data.
  final double settlementRejectChance;

  /// How long a partner takes to notice and answer a pending approval.
  /// `realistic` uses the offline window itself; `stress` widens it to make
  /// staleness and reordering more likely to actually occur.
  final IntRange answerDelayHours;

  /// Chance each partner requests a profit withdrawal after a settlement
  /// takes effect: a common but not universal next step once profit is
  /// confirmed.
  final double profitWithdrawalChance;

  /// A withdrawal takes 10%-60% of the partner's settled share: partners
  /// rarely withdraw either a token amount or everything at once.
  final DoubleRange profitWithdrawalFraction;

  /// About once every 90 days: the investor rarely pulls capital out
  /// mid-partnership, so this must stay rare to be realistic.
  final double capitalWithdrawalDailyChance;

  /// A capital withdrawal takes 5%-20% of the current cash balance: a
  /// partial draw-down, not a full exit.
  final DoubleRange capitalWithdrawalFraction;

  /// How many short offline stretches happen per day on each device, on top
  /// of [longOfflineEpisodeChancePerWeek]'s occasional long one. A phone
  /// goes offline a few short times a day under normal use, in both configs.
  final IntRange shortOfflinePeriodsPerDay;

  /// Length of each short daily offline stretch: a work gap or overnight,
  /// in both configs — only the long weekly episode differs between them.
  final IntRange shortOfflinePeriodHours;

  /// Chance, per 7-day window, of one long offline episode starting (a
  /// genuinely dropped connection, not a daily gap). `realistic`: 0 — this
  /// never happens. `stress`: 1.0 — about once a week, every week.
  final double longOfflineEpisodeChancePerWeek;

  /// Length of a long offline episode, in days, when
  /// [longOfflineEpisodeChancePerWeek] fires. `stress` only: 1-3 days, long
  /// enough to force real divergence before the next sync.
  final IntRange longOfflineEpisodeDays;

  /// Extra network delay once a device is back online: a record is not
  /// eligible to be uploaded in a sync call until this long after it was
  /// authored. `realistic` models a normal connection; `stress` models a
  /// poor one.
  final IntRange relayDelaySeconds;

  /// Chance a device repeats the same sync call a second time right away (a
  /// retried sync re-sending records the relay already has), to exercise
  /// the merge's de-duplication (`ReceiveOutcome.duplicateIgnored`).
  final double duplicateRate;

  /// Chance a sync call's received batch is fed to the validator in a
  /// shuffled order instead of the relay's own per-author seq order, to
  /// exercise the chain-gap buffer. `realistic` keeps 0: a well-behaved
  /// client never does this on its own. `stress` exercises it often.
  final double reorderChance;

  /// Values chosen to model a real small Mudaraba business: everyday
  /// amounts, infrequent mistakes, a yearly ratio review, and short,
  /// ordinary offline gaps (a work break or overnight).
  factory WorkloadConfig.realistic({int days = 30}) => WorkloadConfig(
    name: 'realistic',
    days: days,
    initialInvestment: const IntRange(500000, 2000000),
    additionalInvestmentDailyChance: 1 / 60,
    additionalInvestmentAmount: const IntRange(500000, 2000000),
    salesPerDay: 1.5,
    saleAmount: const IntRange(2000, 100000),
    saleMistakeRate: 0.01,
    expensesPerDay: 0.8,
    expenseAmount: const IntRange(200, 30000),
    expenseMistakeRate: 0.03,
    reversalDelayHours: const IntRange(1, 72),
    budgetRenewalThreshold: 0.20,
    budgetCoverageDays: 14,
    ratioChangeIntervalDays: 365,
    ratioEffectiveFromLeadDays: const IntRange(3, 7),
    settlementIntervalDays: 30,
    settlementRejectChance: 0.10,
    answerDelayHours: const IntRange(1, 6),
    profitWithdrawalChance: 0.6,
    profitWithdrawalFraction: const DoubleRange(0.10, 0.60),
    capitalWithdrawalDailyChance: 1 / 90,
    capitalWithdrawalFraction: const DoubleRange(0.05, 0.20),
    shortOfflinePeriodsPerDay: const IntRange(1, 3),
    shortOfflinePeriodHours: const IntRange(1, 6),
    longOfflineEpisodeChancePerWeek: 0.0,
    longOfflineEpisodeDays: const IntRange(1, 3),
    relayDelaySeconds: const IntRange(0, 30),
    duplicateRate: 0.02,
    reorderChance: 0.0,
  );

  /// Values chosen to exercise the rules hard, not to model a typical day:
  /// an occasional multi-day offline episode on top of ordinary daily gaps,
  /// frequent ratio changes, more mistakes, and higher delay/duplicate/
  /// reorder rates, so staleness, reversal and chain-gap handling are all
  /// genuinely tested under pressure — without modeling a device that is
  /// offline so often it can never be reached at all.
  factory WorkloadConfig.stress({int days = 30}) => WorkloadConfig(
    name: 'stress',
    days: days,
    initialInvestment: const IntRange(500000, 2000000),
    additionalInvestmentDailyChance: 1 / 60,
    additionalInvestmentAmount: const IntRange(500000, 2000000),
    salesPerDay: 1.5,
    saleAmount: const IntRange(2000, 100000),
    saleMistakeRate: 0.05,
    expensesPerDay: 0.8,
    expenseAmount: const IntRange(200, 30000),
    expenseMistakeRate: 0.10,
    reversalDelayHours: const IntRange(1, 72),
    budgetRenewalThreshold: 0.20,
    budgetCoverageDays: 14,
    ratioChangeIntervalDays: 45,
    ratioEffectiveFromLeadDays: const IntRange(3, 7),
    settlementIntervalDays: 30,
    settlementRejectChance: 0.10,
    answerDelayHours: const IntRange(24, 72),
    profitWithdrawalChance: 0.6,
    profitWithdrawalFraction: const DoubleRange(0.10, 0.60),
    capitalWithdrawalDailyChance: 1 / 90,
    capitalWithdrawalFraction: const DoubleRange(0.05, 0.20),
    shortOfflinePeriodsPerDay: const IntRange(1, 2),
    shortOfflinePeriodHours: const IntRange(1, 6),
    longOfflineEpisodeChancePerWeek: 1.0,
    longOfflineEpisodeDays: const IntRange(1, 3),
    relayDelaySeconds: const IntRange(0, 300),
    duplicateRate: 0.10,
    reorderChance: 0.15,
  );

  Map<String, Object> toJson() => {
    'name': name,
    'days': days,
    'initialInvestment': initialInvestment.toJson(),
    'additionalInvestmentDailyChance': additionalInvestmentDailyChance,
    'additionalInvestmentAmount': additionalInvestmentAmount.toJson(),
    'salesPerDay': salesPerDay,
    'saleAmount': saleAmount.toJson(),
    'saleMistakeRate': saleMistakeRate,
    'expensesPerDay': expensesPerDay,
    'expenseAmount': expenseAmount.toJson(),
    'expenseMistakeRate': expenseMistakeRate,
    'reversalDelayHours': reversalDelayHours.toJson(),
    'budgetRenewalThreshold': budgetRenewalThreshold,
    'budgetCoverageDays': budgetCoverageDays,
    'ratioChangeIntervalDays': ratioChangeIntervalDays,
    'ratioEffectiveFromLeadDays': ratioEffectiveFromLeadDays.toJson(),
    'settlementIntervalDays': settlementIntervalDays,
    'settlementRejectChance': settlementRejectChance,
    'answerDelayHours': answerDelayHours.toJson(),
    'profitWithdrawalChance': profitWithdrawalChance,
    'profitWithdrawalFraction': profitWithdrawalFraction.toJson(),
    'capitalWithdrawalDailyChance': capitalWithdrawalDailyChance,
    'capitalWithdrawalFraction': capitalWithdrawalFraction.toJson(),
    'shortOfflinePeriodsPerDay': shortOfflinePeriodsPerDay.toJson(),
    'shortOfflinePeriodHours': shortOfflinePeriodHours.toJson(),
    'longOfflineEpisodeChancePerWeek': longOfflineEpisodeChancePerWeek,
    'longOfflineEpisodeDays': longOfflineEpisodeDays.toJson(),
    'relayDelaySeconds': relayDelaySeconds.toJson(),
    'duplicateRate': duplicateRate,
    'reorderChance': reorderChance,
  };
}
