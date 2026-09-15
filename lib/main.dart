import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bluetooth_serial/flutter_bluetooth_serial.dart';
import 'package:flutter_mjpeg/flutter_mjpeg.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:video_player/video_player.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:http/http.dart' as http;

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  runApp(const AdasApp());
}

class AdasApp extends StatelessWidget {
  const AdasApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GEAR HEADS ADAS',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF030509),
      ),
      home: const VideoIntroGate(),
    );
  }
}

// ============================================================================
// 1. INTRO VIDEO GATEWAY
// ============================================================================
class VideoIntroGate extends StatefulWidget {
  const VideoIntroGate({super.key});

  @override
  State<VideoIntroGate> createState() => _VideoIntroGateState();
}

class _VideoIntroGateState extends State<VideoIntroGate> {
  late VideoPlayerController _videoCtrl;
  bool _isInitialized = false;
  bool _navigated = false;
  Timer? _failSafe;

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _failSafe = Timer(const Duration(milliseconds: 8200), _goToCockpit);
    _playVideo();
  }

  Future<void> _playVideo() async {
    _videoCtrl = VideoPlayerController.asset(
      'assets/intro_video.mp4',
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );

    try {
      await _videoCtrl.initialize();
      await _videoCtrl.setVolume(1.0);
      await _videoCtrl.play();

      if (mounted) setState(() => _isInitialized = true);

      _videoCtrl.addListener(() {
        if (_videoCtrl.value.isInitialized &&
            !_navigated &&
            _videoCtrl.value.position >= _videoCtrl.value.duration) {
          _goToCockpit();
        }
      });
    } catch (e) {
      debugPrint("Video bypass: $e");
      _goToCockpit();
    }
  }

  void _goToCockpit() {
    if (_navigated) return;
    _navigated = true;
    _failSafe?.cancel();

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, anim, __) => const ExactScreenshotDashboard(),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
      ),
    );
  }

  @override
  void dispose() {
    _failSafe?.cancel();
    _videoCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: SizedBox.expand(
        child: _isInitialized
            ? FittedBox(
                fit: BoxFit.cover,
                child: SizedBox(
                  width: _videoCtrl.value.size.width,
                  height: _videoCtrl.value.size.height,
                  child: VideoPlayer(_videoCtrl),
                ),
              )
            : const Center(
                child: CircularProgressIndicator(color: Color(0xFF00E5FF), strokeWidth: 2.0),
              ),
      ),
    );
  }
}

// ============================================================================
// 2. SIMULATED VEHICLE (SINGLE SOURCE OF TRUTH)
// ============================================================================
class SimVehicle {
  final String id;
  final String label;
  final int lane;
  double distanceMeters;
  final double baseSpeedKmh;
  final Color bodyColor;

  SimVehicle({
    required this.id,
    required this.label,
    required this.lane,
    required this.distanceMeters,
    required this.baseSpeedKmh,
    required this.bodyColor,
  });
}

// ============================================================================
// 3. PERSISTENT SINGLETON MUSIC SERVICE (TRULY INDEPENDENT OF DRIVING MODES)
// ============================================================================
class AdasMusicService extends ChangeNotifier {
  static final AdasMusicService _instance = AdasMusicService._internal();
  factory AdasMusicService() => _instance;

  final AudioPlayer _audioPlayer = AudioPlayer();
  PlayerState _playerState = PlayerState.stopped;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;
  double _volume = 0.8;
  int _currentIndex = 0;
  double _beatIntensity = 0.0;

  final List<SongInfo> playlist = [
    SongInfo(
      title: 'Midnight Drive',
      artist: 'ADAS Sound System',
      assetPath: 'Music/track 1.mp3',
    ),
  ];

  AudioPlayer get player => _audioPlayer;
  PlayerState get playerState => _playerState;
  Duration get duration => _duration;
  Duration get position => _position;
  double get volume => _volume;
  int get currentIndex => _currentIndex;
  double get beatIntensity => _beatIntensity;
  SongInfo get currentSong => playlist[_currentIndex];

  AdasMusicService._internal() {
    _init();
  }

  Future<void> _init() async {
    await _audioPlayer.setReleaseMode(ReleaseMode.loop);

    _audioPlayer.onPlayerStateChanged.listen((state) {
      _playerState = state;
      notifyListeners();
    });

    _audioPlayer.onDurationChanged.listen((d) {
      _duration = d;
      notifyListeners();
    });

    _audioPlayer.onPositionChanged.listen((p) {
      _position = p;
      double millis = p.inMilliseconds.toDouble();
      double rawBeat = (millis % 420) / 420.0;
      double sharpBeat = math.pow(1.0 - (rawBeat - 0.5).abs() * 2.0, 4.0).toDouble();
      _beatIntensity = 0.15 + (sharpBeat * 0.85);
      notifyListeners();
    });

    _audioPlayer.onPlayerComplete.listen((_) {
      nextTrack();
    });

    try {
      await _audioPlayer.setSource(AssetSource(currentSong.assetPath));
      await _audioPlayer.setVolume(_volume);
    } catch (e) {
      debugPrint("Music service source init error: $e");
    }
  }

  Future<void> togglePlay() async {
    if (_playerState == PlayerState.playing) {
      await _audioPlayer.pause();
    } else {
      if (_playerState != PlayerState.paused) {
        await _audioPlayer.setSource(AssetSource(currentSong.assetPath));
      }
      await _audioPlayer.resume();
    }
  }

  Future<void> nextTrack() async {
    _currentIndex = (_currentIndex + 1) % playlist.length;
    await _audioPlayer.setSource(AssetSource(currentSong.assetPath));
    await _audioPlayer.resume();
    notifyListeners();
  }

  Future<void> prevTrack() async {
    _currentIndex = (_currentIndex - 1 + playlist.length) % playlist.length;
    await _audioPlayer.setSource(AssetSource(currentSong.assetPath));
    await _audioPlayer.resume();
    notifyListeners();
  }

  Future<void> seek(Duration pos) async {
    await _audioPlayer.seek(pos);
  }

  Future<void> setVolume(double vol) async {
    _volume = vol.clamp(0.0, 1.0);
    await _audioPlayer.setVolume(_volume);
    notifyListeners();
  }
}

// ============================================================================
// 4. REUSABLE ILLUMINATED INNER-EDGE NEON CARD (STEERING-WHEEL CONTOUR STYLE)
// ============================================================================
class AdasNeonCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final Color? customGlowColor;
  final double beatIntensity;
  final bool isPlaying;

  const AdasNeonCard({
    Key? key,
    required this.child,
    this.padding,
    this.margin,
    this.borderRadius = 16,
    this.customGlowColor,
    this.beatIntensity = 0.0,
    this.isPlaying = false,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    Color baseColor = customGlowColor ?? const Color(0xFF00E5FF);
    List<Color> neonPalette = [
      const Color(0xFF00E5FF), // Cyan
      const Color(0xFF2979FF), // Blue
      const Color(0xFF7C4DFF), // Purple
      const Color(0xFFE040FB), // Magenta
    ];
    Color activeGlow = isPlaying ? neonPalette[(DateTime.now().millisecondsSinceEpoch ~/ 1200) % neonPalette.length] : baseColor;

    return Container(
      margin: margin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: [
          BoxShadow(
            color: activeGlow.withOpacity(isPlaying ? 0.3 + (beatIntensity * 0.45) : 0.15),
            blurRadius: isPlaying ? 10 + (beatIntensity * 12) : 6,
            spreadRadius: isPlaying ? 1.2 + (beatIntensity * 2.0) : 0.5,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: const Color(0xFF070D18),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: activeGlow.withOpacity(isPlaying ? 0.75 + (beatIntensity * 0.25) : 0.4),
              width: 1.6,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

// ============================================================================
// 5. PREMIUM SPOTIFY-INSPIRED HORIZONTAL MUSIC PLAYER WIDGET
// ============================================================================
class SongInfo {
  final String title;
  final String artist;
  final String assetPath;

  SongInfo({required this.title, required this.artist, required this.assetPath});
}

class SpotifyMusicPlayerWidget extends StatelessWidget {
  final AdasMusicService musicService;
  final Color activeColor;

  const SpotifyMusicPlayerWidget({
    Key? key,
    required this.musicService,
    required this.activeColor,
  }) : super(key: key);

  String _formatDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    String twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    String twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return "$twoDigitMinutes:$twoDigitSeconds";
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: musicService,
      builder: (context, _) {
        bool isPlaying = musicService.playerState == PlayerState.playing;
        SongInfo currentSong = musicService.currentSong;
        double beat = musicService.beatIntensity;

        return AdasNeonCard(
          isPlaying: isPlaying,
          beatIntensity: beat,
          borderRadius: 16,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: const BoxDecoration(
                      image: DecorationImage(
                        image: NetworkImage('https://images.unsplash.com/photo-1511671782779-c97d3d27a1d4?w=150'),
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        currentSong.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 10.5,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        currentSong.artist,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 8,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.skip_previous, color: Colors.white70, size: 18),
                            onPressed: () => musicService.prevTrack(),
                          ),
                          const SizedBox(width: 10),
                          CircleAvatar(
                            radius: 14,
                            backgroundColor: Colors.white,
                            child: IconButton(
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(),
                              icon: Icon(
                                isPlaying ? Icons.pause : Icons.play_arrow,
                                color: Colors.black,
                                size: 15,
                              ),
                              onPressed: () => musicService.togglePlay(),
                            ),
                          ),
                          const SizedBox(width: 10),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(),
                            icon: const Icon(Icons.skip_next, color: Colors.white70, size: 18),
                            onPressed: () => musicService.nextTrack(),
                          ),
                          const SizedBox(width: 10),
                          SizedBox(
                            width: 24,
                            height: 12,
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: List.generate(3, (i) {
                                double h = isPlaying ? (3.5 + (beat * (6.0 + (i * 2))) % 9.0) : 3.0;
                                return Container(
                                  width: 2.2,
                                  height: h,
                                  decoration: BoxDecoration(
                                    color: i == 0 ? Colors.cyanAccent : (i == 1 ? Colors.purpleAccent : Colors.pinkAccent),
                                    borderRadius: BorderRadius.circular(1),
                                  ),
                                );
                              }),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Row(
                        children: [
                          Text(
                            _formatDuration(musicService.position),
                            style: const TextStyle(color: Colors.white54, fontSize: 7),
                          ),
                          const SizedBox(width: 4),
                          Expanded(
                            child: SliderTheme(
                              data: SliderThemeData(
                                trackHeight: 1.8,
                                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 3),
                                activeTrackColor: Colors.purpleAccent,
                                inactiveTrackColor: Colors.white24,
                                thumbColor: Colors.white,
                              ),
                              child: Slider(
                                value: musicService.position.inMilliseconds.toDouble().clamp(0.0, musicService.duration.inMilliseconds.toDouble() > 0 ? musicService.duration.inMilliseconds.toDouble() : 1.0),
                                min: 0.0,
                                max: musicService.duration.inMilliseconds.toDouble() > 0 ? musicService.duration.inMilliseconds.toDouble() : 1.0,
                                onChanged: (value) async {
                                  await musicService.seek(Duration(milliseconds: value.toInt()));
                                },
                              ),
                            ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _formatDuration(musicService.duration),
                            style: const TextStyle(color: Colors.white54, fontSize: 7),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ============================================================================
// 6. MAIN DASHBOARD CONTROLLER
// ============================================================================
class ExactScreenshotDashboard extends StatefulWidget {
  const ExactScreenshotDashboard({super.key});

  @override
  State<ExactScreenshotDashboard> createState() => _ExactScreenshotDashboardState();
}

class _ExactScreenshotDashboardState extends State<ExactScreenshotDashboard>
    with TickerProviderStateMixin {
  BluetoothConnection? _connection;
  bool _isConnected = true;
  bool _isConnecting = false;
  List<BluetoothDevice> _devicesList = [];

  double _batteryVoltage = 7.5;
  int _batteryPercent = 75;
  int _hardwareSpeed = 0;
  String _selectedGear = "D";

  bool _adasEnabled = true;
  bool _accEnabled = false;
  String _driveMode = "NORMAL";
  String _drivetrainMode = "FWD";

  bool _normalLightsOn = true;
  bool _highBeamOn = true;
  bool _isMusicMode = false;      

  int _selectedPovIndex = 1;
  late AnimationController _povTransitionController;

  bool _isHonking = false;
  bool _isGasPressed = false;
  bool _isBrakePressed = false;
  bool _autoBrakeTriggered = false;

  final String _streamUrl = "http://192.168.4.1:81/stream";
  Key _mjpegKey = UniqueKey();
  bool _isRealCameraOnline = false;
  String _receivedBuffer = '';
  final List<String> _diagLogs = [];

  String _weatherText = "27°C Clear";
  String _locationArea = "Solapur";

  static const double _maxSteeringAngle = 180.0;
  double _steeringAngleDeg = 0.0;
  double _steeringVelocity = 0.0;
  bool _isUserHoldingWheel = false;
  int _lastSentServoAngle = 88;
  double _ultrasonicDistanceCm = 50.0;

  double _adasAnimProgress = 1.0;
  double _accSetSpeedKmh = 80.0;
  String _accStatusText = "ACC STANDBY";
  double _accTargetDistMeters = 0.0;
  String _accFollowingStatus = "SAFE";

  late Timer _clockTimer;
  DateTime _currentTime = DateTime.now();

  late AnimationController _transitionController;
  late AnimationController _drivetrainWarpController;
  String _transitionTitle = "NORMAL";
  String _transitionSubtitle = "STANDARD CRUISING EFFICIENCY";
  Color _transitionColor = const Color(0xFF00E5FF);
  Offset _transitionOrigin = const Offset(560, 26);
  bool _isTransitionForward = true;

  final GlobalKey _adasBtnKey = GlobalKey();
  final GlobalKey _accBtnKey = GlobalKey();
  final GlobalKey _modeBtnKey = GlobalKey();
  final GlobalKey _drivetrainBtnKey = GlobalKey();

  late Ticker _worldPhysicsTicker;
  Duration _lastTickTime = Duration.zero;
  double _virtualDistanceTraveled = 0.0;
  double _virtualVelocityKmh = 0.0;
  double _motorRpm = 0.0;
  double _pedalThrottleRatio = 0.0;
  double _pedalBrakeRatio = 0.0;
  double _displayedVelocity = 0.0;
  double _chassisPitchOffset = 0.0;

  final List<SimVehicle> _trafficList = [
    SimVehicle(id: "v_front", label: "Vehicle (Front)", lane: 0, distanceMeters: 12.4, baseSpeedKmh: 45.0, bodyColor: const Color(0xFFC5C9CF)),
    SimVehicle(id: "v_left", label: "Vehicle (Left)", lane: -1, distanceMeters: 8.6, baseSpeedKmh: 42.0, bodyColor: const Color(0xFFE0E0E0)),
    SimVehicle(id: "v_right", label: "Vehicle (Right)", lane: 1, distanceMeters: 15.6, baseSpeedKmh: 48.0, bodyColor: const Color(0xFF1E293B)),
    SimVehicle(id: "v_center_far", label: "Vehicle (Front)", lane: 0, distanceMeters: 28.7, baseSpeedKmh: 44.0, bodyColor: const Color(0xFF1B4D3E)),
  ];

  late AdasMusicService _musicService;
  late AudioPlayer _modeSoundPlayer;
  late AudioPlayer _uiSoundPlayer;
  late AudioPlayer _hornSoundPlayer;
  late AudioPlayer _powertrainPlayer;
  late AudioPlayer _decelerationPlayer;
  bool _engineAudioReady = false;
  bool _engineAudioBusy = false;
  String _activePowertrainState = 'idle';

  DateTime _lastAudioUpdate = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _musicService = AdasMusicService();
    _musicService.addListener(_onMusicStateChanged);

    _initExclusiveAudio();
    _fetchLiveLocationAndWeather();

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) setState(() => _currentTime = DateTime.now());
    });

    _transitionController = AnimationController(vsync: this);
    _drivetrainWarpController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );

    _povTransitionController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: 1.0,
    );

    _worldPhysicsTicker = createTicker((elapsed) {
      if (_lastTickTime == Duration.zero) {
        _lastTickTime = elapsed;
        return;
      }
      double dt = (elapsed - _lastTickTime).inMicroseconds / 1000000.0;
      _lastTickTime = elapsed;
      if (dt > 0.05) dt = 0.05;

      _updateTrueCarPhysics(dt);
      _updateSteeringDynamics(dt);
    })..start();

    _initPermissionsAndBluetooth();
  }

  void _onMusicStateChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initExclusiveAudio() async {
    _modeSoundPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _uiSoundPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _hornSoundPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.stop);
    _powertrainPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.loop);
    _decelerationPlayer = AudioPlayer()..setReleaseMode(ReleaseMode.loop);

    try {
      await _powertrainPlayer.setVolume(0.10);
      await _powertrainPlayer.play(AssetSource('sounds/engine_acceleration'));
      _engineAudioReady = true;
    } catch (e) {
      debugPrint('ENGINE AUDIO INIT ERROR: $e');
      _engineAudioReady = false;
    }
  }

  Future<void> _playSynchronizedTransition({
    required String audioFileName,
    required Duration duration,
    required VoidCallback onUpdateState,
    Offset? origin,
    String? title,
    String? subtitle,
    Color? color,
    bool isForward = true,
  }) async {
    await _modeSoundPlayer.stop();

    bool wasPlaying = _musicService.playerState == PlayerState.playing;
    if (wasPlaying) {
      await _musicService.setVolume(0.2); // Smooth volume ducking during mode change
    }

    if (origin != null) {
      setState(() {
        _transitionOrigin = origin;
        if (title != null) _transitionTitle = title;
        if (subtitle != null) _transitionSubtitle = subtitle;
        if (color != null) _transitionColor = color;
        _isTransitionForward = isForward;
        onUpdateState();
      });
    } else {
      setState(onUpdateState);
    }

    _transitionController.duration = duration;
    _transitionController.forward(from: 0.0);

    try {
      await _modeSoundPlayer.play(AssetSource('updated sound effects/$audioFileName'), volume: 0.85);
    } catch (e) {
      debugPrint('SYNCHRONIZED AUDIO ERROR: Could not play $audioFileName -> $e');
    }

    Future.delayed(duration, () async {
      if (mounted && wasPlaying && _musicService.playerState == PlayerState.playing) {
        await _musicService.setVolume(0.8);
      }
    });
  }

  Future<void> _safePlayUiOneShot(String fileName, {double volume = 0.60}) async {
    try {
      await _uiSoundPlayer.stop();
      await _uiSoundPlayer.play(AssetSource('updated sound effects/$fileName'), volume: volume);
    } catch (e) {
      debugPrint('UI AUDIO ERROR: Could not play $fileName -> $e');
    }
  }

  Future<void> _playHornSound() async {
    try {
      await _hornSoundPlayer.stop();
      await _hornSoundPlayer.play(AssetSource('updated sound effects/horn.mp3'), volume: 0.85);
    } catch (_) {
      try {
        await _hornSoundPlayer.play(AssetSource('sounds/horn'), volume: 0.85);
      } catch (e) {
        debugPrint('HORN AUDIO ERROR: $e');
      }
    }
  }

  Future<void> _updateEngineAudio() async {
    if (!_engineAudioReady || _engineAudioBusy) return;

    final now = DateTime.now();
    if (now.difference(_lastAudioUpdate).inMilliseconds < 80) return;
    _lastAudioUpdate = now;
    _engineAudioBusy = true;

    try {
      final double speed = _virtualVelocityKmh.abs();
      final bool braking = _pedalBrakeRatio > 0.05;
      final bool accelerating = _pedalThrottleRatio > 0.05 && !braking && _selectedGear != 'N';

      String state;
      if (speed < 0.8) {
        state = 'idle';
      } else if (accelerating) {
        state = 'accel';
      } else if (speed > 1.5) {
        state = 'decel';
      } else {
        state = 'idle';
      }

      if (state != _activePowertrainState) {
        _activePowertrainState = state;
        try {
          if (state == 'decel') {
            await _powertrainPlayer.setVolume(0.0);
            await _decelerationPlayer.stop();
            try {
              await _decelerationPlayer.play(AssetSource('sounds/engine_deceleration'));
            } catch (_) {
              await _decelerationPlayer.play(AssetSource('sounds/engine_acceleration'));
            }
          } else {
            await _decelerationPlayer.setVolume(0.0);
            await _decelerationPlayer.stop();
            if (state != 'idle') {
              await _powertrainPlayer.resume();
            }
          }
        } catch (e) {
          debugPrint('ENGINE STATE ERROR: $e');
        }
      }

      final double topSpeed = _selectedGear == 'R'
          ? 38.0
          : (_driveMode == 'SPORT' ? 160.0 : (_driveMode == 'ECO' ? 75.0 : 115.0));
      final double speedRatio = (speed / topSpeed).clamp(0.0, 1.0);
      final double load = math.max(speedRatio * 0.72, _pedalThrottleRatio);

      if (state == 'idle') {
        await _powertrainPlayer.setPlaybackRate(0.82);
        await _powertrainPlayer.setVolume(0.12);
        await _decelerationPlayer.setVolume(0.0);
      } else if (state == 'accel') {
        final double pitch = (0.82 + load * 0.95).clamp(0.82, 1.80);
        final double volume = (0.20 + load * 0.55).clamp(0.20, 0.82);
        await _powertrainPlayer.setPlaybackRate(pitch);
        await _powertrainPlayer.setVolume(volume);
        await _decelerationPlayer.setVolume(0.0);
      } else {
        final double pitch = (0.78 + speedRatio * 0.55).clamp(0.78, 1.35);
        final double volume = (0.12 + speedRatio * 0.25).clamp(0.12, 0.38);
        await _decelerationPlayer.setPlaybackRate(pitch);
        await _decelerationPlayer.setVolume(volume);
        await _powertrainPlayer.setVolume(0.0);
      }
    } catch (e) {
      debugPrint('ENGINE AUDIO UPDATE ERROR: $e');
    } finally {
      _engineAudioBusy = false;
    }
  }

  Future<void> _fetchLiveLocationAndWeather() async {
    try {
      await Permission.location.request();
      double lat = 17.6599;
      double lon = 75.9064;

      final url = Uri.parse(
        'https://api.open-meteo.com/v1/forecast?latitude=$lat&longitude=$lon&current=temperature_2m,weather_code',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 4));
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final temp = data['current']['temperature_2m'];
        final code = data['current']['weather_code'];
        String condition = "Clear";
        if (code > 3 && code <= 48) condition = "Haze";
        if (code > 48 && code <= 67) condition = "Rain";
        if (code > 67) condition = "Thunderstorm";

        if (mounted) {
          setState(() {
            _weatherText = "${temp.round()}°C $condition";
            _locationArea = "Solapur";
          });
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _weatherText = "28°C Clear";
          _locationArea = "Solapur";
        });
      }
    }
  }

  void _updateTrueCarPhysics(double dt) {
    double targetAdasProg = _adasEnabled ? 1.0 : 0.0;
    _adasAnimProgress += (targetAdasProg - _adasAnimProgress) * (dt * 5.0);

    bool brakeActive = _isBrakePressed || _autoBrakeTriggered;
    double maxRpm = _driveMode == "SPORT" ? 7000.0 : (_driveMode == "ECO" ? 4000.0 : 5500.0);
    double topForwardKmh = _driveMode == "SPORT" ? 160.0 : (_driveMode == "ECO" ? 75.0 : 115.0);
    double topReverseKmh = 38.0;

    double targetSpeedKmh = topForwardKmh;

    if (_adasEnabled && _ultrasonicDistanceCm > 0 && _ultrasonicDistanceCm < 15.0) {
      brakeActive = true;
    }

    if (_accEnabled && _selectedGear == "D") {
      SimVehicle? leadVehicle;
      for (var v in _trafficList) {
        if (v.lane == 0 && v.distanceMeters > 0 && v.distanceMeters < 90.0) {
          if (leadVehicle == null || v.distanceMeters < leadVehicle.distanceMeters) {
            leadVehicle = v;
          }
        }
      }

      if (leadVehicle != null) {
        _accTargetDistMeters = leadVehicle.distanceMeters;
        double safeFollowingDist = 5.0 + (_virtualVelocityKmh / 3.6) * 1.5;

        if (_accTargetDistMeters < 4.0) {
          _accFollowingStatus = "CAUTION";
        } else if (_accTargetDistMeters < safeFollowingDist) {
          _accFollowingStatus = "WARNING";
        } else {
          _accFollowingStatus = "SAFE";
        }

        if (_accTargetDistMeters < safeFollowingDist + 12.0) {
          double speedError = (_accTargetDistMeters - safeFollowingDist);
          targetSpeedKmh = math.min(_accSetSpeedKmh, leadVehicle.baseSpeedKmh + (speedError * 1.2));
          targetSpeedKmh = math.max(0.0, targetSpeedKmh);
          _accStatusText = "ACC HOLDING / FOLLOWING";
        } else {
          targetSpeedKmh = _accSetSpeedKmh;
          _accStatusText = "ACC ACTIVE";
        }
      } else {
        _accTargetDistMeters = 0.0;
        _accFollowingStatus = "SAFE";
        targetSpeedKmh = _accSetSpeedKmh;
        _accStatusText = "ACC ACTIVE";
      }

      double velError = targetSpeedKmh - _virtualVelocityKmh;
      if (velError > 0.5) {
        double throttleReq = (velError / 15.0).clamp(0.0, 1.0);
        _pedalThrottleRatio += (throttleReq - _pedalThrottleRatio) * (dt * 5.0);
        _pedalBrakeRatio += (0.0 - _pedalBrakeRatio) * (dt * 10.0);
      } else if (velError < -0.5) {
        double brakeReq = ((-velError) / 15.0).clamp(0.0, 1.0);
        _pedalThrottleRatio += (0.0 - _pedalThrottleRatio) * (dt * 8.0);
        _pedalBrakeRatio += (brakeReq - _pedalBrakeRatio) * (dt * 8.0);
      } else {
        _pedalThrottleRatio += (0.22 - _pedalThrottleRatio) * (dt * 4.0);
        _pedalBrakeRatio += (0.0 - _pedalBrakeRatio) * (dt * 8.0);
      }
    } else {
      _accStatusText = "ACC STANDBY";
      double targetGasRatio = _isGasPressed ? 1.0 : 0.0;
      double targetBrakeRatio = brakeActive ? 1.0 : 0.0;
      _pedalThrottleRatio += (targetGasRatio - _pedalThrottleRatio) * (dt * 6.5);
      _pedalBrakeRatio += (targetBrakeRatio - _pedalBrakeRatio) * (dt * 12.0);
    }

    double targetRpm = 800.0;
    if (_selectedGear == "D") {
      targetRpm = 800.0 + (_pedalThrottleRatio * (maxRpm - 800.0));
    } else if (_selectedGear == "R") {
      targetRpm = 800.0 + (_pedalThrottleRatio * 3000.0);
    } else if (_selectedGear == "N") {
      targetRpm = 800.0 + (_pedalThrottleRatio * 4500.0);
    }

    _motorRpm += (targetRpm - _motorRpm) * (dt * 10.0);

    if (_selectedGear == "N") {
      _motorRpm = math.max(800.0, _motorRpm - (2500.0 * dt));
      _virtualVelocityKmh = math.max(0.0, _virtualVelocityKmh - (3.0 * dt));
      _chassisPitchOffset += (0.0 - _chassisPitchOffset) * (dt * 5.0);
    } else if (_pedalBrakeRatio > 0.05) {
      double brakeDecel = 24.0 + (_pedalBrakeRatio * 20.0);
      if (_virtualVelocityKmh > 0) {
        _virtualVelocityKmh = math.max(0.0, _virtualVelocityKmh - (brakeDecel * dt));
      } else if (_virtualVelocityKmh < 0) {
        _virtualVelocityKmh = math.min(0.0, _virtualVelocityKmh + (brakeDecel * dt));
      }
      _chassisPitchOffset += (4.5 - _chassisPitchOffset) * (dt * 7.5);
    } else {
      double derivedSpeed = (_motorRpm / 60.0) * 1.35;
      if (_selectedGear == "D") {
        _virtualVelocityKmh = math.min(topForwardKmh, derivedSpeed);
        _chassisPitchOffset += (-2.5 - _chassisPitchOffset) * (dt * 6.0);
      } else if (_selectedGear == "R") {
        _virtualVelocityKmh = math.min(topReverseKmh, derivedSpeed);
        _chassisPitchOffset += (2.0 - _chassisPitchOffset) * (dt * 5.0);
      }
    }

    _displayedVelocity += (_virtualVelocityKmh.abs() - _displayedVelocity) * (dt * 9.0);

    double metersPerSec = _virtualVelocityKmh / 3.6;
    _virtualDistanceTraveled = (_virtualDistanceTraveled + (metersPerSec * dt * 0.012)) % 10000.0;

    for (var vehicle in _trafficList) {
      double relativeVelocityMs = (vehicle.baseSpeedKmh - _virtualVelocityKmh) / 3.6;
      vehicle.distanceMeters += relativeVelocityMs * dt;

      if (vehicle.distanceMeters < 4.0) {
        vehicle.distanceMeters = 85.0 + math.Random().nextDouble() * 35.0;
      } else if (vehicle.distanceMeters > 115.0) {
        vehicle.distanceMeters = 8.0 + math.Random().nextDouble() * 12.0;
      }
    }

    _updateEngineAudio();

    if (mounted) setState(() {});
  }

  void _updateSteeringDynamics(double dt) {
    if (!_isUserHoldingWheel) {
      double springK = 120.0;
      double dampingC = 22.0;
      double springForce = -springK * _steeringAngleDeg;
      double dampingForce = -dampingC * _steeringVelocity;

      _steeringVelocity += (springForce + dampingForce) * dt;
      _steeringAngleDeg += _steeringVelocity * dt;

      if (_steeringAngleDeg.abs() < 0.1 && _steeringVelocity.abs() < 0.1) {
        _steeringAngleDeg = 0.0;
        _steeringVelocity = 0.0;
      }
    }

    _steeringAngleDeg = _steeringAngleDeg.clamp(-_maxSteeringAngle, _maxSteeringAngle);
    _transmitSteeringAngle(_steeringAngleDeg);
  }

  void _onSteeringPanStart(DragStartDetails details) {
    _isUserHoldingWheel = true;
    _steeringVelocity = 0.0;
  }

  void _onSteeringPanUpdate(DragUpdateDetails details) {
    _isUserHoldingWheel = true;
    double sensitivityFactor = 1.25;
    double deltaAngle = details.delta.dx * sensitivityFactor;

    setState(() {
      _steeringAngleDeg = (_steeringAngleDeg + deltaAngle).clamp(-_maxSteeringAngle, _maxSteeringAngle);
    });
  }

  void _onSteeringPanEnd(DragEndDetails details) {
    _isUserHoldingWheel = false;
    _steeringVelocity = (details.velocity.pixelsPerSecond.dx / 25.0).clamp(-20.0, 20.0);
  }

  void _transmitSteeringAngle(double angleDeg) {
    double relativeServoAngle = (angleDeg / _maxSteeringAngle) * 30.0;
    int servoPwmAngle = (90 + (relativeServoAngle / 30.0) * 30.0).round().clamp(60, 120);

    if (_drivetrainMode == "FWD") {
      if ((servoPwmAngle - _lastSentServoAngle).abs() >= 1) {
        _lastSentServoAngle = servoPwmAngle;
        _sendCommand("STR:$servoPwmAngle");
      }
    } else {
      if (_lastSentServoAngle != 90) {
        _lastSentServoAngle = 90;
        _sendCommand("STR:90");
      }
      int leftDifferential = (90 + (angleDeg / _maxSteeringAngle) * 35).round();
      int rightDifferential = (90 - (angleDeg / _maxSteeringAngle) * 35).round();
      _sendCommand("RWD_DIFF:$leftDifferential,$rightDifferential");
    }
  }

  Offset _getWidgetCenter(GlobalKey key, Offset fallback) {
    final RenderBox? box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box != null && box.hasSize) {
      final pos = box.localToGlobal(Offset.zero);
      return Offset(pos.dx + box.size.width / 2, pos.dy + box.size.height / 2);
    }
    return fallback;
  }

  void _onGasDown() {
    setState(() => _isGasPressed = true);
    if (_selectedGear == "D") _sendCommand("DRV:F");
    if (_selectedGear == "R") _sendCommand("DRV:B");
  }

  void _onGasUp() {
    setState(() => _isGasPressed = false);
    if (!_isBrakePressed) _sendCommand("DRV:S");
  }

  void _onBrakeDown() {
    setState(() => _isBrakePressed = true);
    _sendCommand("DRV:S");
  }

  void _onBrakeUp() {
    setState(() => _isBrakePressed = false);
  }

  void _toggleDrivetrainMode() {
    HapticFeedback.heavyImpact();
    setState(() {
      _drivetrainMode = _drivetrainMode == "FWD" ? "RWD" : "FWD";
    });
    _drivetrainWarpController.forward(from: 0.0);
    _safePlayUiOneShot('sport_on.mp3', volume: 0.70);
    _sendCommand("DRIVE_SYS:$_drivetrainMode");
  }

  void _triggerModeTransition(String targetMode) {
    if (_driveMode == targetMode && _transitionController.isAnimating) return;

    HapticFeedback.heavyImpact();
    Offset origin = _getWidgetCenter(_modeBtnKey, const Offset(560, 26));

    if (targetMode == "SPORT") {
      _playSynchronizedTransition(
        audioFileName: 'sport_on.mp3',
        duration: const Duration(milliseconds: 1450),
        origin: origin,
        title: "SPORT",
        subtitle: "DYNAMIC PERFORMANCE ENGAGED",
        color: const Color(0xFFFF1744),
        isForward: true,
        onUpdateState: () => _driveMode = "SPORT",
      );
    } else if (targetMode == "ECO") {
      _playSynchronizedTransition(
        audioFileName: 'normal_off.mp3',
        duration: const Duration(milliseconds: 950),
        origin: origin,
        title: "ECO",
        subtitle: "INTELLIGENT ENERGY CONSERVATION",
        color: const Color(0xFF00E676),
        isForward: false,
        onUpdateState: () => _driveMode = "ECO",
      );
    } else {
      _playSynchronizedTransition(
        audioFileName: 'normal_on.mp3',
        duration: const Duration(milliseconds: 1100),
        origin: origin,
        title: "NORMAL",
        subtitle: "STANDARD CRUISING EFFICIENCY",
        color: const Color(0xFF00E5FF),
        isForward: false,
        onUpdateState: () => _driveMode = "NORMAL",
      );
    }

    _sendCommand("DMODE:$_driveMode");
  }

  void _triggerAdasTransition() {
    HapticFeedback.heavyImpact();
    bool willEnable = !_adasEnabled;
    Offset origin = _getWidgetCenter(_adasBtnKey, const Offset(360, 26));

    String audioFile = willEnable ? 'adas_on.mp3' : 'adas_off.mp3';
    Duration duration = willEnable ? const Duration(milliseconds: 1200) : const Duration(milliseconds: 900);

    _playSynchronizedTransition(
      audioFileName: audioFile,
      duration: duration,
      origin: origin,
      title: willEnable ? "ADAS ACTIVE" : "ADAS STANDBY",
      subtitle: willEnable ? "AUTONOMOUS COLLISION MATRIX ON" : "MANUAL OVERRIDE ACTIVE",
      color: willEnable ? const Color(0xFF00E5FF) : Colors.white60,
      isForward: willEnable,
      onUpdateState: () => _adasEnabled = willEnable,
    );

    _sendCommand(_adasEnabled ? "MODE:ADAS_ON" : "MODE:ADAS_OFF");
  }

  void _triggerAccTransition() {
    HapticFeedback.mediumImpact();
    bool willEnable = !_accEnabled;
    Offset origin = _getWidgetCenter(_accBtnKey, const Offset(440, 26));

    String audioFile = willEnable ? 'acc_on.mp3' : 'acc_off.mp3';
    Duration duration = willEnable ? const Duration(milliseconds: 1150) : const Duration(milliseconds: 850);

    _playSynchronizedTransition(
      audioFileName: audioFile,
      duration: duration,
      origin: origin,
      title: willEnable ? "ACC ACTIVE" : "ACC STANDBY",
      subtitle: willEnable ? "ADAPTIVE RADAR RANGEFINDER LOCKED" : "CRUISE DISENGAGED",
      color: willEnable ? const Color(0xFF00E676) : Colors.white60,
      isForward: willEnable,
      onUpdateState: () => _accEnabled = willEnable,
    );

    _sendCommand(_accEnabled ? "ACC:ON" : "ACC:OFF");
  }

  void _toggleNormalLights() {
    HapticFeedback.selectionClick();
    setState(() {
      _normalLightsOn = !_normalLightsOn;
      if (!_normalLightsOn) _highBeamOn = false;
    });
    _safePlayUiOneShot(_normalLightsOn ? 'lights_on.mp3' : 'lights_off.mp3', volume: 0.60);
    _sendCommand(_normalLightsOn ? "LIGHT:ON" : "LIGHT:OFF");
  }

  void _toggleHighBeam() {
    HapticFeedback.mediumImpact();
    setState(() {
      _highBeamOn = !_highBeamOn;
      if (_highBeamOn) _normalLightsOn = true;
    });
    _safePlayUiOneShot(_highBeamOn ? 'highbeam_on.mp3' : 'highbeam_off.mp3', volume: 0.60);
    _sendCommand(_highBeamOn ? "HBEAM:ON" : "HBEAM:OFF");
  }

  void _toggleMusicMode() {
    HapticFeedback.mediumImpact();
    setState(() {
      _isMusicMode = !_isMusicMode;
    });
    _safePlayUiOneShot(_isMusicMode ? 'sport_on.mp3' : 'normal_off.mp3', volume: 0.60);
  }

  void _selectPov(int index) {
    if (_selectedPovIndex == index) return;
    HapticFeedback.mediumImpact();
    setState(() => _selectedPovIndex = index);
    if (index == 1) {
      _povTransitionController.forward();
    } else {
      _povTransitionController.reverse();
    }
  }

  Future<void> _initPermissionsAndBluetooth() async {
    await [
      Permission.bluetooth,
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();

    try {
      final bonded = await FlutterBluetoothSerial.instance.getBondedDevices();
      if (mounted) setState(() => _devicesList = bonded);
    } catch (_) {}
  }

  void _connectToDevice(BluetoothDevice device) async {
    setState(() => _isConnecting = true);
    try {
      BluetoothConnection connection = await BluetoothConnection.toAddress(device.address);
      if (mounted) {
        setState(() {
          _connection = connection;
          _isConnected = true;
          _isConnecting = false;
        });
      }

      _connection!.input!.listen(_onDataReceived).onDone(() {
        if (mounted) setState(() => _isConnected = false);
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _isConnected = false;
          _isConnecting = false;
        });
      }
    }
  }

  void _onDataReceived(Uint8List data) {
    _receivedBuffer += utf8.decode(data);
    while (_receivedBuffer.contains('\n')) {
      int index = _receivedBuffer.indexOf('\n');
      String line = _receivedBuffer.substring(0, index).trim();
      _receivedBuffer = _receivedBuffer.substring(index + 1);
      _processTelemetry(line);
      if (_diagLogs.length > 8) _diagLogs.removeAt(0);
      setState(() => _diagLogs.add("RX: $line"));
    }
  }

  void _processTelemetry(String line) {
    if (line.isEmpty) return;
    try {
      List<String> parts = line.split(',');
      for (String item in parts) {
        List<String> kv = item.split(':');
        if (kv.length == 2) {
          String key = kv[0].trim();
          String value = kv[1].trim();
          setState(() {
            if (key == 'V') {
              _batteryVoltage = double.tryParse(value) ?? _batteryVoltage;
              _batteryPercent = (((_batteryVoltage - 6.0) / 2.4) * 100).round().clamp(0, 100);
            }
            if (key == 'BAT') _batteryPercent = (int.tryParse(value) ?? _batteryPercent).clamp(0, 100);
            if (key == 'S') _hardwareSpeed = int.tryParse(value) ?? _hardwareSpeed;
            if (key == 'US_DIST') {
              double distCm = double.tryParse(value) ?? 50.0;
              _ultrasonicDistanceCm = distCm;
              if (_trafficList.isNotEmpty) {
                _trafficList[0].distanceMeters = distCm / 100.0;
              }
            }
            if (key == 'AB' && value == '1') {
              _autoBrakeTriggered = true;
              HapticFeedback.heavyImpact();
            } else {
              _autoBrakeTriggered = false;
            }
          });
        }
      }
    } catch (_) {}
  }

  void _sendCommand(String cmd) {
    if (_connection != null && _connection!.isConnected) {
      _connection!.output.add(Uint8List.fromList(utf8.encode('$cmd\n')));
      if (_diagLogs.length > 8) _diagLogs.removeAt(0);
      setState(() => _diagLogs.add("TX: $cmd"));
    }
  }

  String _formatTime(DateTime dt) {
    String hour = dt.hour.toString().padLeft(2, '0');
    String minute = dt.minute.toString().padLeft(2, '0');
    return "$hour:$minute";
  }

  String _formatDate(DateTime dt) {
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return "${dt.day} ${months[dt.month - 1]} ${dt.year}";
  }

  @override
  void dispose() {
    _musicService.removeListener(_onMusicStateChanged);
    _modeSoundPlayer.dispose();
    _uiSoundPlayer.dispose();
    _hornSoundPlayer.dispose();
    _powertrainPlayer.dispose();
    _decelerationPlayer.dispose();
    _worldPhysicsTicker.dispose();
    _clockTimer.cancel();
    _transitionController.dispose();
    _drivetrainWarpController.dispose();
    _povTransitionController.dispose();
    _connection?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Color activeAccentColor = _driveMode == "SPORT"
        ? const Color(0xFFFF1744)
        : (_driveMode == "ECO" ? const Color(0xFF00E676) : const Color(0xFF00E5FF));

    Color baseAmbientGlow = _driveMode == "SPORT"
        ? const Color(0xFF2A0810)
        : (_driveMode == "ECO" ? const Color(0xFF062416) : const Color(0xFF0C1829));

    Color activeAmbientGlow = baseAmbientGlow;
    bool isMusicPlaying = _musicService.playerState == PlayerState.playing;
    double beatVal = _musicService.beatIntensity;
    
    List<Color> neonPalette = [
      const Color(0xFF00E5FF), // Cyan
      const Color(0xFF2979FF), // Blue
      const Color(0xFF7C4DFF), // Purple
      const Color(0xFFE040FB), // Magenta
      const Color(0xFFFF4081), // Pink
    ];

    Color dynamicNeon = activeAccentColor;
    if (isMusicPlaying) {
      double tVal = (beatVal * (neonPalette.length - 1));
      int index1 = tVal.floor().clamp(0, neonPalette.length - 1);
      int index2 = (index1 + 1).clamp(0, neonPalette.length - 1);
      double subT = tVal - index1;
      dynamicNeon = Color.lerp(neonPalette[index1], neonPalette[index2], subT)!;
      activeAmbientGlow = Color.lerp(baseAmbientGlow, dynamicNeon, 0.25 + (beatVal * 0.35))!;
    }

    return Scaffold(
      backgroundColor: const Color(0xFF030509),
      body: SafeArea(
        child: AnimatedBuilder(
          animation: Listenable.merge([_transitionController, _drivetrainWarpController]),
          builder: (context, child) {
            double t = _transitionController.value;
            double warpT = _drivetrainWarpController.value;

            return LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    Positioned.fill(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 120),
                        decoration: BoxDecoration(
                          gradient: RadialGradient(
                            center: const Alignment(0.0, -0.4),
                            radius: 1.4,
                            colors: [activeAmbientGlow, const Color(0xFF030509)],
                          ),
                        ),
                      ),
                    ),

                    Positioned(
                      top: 4, left: 10, right: 10, height: 42,
                      child: _buildTopHeaderBar(activeAccentColor, dynamicNeon, isMusicPlaying, beatVal),
                    ),

                    Positioned(
                      top: 50, left: 10, bottom: 148, width: 156,
                      child: AdasNeonCard(
                        isPlaying: isMusicPlaying,
                        beatIntensity: beatVal,
                        borderRadius: 16,
                        child: _buildSystemStatusCard(activeAccentColor, dynamicNeon, isMusicPlaying, beatVal),
                      ),
                    ),

                    Positioned(
                      top: 50, left: 174, right: 174, bottom: 96,
                      child: _buildCenterCameraViewport(activeAccentColor, dynamicNeon, isMusicPlaying, beatVal),
                    ),

                    Positioned(
                      top: 50, right: 10, bottom: 168, width: 156,
                      child: AdasNeonCard(
                        isPlaying: isMusicPlaying,
                        beatIntensity: beatVal,
                        borderRadius: 16,
                        child: _buildDetectedObjectsCard(activeAccentColor, dynamicNeon, isMusicPlaying, beatVal),
                      ),
                    ),

                    Positioned(
                      bottom: 4, left: 200, right: 200, height: 64,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 300),
                        child: _isMusicMode
                            ? SpotifyMusicPlayerWidget(
                                key: const ValueKey('spotify_popup'),
                                musicService: _musicService,
                                activeColor: activeAccentColor,
                              )
                            : Column(
                                key: const ValueKey('lower_gauges'),
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _buildReferenceBottomGauges(activeAccentColor),
                                  const SizedBox(height: 1),
                                  const Text(
                                    "SAFE DRIVE    •    SMART DRIVE    •    BETTER TOMORROW",
                                    style: TextStyle(color: Colors.white24, fontSize: 6.5, letterSpacing: 2.0, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                      ),
                    ),

                    Positioned(
                      bottom: 2, left: 2, width: 230, height: 180,
                      child: Center(child: _buildSteeringWheelModule(activeAccentColor, dynamicNeon, isMusicPlaying, beatVal)),
                    ),

                    Positioned(
                      bottom: 2, right: 2, width: 210, height: 175,
                      child: Center(child: _buildPedalsAndGears(activeAccentColor)),
                    ),

                    if (_drivetrainWarpController.isAnimating)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: DrivetrainWarpPainter(
                              progress: warpT,
                              mode: _drivetrainMode,
                            ),
                          ),
                        ),
                      ),

                    if (_transitionController.isAnimating && t >= 0.05 && t <= 0.40)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CustomPaint(
                            painter: HorizontalEnergyBusPainter(
                              origin: _transitionOrigin,
                              progress: ((t - 0.05) / 0.35).clamp(0.0, 1.0),
                              isForward: _isTransitionForward,
                              color: _transitionColor,
                            ),
                          ),
                        ),
                      ),
                    if (_transitionController.isAnimating && t >= 0.38 && t <= 0.90)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: Center(
                            child: _buildAutomotiveTypographyReveal(((t - 0.38) / 0.52).clamp(0.0, 1.0)),
                          ),
                        ),
                      ),
                  ],
                );
              },
            );
          },
        ),
      ),
    );
  }

  Widget _buildTopHeaderBar(Color activeColor, Color dynamicNeon, bool isMusicPlaying, double beatVal) {
    Color glowColor = isMusicPlaying ? dynamicNeon : activeColor;
    double blur = isMusicPlaying ? 10.0 + (beatVal * 10.0) : 4.0;
    double spread = isMusicPlaying ? 1.5 + (beatVal * 2.0) : 0.5;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: glowColor.withOpacity(isMusicPlaying ? 0.35 + (beatVal * 0.45) : 0.15),
            blurRadius: blur,
            spreadRadius: spread,
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            height: 38, padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: const Color(0xFF0A1220), borderRadius: BorderRadius.circular(10), border: Border.all(color: activeColor.withOpacity(0.25))),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(color: const Color(0xFF00E676).withOpacity(0.15), borderRadius: BorderRadius.circular(5)),
                  child: const Icon(Icons.battery_charging_full, color: Color(0xFF00E676), size: 16),
                ),
                const SizedBox(width: 6),
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text("$_batteryPercent%", style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 11)),
                    const Text("120 km est.", style: TextStyle(color: Colors.white54, fontSize: 7)),
                  ],
                )
              ],
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            key: _drivetrainBtnKey,
            onTap: _toggleDrivetrainMode,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 400),
              height: 38, padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _drivetrainMode == "FWD" ? const Color(0xFF0C2448) : const Color(0xFF381212),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _drivetrainMode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744), width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(_drivetrainMode == "FWD" ? Icons.bolt : Icons.settings_power, color: _drivetrainMode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744), size: 16),
                  const SizedBox(width: 5),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("DRIVE", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 8.5)),
                      Text(_drivetrainMode, style: TextStyle(color: _drivetrainMode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744), fontSize: 7, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _toggleNormalLights,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              height: 38, padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _normalLightsOn ? activeColor.withOpacity(0.18) : const Color(0xFF0A1220),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _normalLightsOn ? activeColor : Colors.white12, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.highlight, color: _normalLightsOn ? activeColor : Colors.white38, size: 16),
                  const SizedBox(width: 5),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("LIGHTS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 8.5)),
                      Text(_normalLightsOn ? "ON" : "OFF", style: TextStyle(color: _normalLightsOn ? activeColor : Colors.white38, fontSize: 7, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: _toggleHighBeam,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              height: 38, padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _highBeamOn ? const Color(0xFF0C2448) : const Color(0xFF0A1220),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _highBeamOn ? const Color(0xFF2979FF) : Colors.white12, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.flare_rounded, color: _highBeamOn ? const Color(0xFF448AFF) : Colors.white38, size: 16),
                  const SizedBox(width: 5),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("HI-BEAM", style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 8.5)),
                      Text(_highBeamOn ? "ON" : "OFF", style: TextStyle(color: _highBeamOn ? const Color(0xFF448AFF) : Colors.white38, fontSize: 7, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            key: _adasBtnKey,
            onTap: _triggerAdasTransition,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              height: 38, padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _adasEnabled ? const Color(0xFF052A26) : const Color(0xFF0A1220),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _adasEnabled ? const Color(0xFF00E676) : Colors.white12, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.alt_route, color: _adasEnabled ? const Color(0xFF00E676) : Colors.white38, size: 16),
                  const SizedBox(width: 5),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("ADAS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 8.5)),
                      Text(_adasEnabled ? "ACTIVE" : "STANDBY", style: TextStyle(color: _adasEnabled ? const Color(0xFF00E676) : Colors.white38, fontSize: 7, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            key: _accBtnKey,
            onTap: _triggerAccTransition,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500),
              height: 38, padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: _accEnabled ? const Color(0xFF062416) : const Color(0xFF0A1220),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: _accEnabled ? const Color(0xFF00E676) : Colors.white12, width: 1.5),
              ),
              child: Row(
                children: [
                  Icon(Icons.speed, color: _accEnabled ? const Color(0xFF00E676) : Colors.white38, size: 16),
                  const SizedBox(width: 5),
                  Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("ACC", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 8.5)),
                      Text(_accEnabled ? (_accStatusText.contains("HOLDING") ? "FOLLOWING" : "ACTIVE") : "STANDBY", 
                           style: TextStyle(color: _accEnabled ? const Color(0xFF00E676) : Colors.white38, fontSize: 6.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500),
            key: _modeBtnKey, height: 38, padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(
              color: activeColor.withOpacity(0.18),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: activeColor, width: 1.5),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: _driveMode,
                dropdownColor: const Color(0xFF0B132B),
                style: TextStyle(color: activeColor, fontSize: 10.5, fontWeight: FontWeight.w900),
                icon: Icon(Icons.arrow_drop_down, color: activeColor, size: 18),
                items: ["NORMAL", "SPORT", "ECO"].map((m) => DropdownMenuItem(value: m, child: Text(m))).toList(),
                onChanged: (v) { if (v != null) _triggerModeTransition(v); },
              ),
            ),
          ),
          const Spacer(),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: _showBluetoothList,
                child: Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A1220),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: _isConnected ? const Color(0xFF00E676).withOpacity(0.4) : Colors.white12),
                  ),
                  child: Icon(
                    _isConnected ? Icons.bluetooth_connected : Icons.bluetooth,
                    color: _isConnected ? const Color(0xFF00E676) : Colors.white54,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: _toggleMusicMode,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(
                    color: _isMusicMode ? const Color(0xFF0C2448) : const Color(0xFF0A1220),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _isMusicMode ? Colors.cyanAccent : Colors.white12,
                      width: _isMusicMode ? 1.5 : 1.0,
                    ),
                    boxShadow: [
                      if (_isMusicMode)
                        BoxShadow(color: Colors.cyanAccent.withOpacity(0.4), blurRadius: 8),
                    ],
                  ),
                  child: Icon(
                    Icons.music_note,
                    color: _isMusicMode ? Colors.cyanAccent : Colors.white54,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(_formatTime(_currentTime), style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.bold, letterSpacing: 0.5)),
                  Text(_formatDate(_currentTime), style: const TextStyle(color: Colors.white38, fontSize: 7)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildSystemStatusCard(Color activeColor, Color dynamicNeon, bool isMusicPlaying, double beatVal) {
    Color glowColor = isMusicPlaying ? dynamicNeon : activeColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(text: TextSpan(children: [
          TextSpan(text: "SYSTEM ", style: TextStyle(color: glowColor, fontWeight: FontWeight.w900, fontSize: 10)),
          const TextSpan(text: "STATUS", style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 10)),
        ])),
        const Divider(color: Colors.white10, height: 8),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown, alignment: Alignment.topLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildStatusRow("Drive Sys", _drivetrainMode, _drivetrainMode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744)),
                _buildStatusRow("Motor RPM", "${_motorRpm.round()} RPM", const Color(0xFF00E676)),
                _buildStatusRow("ADAS", _adasEnabled ? "ACTIVE" : "STANDBY", _adasEnabled ? const Color(0xFF00E676) : Colors.white54),
                _buildStatusRow("ACC Mode", _accEnabled ? "ACTIVE" : "STANDBY", _accEnabled ? const Color(0xFF00E676) : Colors.white54),
                _buildStatusRow("Steering", _drivetrainMode == "FWD" ? "SERVO" : "DIFFERENTIAL", const Color(0xFF00E676)),
                _buildStatusRow("Bluetooth", _isConnected ? "CONNECTED" : "OFFLINE", _isConnected ? const Color(0xFF00E676) : Colors.amberAccent),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow(String label, String status, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2.0),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(width: 76, child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 8.5))),
          Container(width: 5, height: 5, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
          const SizedBox(width: 4),
          Text(status, style: TextStyle(color: color, fontSize: 8, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildDetectedObjectsCard(Color activeColor, Color dynamicNeon, bool isMusicPlaying, double beatVal) {
    Color glowColor = isMusicPlaying ? dynamicNeon : activeColor;

    List<Widget> objectWidgets = [];

    if (_isConnected) {
      String tag;
      Color tagColor;
      if (_ultrasonicDistanceCm < 5.0) {
        tag = "CAUTION";
        tagColor = const Color(0xFFFF1744);
      } else if (_ultrasonicDistanceCm < 15.0) {
        tag = "WARNING";
        tagColor = Colors.amberAccent;
      } else {
        tag = "SAFE";
        tagColor = const Color(0xFF00E676);
      }

      objectWidgets.add(
        Container(
          margin: const EdgeInsets.symmetric(vertical: 2.0),
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
          decoration: BoxDecoration(color: const Color(0xFF0D1626), borderRadius: BorderRadius.circular(6), border: Border.all(color: tagColor.withOpacity(0.35))),
          child: Row(
            children: [
              const Icon(Icons.sensors, color: Colors.white70, size: 12),
              const SizedBox(width: 4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text("Ultrasonic Obstacle", overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white70, fontSize: 7)),
                    Text("${_ultrasonicDistanceCm.toStringAsFixed(1)} cm", style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                decoration: BoxDecoration(color: tagColor.withOpacity(0.15), borderRadius: BorderRadius.circular(3), border: Border.all(color: tagColor, width: 0.8)),
                child: Text(tag, style: TextStyle(color: tagColor, fontSize: 6, fontWeight: FontWeight.w900)),
              ),
            ],
          ),
        ),
      );
    } else {
      final activeObjects = _trafficList.where((v) => v.distanceMeters > 4.0 && v.distanceMeters < 50.0).toList();
      for (var obj in activeObjects) {
        String tag = obj.distanceMeters * 100 < 5.0 ? "CAUTION" : (obj.distanceMeters * 100 < 15.0 ? "WARNING" : "SAFE");
        Color tagColor = obj.distanceMeters * 100 < 5.0 ? const Color(0xFFFF1744) : (obj.distanceMeters * 100 < 15.0 ? Colors.amberAccent : const Color(0xFF00E676));

        objectWidgets.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 2.0),
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(color: const Color(0xFF0D1626), borderRadius: BorderRadius.circular(6), border: Border.all(color: tagColor.withOpacity(0.35))),
            child: Row(
              children: [
                const Icon(Icons.directions_car, color: Colors.white70, size: 12),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(obj.label, overflow: TextOverflow.ellipsis, style: const TextStyle(color: Colors.white70, fontSize: 7)),
                      Text("${(obj.distanceMeters * 100).toStringAsFixed(1)} cm", style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold)),
                    ],
                  ),
                ),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
                  decoration: BoxDecoration(color: tagColor.withOpacity(0.15), borderRadius: BorderRadius.circular(3), border: Border.all(color: tagColor, width: 0.8)),
                  child: Text(tag, style: TextStyle(color: tagColor, fontSize: 6, fontWeight: FontWeight.w900)),
                ),
              ],
            ),
          ),
        );
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text("DETECTED OBJECTS", style: TextStyle(color: glowColor, fontWeight: FontWeight.w900, fontSize: 9.5, letterSpacing: 0.5)),
        const Divider(color: Colors.white10, height: 8),
        Expanded(
          child: objectWidgets.isEmpty
              ? Center(child: Text("NO OBJECTS DETECTED", style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 8, fontWeight: FontWeight.w900)))
              : ListView(
                  padding: EdgeInsets.zero,
                  children: objectWidgets,
                ),
        ),
      ],
    );
  }

  Widget _buildReferenceBottomGauges(Color activeColor) {
    int throttleBars = (_pedalThrottleRatio * 10).round().clamp(0, 10);
    int brakeBars = (_pedalBrakeRatio * 10).round().clamp(0, 10);

    return FittedBox(
      fit: BoxFit.scaleDown,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 500), width: 98, height: 48, padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(10), border: Border.all(color: activeColor.withOpacity(0.3))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("MOTOR RPM", style: TextStyle(color: Colors.white54, fontSize: 5.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.autorenew, color: activeColor, size: 11),
                    const SizedBox(width: 3),
                    Text("${_motorRpm.round()}", style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 1.0),
                const Text("RPM SPEED REF", style: TextStyle(color: Colors.white30, fontSize: 5.0, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500), width: 98, height: 48, padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(10), border: Border.all(color: activeColor.withOpacity(0.3))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("THROTTLE", style: TextStyle(color: Colors.white54, fontSize: 5.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.speed, color: Color(0xFF00E676), size: 11),
                    const SizedBox(width: 3),
                    Text("${(_pedalThrottleRatio * 100).round()}%", style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 1.0),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(10, (i) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.6), width: 3.0, height: 4.0,
                    decoration: BoxDecoration(color: i < throttleBars ? const Color(0xFF00E676) : Colors.white12, borderRadius: BorderRadius.circular(1)),
                  )),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500), width: 98, height: 48, padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(10), border: Border.all(color: const Color(0xFFFF1744).withOpacity(0.3))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("BRAKE", style: TextStyle(color: Colors.white54, fontSize: 5.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.do_not_disturb_on, color: Color(0xFFFF1744), size: 11),
                    const SizedBox(width: 3),
                    Text("${(_pedalBrakeRatio * 100).round()}%", style: const TextStyle(color: Colors.white, fontSize: 9.5, fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 1.0),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(10, (i) => Container(
                    margin: const EdgeInsets.symmetric(horizontal: 0.6), width: 3.0, height: 4.0,
                    decoration: BoxDecoration(color: i < brakeBars ? const Color(0xFFFF1744) : Colors.white12, borderRadius: BorderRadius.circular(1)),
                  )),
                ),
              ],
            ),
          ),
          const SizedBox(width: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500), width: 98, height: 48, padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(10), border: Border.all(color: activeColor.withOpacity(0.4))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text("DRIVE MODE", style: TextStyle(color: Colors.white54, fontSize: 5.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 1),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.alt_route, color: activeColor, size: 11),
                    const SizedBox(width: 3),
                    Text(_driveMode, style: TextStyle(color: activeColor, fontSize: 9.5, fontWeight: FontWeight.w900)),
                  ],
                ),
                const SizedBox(height: 1.0),
                const Text("ECO | NORMAL | SPORT", style: TextStyle(color: Colors.white30, fontSize: 5.0, fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          const SizedBox(width: 4),
          AnimatedContainer(
            duration: const Duration(milliseconds: 500), width: 98, height: 48, padding: const EdgeInsets.all(2),
            decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(10), border: Border.all(color: activeColor.withOpacity(0.4))),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text("POV", style: TextStyle(color: activeColor, fontSize: 5.5, fontWeight: FontWeight.bold)),
                const SizedBox(height: 0.5),
                _buildMiniPovItem(0, "1ST PERSON", activeColor),
                _buildMiniPovItem(1, "3RD PERSON", activeColor),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniPovItem(int index, String title, Color activeColor) {
    bool isSel = _selectedPovIndex == index;
    return GestureDetector(
      onTap: () => _selectPov(index),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 0.2), padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.8),
        decoration: BoxDecoration(color: isSel ? activeColor.withOpacity(0.25) : Colors.transparent, borderRadius: BorderRadius.circular(2)),
        child: Text(title, style: TextStyle(color: isSel ? activeColor : Colors.white54, fontSize: 5.5, fontWeight: isSel ? FontWeight.w900 : FontWeight.normal)),
      ),
    );
  }

  Widget _buildCenterCameraViewport(Color activeColor, Color dynamicNeon, bool isMusicPlaying, double beatVal) {
    Color glowColor = isMusicPlaying ? dynamicNeon : activeColor;
    double blur = isMusicPlaying ? 16.0 + (beatVal * 18.0) : 8.0;
    double spread = isMusicPlaying ? 2.5 + (beatVal * 3.0) : 1.5;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      decoration: BoxDecoration(
        color: const Color(0xFF050B14),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: glowColor.withOpacity(isMusicPlaying ? 0.75 + (beatVal * 0.25) : 0.5), width: 2.0),
        boxShadow: [
          BoxShadow(
            color: glowColor.withOpacity(isMusicPlaying ? 0.4 + (beatVal * 0.6) : 0.25),
            blurRadius: blur,
            spreadRadius: spread,
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          CustomPaint(
            painter: ArcadeMotionHighwayPainter(
              displacement: _virtualDistanceTraveled,
              velocityKmh: _virtualVelocityKmh,
              steeringAngle: _steeringAngleDeg,
              driveMode: _driveMode,
              normalLightsOn: _normalLightsOn,
              highBeamOn: _highBeamOn,
              brakePressed: _isBrakePressed || _autoBrakeTriggered || (_adasEnabled && _ultrasonicDistanceCm > 0 && _ultrasonicDistanceCm < 15.0),
              povMode: _selectedPovIndex,
              chassisPitch: _chassisPitchOffset,
              trafficList: _trafficList,
              accentColor: activeColor,
              adasActive: _adasEnabled,
              adasOpacity: _adasAnimProgress,
              accActive: _accEnabled,
              drivetrainMode: _drivetrainMode,
              beatIntensity: beatVal,
            ),
          ),
          if (_isRealCameraOnline)
            Positioned.fill(
              child: Mjpeg(
                key: _mjpegKey, isLive: true, stream: _streamUrl, timeout: const Duration(seconds: 4),
                loading: (ctx) => const SizedBox.shrink(),
                error: (ctx, err, stack) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) setState(() => _isRealCameraOnline = false);
                  });
                  return const SizedBox.shrink();
                },
                headers: const {'Connection': 'keep-alive'},
              ),
            ),
          Positioned(
            top: 8, left: 10,
            child: Row(
              children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: _isRealCameraOnline ? const Color(0xFF00E676) : Colors.amberAccent)),
                const SizedBox(width: 5),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_isRealCameraOnline ? "CAMERA ONLINE" : "CAMERA OFFLINE • VIRTUAL MODE", style: const TextStyle(color: Colors.white, fontSize: 9.0, fontWeight: FontWeight.w900)),
                    const Text("LANE DETECTION ACTIVE", style: TextStyle(color: Colors.white54, fontSize: 6.5, fontWeight: FontWeight.bold)),
                  ],
                )
              ],
            ),
          ),
          Positioned(
            top: 8, right: 10,
            child: Row(
              children: [
                const Icon(Icons.nightlight_round, color: Colors.amberAccent, size: 13),
                const SizedBox(width: 4),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(_weatherText, style: const TextStyle(color: Colors.white, fontSize: 9.0, fontWeight: FontWeight.bold)),
                    Text(_locationArea, style: const TextStyle(color: Colors.white54, fontSize: 6.5)),
                  ],
                )
              ],
            ),
          ),
          Positioned(
            top: 0, left: 0, right: 0,
            child: Center(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 500), width: 130, height: 48,
                decoration: BoxDecoration(
                  color: const Color(0xEE0B1426), borderRadius: const BorderRadius.vertical(bottom: Radius.circular(26)),
                  border: Border.all(color: activeColor.withOpacity(0.5), width: 1.5),
                  boxShadow: [BoxShadow(color: activeColor.withOpacity(0.3), blurRadius: 12)],
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text("${_hardwareSpeed > 0 ? _hardwareSpeed : _displayedVelocity.round()}", style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w900)),
                    const Text("km/h", style: TextStyle(color: Colors.white54, fontSize: 7)),
                  ],
                ),
              ),
            ),
          ),
          if (_accEnabled)
            Positioned(
              top: 52, left: 16, right: 16,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: const Color(0xDD062416),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFF00E676), width: 1.2),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceAround,
                  children: [
                    Text("SET SPEED: ${_accSetSpeedKmh.round()} km/h", style: const TextStyle(color: Color(0xFF00E676), fontSize: 8.5, fontWeight: FontWeight.w900)),
                    Text("CUR SPEED: ${_displayedVelocity.round()} km/h", style: const TextStyle(color: Colors.white, fontSize: 8.5, fontWeight: FontWeight.bold)),
                    Text("TARGET: ${_accTargetDistMeters > 0 ? '${(_accTargetDistMeters).toStringAsFixed(1)} m' : 'NONE'}", style: const TextStyle(color: Colors.amberAccent, fontSize: 8.5, fontWeight: FontWeight.bold)),
                    Text("DIST: $_accFollowingStatus", style: TextStyle(color: _accFollowingStatus == "SAFE" ? const Color(0xFF00E676) : (_accFollowingStatus == "WARNING" ? Colors.amberAccent : const Color(0xFFFF1744)), fontSize: 8.5, fontWeight: FontWeight.w900)),
                  ],
                ),
              ),
            ),
          Positioned(
            bottom: 8, left: 10,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 500), padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xDD071C25), borderRadius: BorderRadius.circular(6), border: Border.all(color: activeColor.withOpacity(0.6))),
              child: Row(
                children: [
                  Icon(Icons.alt_route, color: activeColor, size: 14),
                  const SizedBox(width: 5),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text("LANE KEEPING", style: TextStyle(color: Colors.white70, fontSize: 6.5, fontWeight: FontWeight.bold)),
                      Text("ACTIVE", style: TextStyle(color: activeColor, fontSize: 8.0, fontWeight: FontWeight.w900)),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            bottom: 8, right: 10,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(color: const Color(0xDD07261B), borderRadius: BorderRadius.circular(16), border: Border.all(color: const Color(0xFF00E676).withOpacity(0.6))),
              child: const Row(
                children: [
                  Icon(Icons.check_circle, color: Color(0xFF00E676), size: 12),
                  SizedBox(width: 4),
                  Text("SAFE DISTANCE", style: TextStyle(color: Color(0xFF00E676), fontSize: 8.0, fontWeight: FontWeight.w900)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ============================================================================
  // STEERING WHEEL WITH BRIGHT CYAN BEAT-REACTIVE INNER CONTOUR ILLUMINATION
  // ============================================================================
  Widget _buildSteeringWheelModule(Color activeColor, Color dynamicNeon, bool isMusicPlaying, double beatVal) {
    const double size = 230.0;
    Color wheelGlow = isMusicPlaying ? dynamicNeon : const Color(0xFF00E5FF);
    double wheelBlur = isMusicPlaying ? 16.0 + (beatVal * 18.0) : 9.0;
    double wheelSpread = isMusicPlaying ? 2.5 + (beatVal * 3.5) : 1.2;

    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: _onSteeringPanStart,
          onPanUpdate: _onSteeringPanUpdate,
          onPanEnd: _onSteeringPanEnd,
          child: Transform.rotate(
            angle: _steeringAngleDeg * (math.pi / 180),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: size, height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: wheelGlow.withOpacity(isMusicPlaying ? 0.5 + (beatVal * 0.5) : 0.3),
                    blurRadius: wheelBlur,
                    spreadRadius: wheelSpread,
                  ),
                ],
              ),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Image.asset(
                    'assets/wheel_body.png', width: size, height: size, fit: BoxFit.contain,
                    errorBuilder: (context, error, stackTrace) => Container(
                      width: size, height: size,
                      decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: wheelGlow, width: 6.0)),
                    ),
                  ),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (_) {
                      setState(() => _isHonking = true);
                      HapticFeedback.heavyImpact();
                      _playHornSound();
                      _sendCommand("HORN:ON");
                    },
                    onTapUp: (_) {
                      setState(() => _isHonking = false);
                      _sendCommand("HORN:OFF");
                    },
                    onTapCancel: () {
                      setState(() => _isHonking = false);
                      _sendCommand("HORN:OFF");
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      transform: Matrix4.identity()..scale(_isHonking ? 0.93 : 1.0),
                      width: 70, height: 70,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const RadialGradient(colors: [Color(0xFF1E2838), Color(0xFF080C14)], stops: [0.35, 1.0]),
                        border: Border.all(color: wheelGlow, width: 3.0),
                        boxShadow: [BoxShadow(color: wheelGlow.withOpacity(isMusicPlaying ? 0.85 + (beatVal * 0.15) : 0.6), blurRadius: 18)],
                      ),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: const [
                          Icon(Icons.speed, color: Colors.white, size: 16),
                          SizedBox(height: 1),
                          Text("GEAR HEADS", style: TextStyle(color: Colors.white, fontSize: 6.5, fontWeight: FontWeight.w900, letterSpacing: 0.6)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildPedalsAndGears(Color activeColor) {
    bool brakeActive = _isBrakePressed || _autoBrakeTriggered || (_adasEnabled && _ultrasonicDistanceCm > 0 && _ultrasonicDistanceCm < 15.0);

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        GestureDetector(
          onTapDown: (_) => _onBrakeDown(),
          onTapUp: (_) => _onBrakeUp(),
          onTapCancel: () => _onBrakeUp(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            transformAlignment: Alignment.topCenter,
            transform: Matrix4.identity()..setEntry(3, 2, 0.002)..rotateX(brakeActive ? -0.25 : 0.0)..scale(brakeActive ? 0.94 : 1.0),
            width: 82, height: 150,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: const Color(0xFFFF1744).withOpacity(brakeActive ? 0.95 : 0.35), blurRadius: 24, offset: const Offset(0, 3))],
            ),
            child: Image.asset('assets/pedal_brake.png', fit: BoxFit.contain),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTapDown: (_) => _onGasDown(),
          onTapUp: (_) => _onGasUp(),
          onTapCancel: () => _onGasUp(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 90),
            transformAlignment: Alignment.bottomCenter,
            transform: Matrix4.identity()..setEntry(3, 2, 0.002)..rotateX(_isGasPressed ? 0.22 : 0.0)..scale(_isGasPressed ? 0.95 : 1.0),
            width: 74, height: 185,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: [BoxShadow(color: activeColor.withOpacity(_isGasPressed ? 0.95 : 0.35), blurRadius: 24, offset: const Offset(0, 3))],
            ),
            child: Image.asset('assets/pedal_gas.png', fit: BoxFit.contain),
          ),
        ),
        const SizedBox(width: 8),
        AnimatedContainer(
          duration: const Duration(milliseconds: 500), width: 32, padding: const EdgeInsets.symmetric(vertical: 4),
          decoration: BoxDecoration(color: const Color(0xFF080F1D), borderRadius: BorderRadius.circular(8), border: Border.all(color: activeColor.withOpacity(0.2))),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: ["D", "N", "R"].map((g) {
              bool isSel = _selectedGear == g;
              Color selColor = g == "D" ? const Color(0xFFFF1744) : (g == "R" ? Colors.amberAccent : activeColor);
              return GestureDetector(
                onTap: () {
                  setState(() => _selectedGear = g);
                  _sendCommand("GEAR:$g");
                  if (g == "N") _sendCommand("DRV:S");
                  HapticFeedback.selectionClick();
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180), margin: const EdgeInsets.symmetric(vertical: 2.5), width: 24, height: 24,
                  decoration: BoxDecoration(color: isSel ? selColor : Colors.transparent, borderRadius: BorderRadius.circular(5)),
                  child: Center(child: Text(g, style: TextStyle(color: isSel ? Colors.white : Colors.white60, fontWeight: FontWeight.w900, fontSize: 11.5))),
                ),
              );
            }).toList(),
          ),
        ),
      ],
    );
  }

  Widget _buildAutomotiveTypographyReveal(double p) {
    double scale = 0.90 + (0.12 * math.sin(p * math.pi * 0.5));
    double opacity = (p < 0.25) ? (p / 0.25) : ((p > 0.75) ? (1.0 - (p - 0.75) / 0.25) : 1.0);

    return Opacity(
      opacity: opacity.clamp(0.0, 1.0),
      child: Transform.scale(
        scale: scale,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 220, height: 2,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [Colors.transparent, _transitionColor, Colors.white, _transitionColor, Colors.transparent]),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _transitionTitle,
              style: TextStyle(
                color: Colors.white, fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 8.0,
                shadows: [Shadow(color: _transitionColor, blurRadius: 20), Shadow(color: _transitionColor.withOpacity(0.5), blurRadius: 40)],
              ),
            ),
            const SizedBox(height: 3),
            Text(
              _transitionSubtitle,
              style: TextStyle(color: _transitionColor.withOpacity(0.9), fontSize: 8.5, fontWeight: FontWeight.bold, letterSpacing: 2.5),
            ),
          ],
        ),
      ),
    );
  }

  void _showBluetoothList() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF0C121D),
        title: const Text("Select Bluetooth Controller"),
        content: SizedBox(
          width: double.maxFinite, height: 200,
          child: _devicesList.isEmpty
              ? const Center(child: Text("No paired devices found"))
              : ListView.builder(
                  itemCount: _devicesList.length,
                  itemBuilder: (_, i) => ListTile(
                    title: Text(_devicesList[i].name ?? "Device"),
                    subtitle: Text(_devicesList[i].address),
                    onTap: () { Navigator.pop(ctx); _connectToDevice(_devicesList[i]); },
                  ),
                ),
        ),
      ),
    );
  }
}

// ============================================================================
// 7. ARCADE MOTION HIGHWAY RASTER PAINTER (ENHANCED ADAS LANE & TARGET ANIMATION)
// ============================================================================
class ArcadeMotionHighwayPainter extends CustomPainter {
  final double displacement;
  final double velocityKmh;
  final double steeringAngle;
  final String driveMode;
  final bool normalLightsOn;
  final bool highBeamOn;
  final bool brakePressed;
  final int povMode;
  final double chassisPitch;
  final List<SimVehicle> trafficList;
  final Color accentColor;
  final bool adasActive;
  final double adasOpacity;
  final bool accActive;
  final String drivetrainMode;
  final double beatIntensity;

  ArcadeMotionHighwayPainter({
    required this.displacement,
    required this.velocityKmh,
    required this.steeringAngle,
    required this.driveMode,
    required this.normalLightsOn,
    required this.highBeamOn,
    required this.brakePressed,
    required this.povMode,
    required this.chassisPitch,
    required this.trafficList,
    required this.accentColor,
    required this.adasActive,
    required this.adasOpacity,
    required this.accActive,
    required this.drivetrainMode,
    required this.beatIntensity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double horizonY = size.height * (povMode == 0 ? 0.35 : 0.38);

    final double turnNorm = (steeringAngle / 180.0).clamp(-1.0, 1.0);
    final double horizonShift = turnNorm * 80.0;

    _drawSkyAndHorizon(canvas, size, horizonY);
    _drawArcadeCitySkyline(canvas, size, horizonY, horizonShift);
    _drawArcadeRoad(canvas, size, cx, horizonY, horizonShift);
    
    if (adasOpacity > 0.01) {
      _drawFuturisticAdasLaneAndTracking(canvas, size, cx, horizonY, horizonShift, turnNorm);
    }

    _drawRoadsideInfrastructure(canvas, size, cx, horizonY, horizonShift);
    _drawArcadeSpeedLines(canvas, size, cx, horizonY, horizonShift);
    _drawPerspectiveLaneMarkings(canvas, size, cx, horizonY, horizonShift);
    _drawOverheadGantry(canvas, size, cx, horizonY, horizonShift);
    _drawHeadlightBeams(canvas, size, cx, horizonY, horizonShift);

    if (povMode != 3) {
      _drawSurroundingTraffic(canvas, size, cx, horizonY, horizonShift);
    }

    _drawEgoVehicle(canvas, size, cx, horizonShift);
  }

  void _drawSkyAndHorizon(Canvas canvas, Size size, double horizonY) {
    Paint sky = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [const Color(0xFF01040A), const Color(0xFF071022), accentColor.withOpacity(0.12)],
        stops: const [0.0, 0.65, 1.0],
      ).createShader(Rect.fromLTWH(0, 0, size.width, horizonY));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, horizonY), sky);
  }

  void _drawArcadeCitySkyline(Canvas canvas, Size size, double horizonY, double turnShift) {
    final double parallax = turnShift * 0.18;
    final List<double> heights = [62, 90, 48, 112, 72, 98, 58, 120, 80, 94, 66];

    for (int i = 0; i < heights.length; i++) {
      double bx = (i * 36.0) - parallax - 20;
      double bh = heights[i];
      double by = horizonY - bh;
      double bw = 30.0;

      Paint facade = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter, end: Alignment.bottomCenter,
          colors: [const Color(0xFF162842), const Color(0xFF09121E)],
        ).createShader(Rect.fromLTWH(bx, by, bw, bh));
      canvas.drawRect(Rect.fromLTWH(bx, by, bw, bh), facade);

      Paint winWarm = Paint()..color = const Color(0xFFFFD54F).withOpacity(0.50);
      Paint winCyan = Paint()..color = accentColor.withOpacity(0.50);

      for (double wy = by + 6; wy < horizonY - 4; wy += 8) {
        if ((i + wy.toInt()) % 3 != 0) {
          canvas.drawRect(Rect.fromLTWH(bx + 4, wy, 4, 3), (i % 2 == 0) ? winWarm : winCyan);
          canvas.drawRect(Rect.fromLTWH(bx + 14, wy, 4, 3), winCyan);
        }
      }
    }
  }

  void _drawArcadeRoad(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    final Offset hLeft = Offset(cx - 38 + turnShift, horizonY);
    final Offset hRight = Offset(cx + 38 + turnShift, horizonY);
    final Offset bLeft = Offset(-160, size.height);
    final Offset bRight = Offset(size.width + 160, size.height);
    final Offset controlPt = Offset(cx + turnShift * 0.5, size.height * 0.72);

    Path roadPath = Path()
      ..moveTo(hLeft.dx, hLeft.dy)
      ..lineTo(hRight.dx, hRight.dy)
      ..quadraticBezierTo(controlPt.dx + (size.width * 0.45), controlPt.dy, bRight.dx, bRight.dy)
      ..lineTo(bLeft.dx, bLeft.dy)
      ..quadraticBezierTo(controlPt.dx - (size.width * 0.45), controlPt.dy, hLeft.dx, hLeft.dy)
      ..close();

    canvas.save();
    canvas.clipPath(roadPath);

    Paint asphalt = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter, end: Alignment.bottomCenter,
        colors: [const Color(0xFF0F1826), const Color(0xFF0A101A), const Color(0xFF04060A)],
      ).createShader(Rect.fromLTWH(0, horizonY, size.width, size.height - horizonY));
    canvas.drawRect(Rect.fromLTWH(0, horizonY, size.width, size.height - horizonY), asphalt);

    Paint neonGlow = Paint()
      ..shader = LinearGradient(
        begin: Alignment.centerLeft, end: Alignment.centerRight,
        colors: [Colors.transparent, accentColor.withOpacity(0.08), accentColor.withOpacity(0.18 + (beatIntensity * 0.15)), accentColor.withOpacity(0.08), Colors.transparent],
        stops: const [0.0, 0.35, 0.50, 0.65, 1.0],
      ).createShader(Rect.fromLTWH(cx - 120, horizonY, 240, size.height - horizonY))
      ..blendMode = BlendMode.screen;
    canvas.drawRect(Rect.fromLTWH(cx - 120, horizonY, 240, size.height - horizonY), neonGlow);

    canvas.restore();
  }

  // ENHANCED ADAS SCANNING LANE & FLOWING HUD PATH ANIMATION
  void _drawFuturisticAdasLaneAndTracking(Canvas canvas, Size size, double cx, double horizonY, double turnShift, double turnNorm) {
    final Offset hLeft = Offset(cx - 44 + turnShift, horizonY);
    final Offset cLeft = Offset(cx - 120 + turnShift * 1.3 - (turnNorm * 30), size.height * 0.65);
    final Offset bLeft = Offset(cx - 210 + turnShift * 1.9 - (turnNorm * 60), size.height);

    final Offset hRight = Offset(cx + 44 + turnShift, horizonY);
    final Offset cRight = Offset(cx + 120 + turnShift * 1.3 - (turnNorm * 30), size.height * 0.65);
    final Offset bRight = Offset(cx + 210 + turnShift * 1.9 - (turnNorm * 60), size.height);

    Path leftLane = Path()
      ..moveTo(hLeft.dx, hLeft.dy)
      ..quadraticBezierTo(cLeft.dx, cLeft.dy, bLeft.dx, bLeft.dy);

    Path rightLane = Path()
      ..moveTo(hRight.dx, hRight.dy)
      ..quadraticBezierTo(cRight.dx, cRight.dy, bRight.dx, bRight.dy);

    // Outer Glow Track
    Paint outerGlow = Paint()
      ..color = const Color(0xFF00E676).withOpacity(0.35 * adasOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 6.0
      ..strokeCap = StrokeCap.round
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);

    // Inner Core Line with Flowing Dash Effect
    Paint innerCore = Paint()
      ..color = Colors.white.withOpacity(0.95 * adasOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;

    canvas.drawPath(leftLane, outerGlow);
    canvas.drawPath(rightLane, outerGlow);
    canvas.drawPath(leftLane, innerCore);
    canvas.drawPath(rightLane, innerCore);

    // DRAW FLOWING HUD CHEVRONS ALONG THE PATH TO REPRESENT ACTIVE CALCULATED PATH
    Paint chevronPaint = Paint()
      ..color = const Color(0xFF00E676).withOpacity(0.85 * adasOpacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;

    double flowOffset = (displacement * 120.0) % 40.0;
    for (double y = horizonY + 40 + flowOffset; y < size.height - 20; y += 50) {
      double progressFactor = (y - horizonY) / (size.height - horizonY);
      double currentCx = cx + (turnShift * (1.0 - progressFactor));
      double spread = 24.0 + (progressFactor * 110.0);

      Path chevron = Path()
        ..moveTo(currentCx - spread + 8, y + 6)
        ..lineTo(currentCx, y)
        ..lineTo(currentCx + spread - 8, y + 6);
      canvas.drawPath(chevron, chevronPaint);
    }
  }

  void _drawRoadsideInfrastructure(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    for (int i = 0; i < 7; i++) {
      double z = ((i / 7.0) + displacement) % 1.0;
      double y = horizonY + (size.height - horizonY) * (z * z);
      double scale = 0.2 + (z * 0.9);

      double curveFactor = (1.0 - z);
      double curCenterX = cx + (turnShift * curveFactor * curveFactor);
      double laneWidth = 46.0 + (z * 175.0);

      Paint rail = Paint()..color = Color.lerp(const Color(0xFF1B2E46), const Color(0xFF385270), z)!;
      double postH = 15.0 * scale;
      canvas.drawRect(Rect.fromLTWH(curCenterX - laneWidth - (4 * scale), y - postH, 4 * scale, postH), rail);
      canvas.drawRect(Rect.fromLTWH(curCenterX + laneWidth, y - postH, 4 * scale, postH), rail);
    }
  }

  void _drawArcadeSpeedLines(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    if (velocityKmh < 30) return;
    Paint speedLinePaint = Paint()
      ..color = Colors.white.withOpacity(0.15)
      ..strokeWidth = 1.5;

    for (int i = 0; i < 6; i++) {
      double rx = cx + ((i - 3) * 75.0) + (math.sin(displacement * 10 + i) * 30);
      double ry = horizonY + ((displacement * 400 + i * 50) % (size.height - horizonY));
      canvas.drawLine(Offset(rx, ry), Offset(rx + (i % 2 == 0 ? 4 : -4), ry + 25), speedLinePaint);
    }
  }

  void _drawPerspectiveLaneMarkings(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    for (int i = 0; i < 8; i++) {
      double z = ((i / 8.0) + displacement) % 1.0;
      double y = horizonY + (size.height - horizonY) * (z * z);
      double scale = 0.16 + (z * 0.84);
      double dashLen = 8.0 + (z * 34.0);

      double curveFactor = (1.0 - z);
      double curCenterX = cx + (turnShift * curveFactor * curveFactor);
      double laneSpread = 30.0 + (z * 92.0);

      Paint lanePaint = Paint()..color = Colors.white.withOpacity(0.95)..strokeWidth = 2.2 * scale..strokeCap = StrokeCap.round;

      canvas.drawLine(Offset(curCenterX - laneSpread, y), Offset(curCenterX - laneSpread, y + dashLen), lanePaint);
      canvas.drawLine(Offset(curCenterX + laneSpread, y), Offset(curCenterX + laneSpread, y + dashLen), lanePaint);

      Paint catEye = Paint()..color = accentColor;
      canvas.drawCircle(Offset(curCenterX - laneSpread, y), 1.5 * scale, catEye);
      canvas.drawCircle(Offset(curCenterX + laneSpread, y), 1.5 * scale, catEye);
    }
  }

  void _drawOverheadGantry(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    double z = (displacement * 0.18) % 1.0;
    if (z > 0.10) {
      double y = horizonY + (size.height - horizonY) * (z * z) - (65.0 * z);
      double scale = 0.28 + (z * 0.88);
      double w = 240.0 * scale;
      double h = 50.0 * scale;
      double curCenterX = cx + (turnShift * (1.0 - z));

      Paint steel = Paint()..color = const Color(0xFF334A66)..strokeWidth = 2.2 * scale;
      canvas.drawLine(Offset(curCenterX - w / 2, y + h), Offset(curCenterX - w / 2, y), steel);
      canvas.drawLine(Offset(curCenterX + w / 2, y + h), Offset(curCenterX + w / 2, y), steel);
      canvas.drawLine(Offset(curCenterX - w / 2, y), Offset(curCenterX + w / 2, y), steel);
    }
  }

  void _drawHeadlightBeams(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    if (!normalLightsOn) return;
    double beamReach = highBeamOn ? 0.38 : 0.58;
    double beamIntensity = highBeamOn ? 0.42 : 0.22;

    Path beam = Path()
      ..moveTo(cx - 90, size.height)
      ..lineTo(cx + 90, size.height)
      ..lineTo(cx + turnShift * 0.7 + (highBeamOn ? 95 : 60), size.height * beamReach)
      ..lineTo(cx + turnShift * 0.7 - (highBeamOn ? 95 : 60), size.height * beamReach)
      ..close();

    canvas.drawPath(
      beam,
      Paint()
        ..shader = RadialGradient(
          center: Alignment(0.0, highBeamOn ? -0.1 : 0.3), radius: highBeamOn ? 1.4 : 0.95,
          colors: [const Color(0xFFE0F7FA).withOpacity(beamIntensity), const Color(0xFF90CAF9).withOpacity(beamIntensity * 0.3), Colors.transparent],
        ).createShader(Rect.fromLTWH(0, size.height * beamReach, size.width, size.height * (1.0 - beamReach)))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
  }

  void _drawSurroundingTraffic(Canvas canvas, Size size, double cx, double horizonY, double turnShift) {
    final sorted = List<SimVehicle>.from(trafficList)
      ..sort((a, b) => b.distanceMeters.compareTo(a.distanceMeters));

    for (var v in sorted) {
      if (v.distanceMeters < 3.5 || v.distanceMeters > 95.0) continue;

      double z = (1.0 - (v.distanceMeters / 95.0)).clamp(0.05, 1.0);
      double y = horizonY + (size.height - horizonY) * (z * z);
      double scale = 0.24 + (z * 0.86);

      double curveFactor = (1.0 - z);
      double curCenterX = cx + (turnShift * curveFactor * curveFactor);
      double laneSpread = v.lane * (34.0 + (z * 98.0));
      Offset pos = Offset(curCenterX + laneSpread, y);

      double w = 58.0 * scale;
      double h = 36.0 * scale;

      canvas.drawOval(
        Rect.fromCenter(center: Offset(pos.dx, pos.dy + h * 0.36), width: w * 1.15, height: h * 0.32),
        Paint()..color = Colors.black.withOpacity(0.75)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0),
      );

      Rect chassis = Rect.fromCenter(center: Offset(pos.dx, pos.dy + h * 0.08), width: w, height: h * 0.62);
      canvas.drawRRect(RRect.fromRectAndRadius(chassis, Radius.circular(4.0 * scale)), Paint()..color = v.bodyColor);

      Rect cabin = Rect.fromCenter(center: Offset(pos.dx, pos.dy - h * 0.22), width: w * 0.76, height: h * 0.44);
      canvas.drawRRect(RRect.fromRectAndRadius(cabin, Radius.circular(3.0 * scale)), Paint()..color = const Color(0xFF101C2C));

      Paint tailGlow = Paint()
        ..color = const Color(0xFFFF1744)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 5.0 * scale);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(pos.dx - w * 0.32, pos.dy + h * 0.05), width: w * 0.20, height: h * 0.14), Radius.circular(1.5 * scale)), tailGlow);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(pos.dx + w * 0.32, pos.dy + h * 0.05), width: w * 0.20, height: h * 0.14), Radius.circular(1.5 * scale)), tailGlow);

      Color boxColor = v.lane == 0 ? const Color(0xFF00E676) : Colors.white60;
      Rect bbox = Rect.fromCenter(center: pos, width: w * 1.18, height: h * 1.18);
      canvas.drawRect(bbox, Paint()..color = boxColor..strokeWidth = 1.8..style = PaintingStyle.stroke);

      TextPainter tag = TextPainter(
        text: TextSpan(text: "${v.distanceMeters.toStringAsFixed(1)} m", style: TextStyle(color: Colors.white, fontSize: 8.0 * scale, fontWeight: FontWeight.bold, backgroundColor: Colors.black87)),
        textDirection: TextDirection.ltr,
      )..layout();
      tag.paint(canvas, Offset(bbox.center.dx - (tag.width / 2), bbox.top - 14));
    }
  }

  void _drawEgoVehicle(Canvas canvas, Size size, double cx, double turnShift) {
    if (povMode == 1) {
      double egoX = cx + (turnShift * 0.16);
      double egoY = (size.height * 0.77) + chassisPitch;
      double w = 116.0;
      double h = 64.0;

      canvas.drawOval(
        Rect.fromCenter(center: Offset(egoX, egoY + h * 0.40), width: w * 1.25, height: h * 0.35),
        Paint()..color = Colors.black.withOpacity(0.90)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0),
      );

      Paint chassis = Paint()..color = const Color(0xFF162338);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: Offset(egoX, egoY + h * 0.05), width: w, height: h * 0.65), const Radius.circular(10.0)), chassis);

      canvas.drawLine(Offset(egoX - w * 0.42, egoY + h * 0.32), Offset(egoX + w * 0.42, egoY + h * 0.32), Paint()..color = accentColor..strokeWidth = 2.5);

      Paint drivetrainGlow = Paint()
        ..color = (drivetrainMode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744)).withOpacity(0.50)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6.0);
      
      if (drivetrainMode == "FWD") {
        canvas.drawCircle(Offset(egoX - w * 0.35, egoY + h * 0.28), 6.0, drivetrainGlow);
        canvas.drawCircle(Offset(egoX + w * 0.35, egoY + h * 0.28), 6.0, drivetrainGlow);
      } else {
        canvas.drawCircle(Offset(egoX - w * 0.35, egoY - h * 0.05), 6.0, drivetrainGlow);
        canvas.drawCircle(Offset(egoX + w * 0.35, egoY - h * 0.05), 6.0, drivetrainGlow);
      }

      Rect cabin = Rect.fromCenter(center: Offset(egoX, egoY - h * 0.25), width: w * 0.74, height: h * 0.46);
      canvas.drawRRect(RRect.fromRectAndRadius(cabin, const Radius.circular(6.0)), Paint()..color = const Color(0xFF0B121E));

      Rect plate = Rect.fromCenter(center: Offset(egoX, egoY + h * 0.18), width: 42, height: 12);
      canvas.drawRRect(RRect.fromRectAndRadius(plate, const Radius.circular(2)), Paint()..color = const Color(0xFF070B12));
      TextPainter pt = TextPainter(
        text: const TextSpan(text: "GEAR HEADS", style: TextStyle(color: Colors.white, fontSize: 6.0, fontWeight: FontWeight.w900)),
        textDirection: TextDirection.ltr,
      )..layout();
      pt.paint(canvas, Offset(plate.center.dx - pt.width / 2, plate.center.dy - pt.height / 2));

      Paint lightbar = Paint()
        ..color = brakePressed ? const Color(0xFFFF1744) : const Color(0xFFFF3366)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, brakePressed ? 14.0 : 6.0);
      Rect barRect = Rect.fromCenter(center: Offset(egoX, egoY - h * 0.02), width: w * 0.90, height: 6.5);
      canvas.drawRRect(RRect.fromRectAndRadius(barRect, const Radius.circular(3)), lightbar);
      canvas.drawRRect(RRect.fromRectAndRadius(barRect.deflate(1.2), const Radius.circular(1.5)), Paint()..color = Colors.white);
    } else {
      Path hood = Path()
        ..moveTo(cx - 135, size.height)
        ..quadraticBezierTo(cx, size.height - 32 + chassisPitch, cx + 135, size.height)
        ..close();
      canvas.drawPath(hood, Paint()..color = const Color(0xFF0D1524));
      canvas.drawPath(hood, Paint()..color = accentColor.withOpacity(0.5)..style = PaintingStyle.stroke..strokeWidth = 2.0);
    }
  }

  @override
  bool shouldRepaint(covariant ArcadeMotionHighwayPainter oldDelegate) => true;
}

// ============================================================================
// 8. TRANSITION PAINTERS & WARP PAINTER
// ============================================================================
class DrivetrainWarpPainter extends CustomPainter {
  final double progress;
  final String mode;

  DrivetrainWarpPainter({required this.progress, required this.mode});

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = (mode == "FWD" ? const Color(0xFF00E5FF) : const Color(0xFFFF1744)).withOpacity((1.0 - progress) * 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 + (progress * 3.0);

    final Offset center = Offset(size.width / 2, size.height / 2);
    double maxRadius = math.max(size.width, size.height) * progress;

    for (int i = 0; i < 3; i++) {
      double r = maxRadius * (0.4 + (i * 0.3));
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant DrivetrainWarpPainter oldDelegate) => true;
}

class HorizontalEnergyBusPainter extends CustomPainter {
  final Offset origin;
  final double progress;
  final bool isForward;
  final Color color;

  HorizontalEnergyBusPainter({required this.origin, required this.progress, required this.isForward, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    double targetX = size.width * 0.50;
    double currentX = isForward ? origin.dx + (targetX - origin.dx) * progress : targetX + (origin.dx - targetX) * (1.0 - progress);
    double busY = origin.dy;

    Paint linePaint = Paint()
      ..shader = LinearGradient(colors: [Colors.transparent, color.withOpacity(0.8), Colors.white, color.withOpacity(0.8), Colors.transparent]).createShader(Rect.fromLTWH(currentX - 50, busY - 4, 100, 8))
      ..strokeWidth = 3.0;

    canvas.drawLine(Offset(isForward ? origin.dx : targetX, busY), Offset(currentX, busY), linePaint);
    canvas.drawCircle(Offset(currentX, busY), 5.0, Paint()..color = color.withOpacity(0.9)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    canvas.drawCircle(Offset(currentX, busY), 2.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant HorizontalEnergyBusPainter oldDelegate) => true;
}