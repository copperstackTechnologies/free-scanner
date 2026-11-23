class ScanDoc {
  String id;
  String name;
  DateTime created;
  List<String> pages; // file names inside the document folder, in order
  String ocrText;

  ScanDoc({
    required this.id,
    required this.name,
    required this.created,
    required this.pages,
    this.ocrText = '',
  });

  factory ScanDoc.fromJson(Map<String, dynamic> j) => ScanDoc(
        id: j['id'] as String,
        name: j['name'] as String,
        created: DateTime.parse(j['created'] as String),
        pages: List<String>.from(j['pages'] as List),
        ocrText: (j['ocrText'] as String?) ?? '',
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'created': created.toIso8601String(),
        'pages': pages,
        'ocrText': ocrText,
      };
}
