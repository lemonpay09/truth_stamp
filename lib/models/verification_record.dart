class VerificationRecord {
  const VerificationRecord({
    required this.hash,
    required this.timestamp,
    required this.latitude,
    required this.longitude,
    required this.accuracy,
    required this.createdAt,
    required this.verifyUrl,
    required this.imagePath,
    required this.recordType,
    this.thumbnailBase64,
    this.heatmapBase64,
    this.maskBase64,
    this.metadataScore,
    this.aiScore,
    this.forgeryScore,
    this.conclusion,
  });

  final String hash;
  final String timestamp;
  final String latitude;
  final String longitude;
  final String accuracy;
  final String createdAt;
  final String verifyUrl;
  final String imagePath;
  final String recordType; // detect | verify
  final String? thumbnailBase64;
  final String? heatmapBase64;
  final String? maskBase64;
  final String? metadataScore;
  final String? aiScore;
  final String? forgeryScore;
  final String? conclusion;

  String get shortHash {
    if (hash.length <= 12) return hash;
    return '${hash.substring(0, 8)}…${hash.substring(hash.length - 4)}';
  }

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'hash': hash,
      'timestamp': timestamp,
      'latitude': latitude,
      'longitude': longitude,
      'accuracy': accuracy,
      'createdAt': createdAt,
      'verifyUrl': verifyUrl,
      'imagePath': imagePath,
      'recordType': recordType,
      'thumbnailBase64': thumbnailBase64,
      'heatmapBase64': heatmapBase64,
      'maskBase64': maskBase64,
      'metadataScore': metadataScore,
      'aiScore': aiScore,
      'forgeryScore': forgeryScore,
      'conclusion': conclusion,
    };
  }

  factory VerificationRecord.fromJson(Map<String, dynamic> json) {
    return VerificationRecord(
      hash: json['hash']?.toString() ?? '',
      timestamp: json['timestamp']?.toString() ?? '',
      latitude: json['latitude']?.toString() ?? '',
      longitude: json['longitude']?.toString() ?? '',
      accuracy: json['accuracy']?.toString() ?? '',
      createdAt: json['createdAt']?.toString() ?? '',
      verifyUrl: json['verifyUrl']?.toString() ?? '',
      imagePath: json['imagePath']?.toString() ?? '',
      recordType: json['recordType']?.toString() ?? 'verify',
      thumbnailBase64: json['thumbnailBase64']?.toString(),
      heatmapBase64: json['heatmapBase64']?.toString(),
      maskBase64: json['maskBase64']?.toString(),
      metadataScore: json['metadataScore']?.toString(),
      aiScore: json['aiScore']?.toString(),
      forgeryScore: json['forgeryScore']?.toString(),
      conclusion: json['conclusion']?.toString(),
    );
  }
}
