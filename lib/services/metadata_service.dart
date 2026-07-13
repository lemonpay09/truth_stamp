import 'dart:async';

import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';

class MetadataService {
  const MetadataService();

  Future<void> ensureLocationPermission() async {
    final locationEnabled = await Geolocator.isLocationServiceEnabled();
    if (!locationEnabled) {
      throw const LocationServiceDisabledException();
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }

    if (permission == LocationPermission.denied) {
      throw const PermissionDeniedException(
        'Location permission was denied.',
      );
    }

    if (permission == LocationPermission.deniedForever) {
      throw const PermissionDeniedException(
        'Location permission is permanently denied.',
      );
    }
  }

  Future<Map<String, dynamic>> collectMetadata() async {
    await ensureLocationPermission();

    try {
      final position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      final timestamp = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

      return <String, dynamic>{
        'timestamp': timestamp,
        'latitude': position.latitude,
        'longitude': position.longitude,
        'accuracy': position.accuracy,
      };
    } on TimeoutException catch (error) {
      throw Exception('Fetching location timed out: ${error.message ?? error.toString()}');
    } on PermissionDeniedException catch (error) {
      throw Exception('Unable to fetch location: ${error.message ?? error.toString()}');
    } on LocationServiceDisabledException catch (error) {
      throw Exception('Unable to fetch location: ${error.toString()}');
    } on Exception catch (error) {
      throw Exception('Unable to collect metadata: $error');
    }
  }
}
