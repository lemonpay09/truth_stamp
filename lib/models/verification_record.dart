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
  });

  final String hash;
  final String timestamp;
  final String latitude;
  final String longitude;
  final String accuracy;
  final String createdAt;
  final String verifyUrl;
  final String imagePath;

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
    );
  }
}
