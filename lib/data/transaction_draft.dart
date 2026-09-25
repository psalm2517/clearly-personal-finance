import 'database.dart';

/// The four things a person actually records. Everything else in Clearly
/// (bills, paychecks, recurring items, transfers, payments) is one of these,
/// repeating or not — this is the one vocabulary the Add flow speaks.
enum DraftKind { expense, income, transfer, payment }

/// What a person typed into the Add flow, before it is routed to the right
/// place. [HomebaseRepository.addTransaction] decides what it becomes.
class TransactionDraft {
  const TransactionDraft({
    required this.kind,
    required this.amountCents,
    required this.date,
    this.name,
    this.category,
    this.payee,
    this.tags = const [],
    this.splits = const [],
    this.accountId,
    this.cardId,
    this.toAccountId,
    this.payableType,
    this.payableId,
    this.targetCategory,
    this.note,
    this.repeats = false,
    this.frequency = PayFrequency.monthly,
  });

  final DraftKind kind;
  final int amountCents;

  /// The day it happened, or — when [repeats] — the first day it happens.
  final DateTime date;

  /// Description for an entry, name for a transfer or a repeating item.
  final String? name;
  final String? category;
  final String? payee;
  final List<String> tags;
  final List<({String category, int amountCents})> splits;

  /// Income/expense: the account it moved through. Transfer: the account it
  /// came from. Payment: the account it was paid from (optional).
  final int? accountId;

  /// Income/expense charged to or credited from a card.
  final int? cardId;

  /// Transfers: where the money went.
  final int? toAccountId;

  /// Payments: which card or loan was paid.
  final PaymentAccountType? payableType;
  final int? payableId;

  /// Transfers: a budget category this counts toward (e.g. "Invest").
  final String? targetCategory;

  /// Payments: an optional note.
  final String? note;

  final bool repeats;
  final PayFrequency frequency;
}
