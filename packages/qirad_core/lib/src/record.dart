/// A single signed ledger record, exactly as defined in spec section 3.
///
/// Records are immutable: once created, a record is never changed. A
/// mistake is fixed by creating a new `reversal` record, never by editing
/// or deleting this one (hard rule: records are never edited or deleted).
class Record {
  final int v;
  final String id;
  final String partnership;
  final String author;
  final int seq;
  final String prevHash;
  final String type;
  final Map<String, dynamic> body;
  final String? refersTo;
  final String note;
  final String time;
  final String sig;

  const Record({
    required this.v,
    required this.id,
    required this.partnership,
    required this.author,
    required this.seq,
    required this.prevHash,
    required this.type,
    required this.body,
    required this.refersTo,
    required this.note,
    required this.time,
    required this.sig,
  });

  factory Record.fromJson(Map<String, dynamic> json) {
    return Record(
      v: json['v'] as int,
      id: json['id'] as String,
      partnership: json['partnership'] as String,
      author: json['author'] as String,
      seq: json['seq'] as int,
      prevHash: json['prevHash'] as String,
      type: json['type'] as String,
      body: json['body'] as Map<String, dynamic>,
      refersTo: json['refersTo'] as String?,
      note: json['note'] as String,
      time: json['time'] as String,
      sig: json['sig'] as String,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'v': v,
      'id': id,
      'partnership': partnership,
      'author': author,
      'seq': seq,
      'prevHash': prevHash,
      'type': type,
      'body': body,
      'refersTo': refersTo,
      'note': note,
      'time': time,
      'sig': sig,
    };
  }
}
