import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/capture_mode.dart';

enum CameraLensType {
  uw('uw', 0),
  main('main', 1),
  tele('tele', 2);

  const CameraLensType(this.exportName, this.cameraIndex);

  final String exportName;
  final int cameraIndex;

  static CameraLensType fromExportName(String name) {
    for (final lens in values) {
      if (lens.exportName == name) return lens;
    }
    return CameraLensType.main;
  }
}

enum CoverageBinColor {
  gray,
  red,
  orange,
  blue,
  green,
  purple,
}

class CoverageBin {
  const CoverageBin({
    required this.id,
    required this.azimuthIndex,
    required this.elevationBand,
    this.uwCount = 0,
    this.mainCount = 0,
    this.teleCount = 0,
    this.attempts = 0,
    this.bestSharpness = 0,
    this.bestTexture = 0,
  });

  final String id;
  final int azimuthIndex;
  final String elevationBand;
  final int uwCount;
  final int mainCount;
  final int teleCount;
  final int attempts;
  final double bestSharpness;
  final double bestTexture;

  CoverageBinColor get color {
    if (teleCount >= 2) return CoverageBinColor.purple;
    if (mainCount >= 2) return CoverageBinColor.green;
    if (uwCount >= 1 && mainCount == 0) return CoverageBinColor.blue;
    if (mainCount == 1) return CoverageBinColor.orange;
    if (attempts > 0) return CoverageBinColor.red;
    return CoverageBinColor.gray;
  }

  bool get isQualityCovered =>
      color == CoverageBinColor.green || color == CoverageBinColor.purple;

  CoverageBin copyWithFrame({
    required CameraLensType camera,
    required bool qualityAccepted,
    required double sharpness,
    required double textureScore,
  }) {
    final accepted = qualityAccepted ? 1 : 0;
    return CoverageBin(
      id: id,
      azimuthIndex: azimuthIndex,
      elevationBand: elevationBand,
      uwCount: uwCount + (camera == CameraLensType.uw ? accepted : 0),
      mainCount: mainCount + (camera == CameraLensType.main ? accepted : 0),
      teleCount: teleCount + (camera == CameraLensType.tele ? accepted : 0),
      attempts: attempts + 1,
      bestSharpness: math.max(bestSharpness, sharpness),
      bestTexture: math.max(bestTexture, textureScore),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'azimuth_bin': azimuthIndex,
        'elevation_band': elevationBand,
        'uw_count': uwCount,
        'main_count': mainCount,
        'tele_count': teleCount,
        'attempts': attempts,
        'best_sharpness': bestSharpness,
        'best_texture_score': bestTexture,
        'state': color.name,
      };
}

class CoverageState {
  CoverageState({
    required this.bins,
    required this.coveragePercent,
    required this.ceilingPercent,
    required this.floorPercent,
    required this.perCameraCoverage,
  });

  final Map<String, CoverageBin> bins;
  final double coveragePercent;
  final double ceilingPercent;
  final double floorPercent;
  final Map<String, double> perCameraCoverage;

  List<CoverageBin> get azimuthBins =>
      List<CoverageBin>.generate(CoverageTracker.azimuthBins, (i) {
        return bins[CoverageTracker.roomBinId(i, 'level')] ??
            CoverageTracker.emptyRoomBin(i, 'level');
      }, growable: false);

  Map<String, dynamic> toJson() => {
        'coverage_percent': coveragePercent,
        'ceiling_percent': ceilingPercent,
        'floor_percent': floorPercent,
        'per_camera_coverage': perCameraCoverage,
        'bins': bins.map((key, value) => MapEntry(key, value.toJson())),
      };

  static CoverageState empty() => CoverageState(
        bins: const {},
        coveragePercent: 0,
        ceilingPercent: 0,
        floorPercent: 0,
        perCameraCoverage: const {'uw': 0, 'main': 0, 'tele': 0},
      );
}

class CoverageTracker extends StateNotifier<CoverageState> {
  CoverageTracker() : super(CoverageState.empty()) {
    _emit();
  }

  static const int azimuthBins = 36;
  static const int objectElevationBins = 12;

  final _stream = StreamController<CoverageState>.broadcast();
  final Map<String, CoverageBin> _bins = <String, CoverageBin>{};

  CoverageState get value => state;

  @override
  Stream<CoverageState> get stream => _stream.stream;

  static String roomBinId(int azimuthIndex, String band) =>
      'room_${band}_$azimuthIndex';

  static CoverageBin emptyRoomBin(int azimuthIndex, String band) => CoverageBin(
        id: roomBinId(azimuthIndex, band),
        azimuthIndex: azimuthIndex,
        elevationBand: band,
      );

  void reset() {
    _bins.clear();
    _emit();
  }

  void recordFrame({
    required CaptureMode mode,
    required CameraLensType camera,
    required double azimuthDeg,
    required double elevationDeg,
    required double sharpness,
    required double textureScore,
    required bool qualityAccepted,
  }) {
    final ids = binIdsFor(
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    );
    for (final id in ids) {
      final bin = _bins[id] ?? _emptyBinForId(id);
      _bins[id] = bin.copyWithFrame(
        camera: camera,
        qualityAccepted: qualityAccepted,
        sharpness: sharpness,
        textureScore: textureScore,
      );
    }
    _emit();
  }

  List<String> binIdsFor({
    required CaptureMode mode,
    required double azimuthDeg,
    required double elevationDeg,
  }) {
    final az = azimuthIndex(azimuthDeg);
    if (mode == CaptureMode.object) {
      final elev = (((elevationDeg.clamp(-89.999, 89.999) + 90) / 15).floor())
          .clamp(0, objectElevationBins - 1);
      return ['object_${az}_$elev'];
    }

    final band = roomElevationBand(elevationDeg);
    return [roomBinId(az, band)];
  }

  CoverageBin binAt({
    required CaptureMode mode,
    required double azimuthDeg,
    required double elevationDeg,
  }) {
    final id = binIdsFor(
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    ).first;
    return _bins[id] ?? _emptyBinForId(id);
  }

  int nearestUncoveredAzimuth({
    required double azimuthDeg,
    String band = 'level',
  }) {
    final current = azimuthIndex(azimuthDeg);
    for (var offset = 0; offset < azimuthBins ~/ 2; offset++) {
      final right = (current + offset) % azimuthBins;
      final left = (current - offset + azimuthBins) % azimuthBins;
      if (!(_bins[roomBinId(right, band)] ?? emptyRoomBin(right, band))
          .isQualityCovered) {
        return right;
      }
      if (!(_bins[roomBinId(left, band)] ?? emptyRoomBin(left, band))
          .isQualityCovered) {
        return left;
      }
    }
    return current;
  }

  bool needsBasic(double azimuthDeg, double elevationDeg, CaptureMode mode) {
    final bin = binAt(
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    );
    return bin.mainCount == 0 && bin.teleCount == 0;
  }

  bool needsQuality(double azimuthDeg, double elevationDeg, CaptureMode mode) {
    final bin = binAt(
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    );
    return bin.color != CoverageBinColor.green &&
        bin.color != CoverageBinColor.purple;
  }

  bool needsDetail(double azimuthDeg, double elevationDeg, CaptureMode mode) {
    final bin = binAt(
      mode: mode,
      azimuthDeg: azimuthDeg,
      elevationDeg: elevationDeg,
    );
    return bin.bestTexture < 0.3 && bin.teleCount < 2;
  }

  static int azimuthIndex(double degrees) {
    var yaw = degrees % 360.0;
    if (yaw < 0) yaw += 360.0;
    return (yaw / 10).floor().clamp(0, azimuthBins - 1);
  }

  static String roomElevationBand(double elevationDeg) {
    if (elevationDeg > 60) return 'ceiling';
    if (elevationDeg < -60) return 'floor';
    if (elevationDeg > 15) return 'up';
    if (elevationDeg < -15) return 'down';
    return 'level';
  }

  CoverageBin _emptyBinForId(String id) {
    final parts = id.split('_');
    if (id.startsWith('room_')) {
      final az = int.tryParse(parts.last) ?? 0;
      final band = parts.length >= 3 ? parts[1] : 'level';
      return emptyRoomBin(az, band);
    }
    final az = parts.length >= 2 ? int.tryParse(parts[1]) ?? 0 : 0;
    return CoverageBin(id: id, azimuthIndex: az, elevationBand: 'object');
  }

  void _emit() {
    final coverage = _percentWhere((b) => b.isQualityCovered, 'level');
    final ceiling = _percentWhere((b) => b.isQualityCovered, 'ceiling');
    final floor = _percentWhere((b) => b.isQualityCovered, 'floor');
    final perCamera = {
      'uw': _percentWhere((b) => b.uwCount > 0, 'level'),
      'main': _percentWhere((b) => b.mainCount > 0, 'level'),
      'tele': _percentWhere((b) => b.teleCount > 0, 'level'),
    };
    state = CoverageState(
      bins: Map.unmodifiable(_bins),
      coveragePercent: coverage,
      ceilingPercent: ceiling,
      floorPercent: floor,
      perCameraCoverage: perCamera,
    );
    if (!_stream.isClosed) _stream.add(state);
  }

  double _percentWhere(bool Function(CoverageBin bin) test, String band) {
    var covered = 0;
    for (var i = 0; i < azimuthBins; i++) {
      final bin = _bins[roomBinId(i, band)] ?? emptyRoomBin(i, band);
      if (test(bin)) covered++;
    }
    return covered / azimuthBins * 100.0;
  }

  @override
  void dispose() {
    _stream.close();
    super.dispose();
  }
}

final coverageTrackerProvider =
    StateNotifierProvider<CoverageTracker, CoverageState>(
  (ref) => CoverageTracker(),
);
