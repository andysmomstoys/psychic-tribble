import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:health/health.dart';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class WearSession {
  final DateTime start;
  final DateTime end;

  WearSession(this.start, this.end);

  Duration get duration => end.difference(start);

  String toCsv() {
    return '\${start.toIso8601String()},\${end.toIso8601String()},\${duration.inSeconds}';
  }
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SmartPuck BLE + Health',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  FlutterBluePlus flutterBlue = FlutterBluePlus.instance;
  HealthFactory health = HealthFactory();

  BluetoothDevice? device;
  BluetoothCharacteristic? controlChar;
  BluetoothCharacteristic? pressureChar;
  BluetoothCharacteristic? vacuumLevelChar;

  bool isConnected = false;
  bool isOn = false;
  DateTime? sessionStart;
  List<WearSession> sessions = [];

  String status = "Disconnected";
  String pressure = "N/A";
  double vacuumLevel = 8;

  final serviceUuid = Guid("DA2B84F1-6279-48DE-BDC0-AFBEA0226079");
  final onOffCharUuid = Guid("A87988B9-694C-479C-900E-95DFA6C00A24");
  final pressureCharUuid = Guid("18CDA784-4BD3-4370-85BB-BFED91EC86AF");
  final vacuumLevelUuid = Guid("BF03260C-7205-4C25-AF43-93B1C299D159");

  @override
  void initState() {
    super.initState();
    FlutterBluePlus.setLogLevel(LogLevel.verbose);
    _authorizeHealth();
  }

  Future<void> _authorizeHealth() async {
    final types = [HealthDataType.MINDFULNESS];
    final access = await health.requestAuthorization(types);
    setState(() {
      status = access ? "Health access granted" : "Health access denied";
    });
  }

  void startScan() {
    flutterBlue.startScan(timeout: const Duration(seconds: 5));
    flutterBlue.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.advertisementData.serviceUuids.contains(serviceUuid.toString().toLowerCase())) {
          flutterBlue.stopScan();
          connectToDevice(r.device);
          break;
        }
      }
    });
  }

  void connectToDevice(BluetoothDevice d) async {
    await d.connect();
    device = d;
    isConnected = true;
    status = "Connected";
    setState(() {});

    List<BluetoothService> services = await d.discoverServices();
    for (var s in services) {
      if (s.uuid == serviceUuid) {
        for (var c in s.characteristics) {
          if (c.uuid == onOffCharUuid) controlChar = c;
          if (c.uuid == pressureCharUuid) {
            pressureChar = c;
            await c.setNotifyValue(true);
            c.onValueReceived.listen((data) {
              final decoded = utf8.decode(data);
              setState(() => pressure = decoded);
            });
          }
          if (c.uuid == vacuumLevelUuid) vacuumLevelChar = c;
        }
        status = "Ready";
        setState(() {});
      }
    }
  }

  void sendCommand(bool turnOn) async {
    if (controlChar == null) return;
    await controlChar!.write([turnOn ? 0x01 : 0x00], withoutResponse: false);

    if (turnOn) {
      sessionStart = DateTime.now();
    } else if (sessionStart != null) {
      final end = DateTime.now();
      final session = WearSession(sessionStart!, end);
      sessions.add(session);
      sessionStart = null;
      await _logToHealth(session);
    }

    isOn = turnOn;
    setState(() {});
  }

  Future<void> _logToHealth(WearSession session) async {
    await health.writeHealthData(
      session.duration.inSeconds.toDouble(),
      HealthDataType.MINDFULNESS,
      session.start,
      session.end,
    );
  }

  void updateVacuumLevel(double level) async {
    vacuumLevel = level;
    if (vacuumLevelChar != null) {
      await vacuumLevelChar!.write([level.toInt()]);
    }
    setState(() {});
  }

  String formatDuration(Duration d) {
    return "\${d.inHours}h \${(d.inMinutes % 60)}m \${(d.inSeconds % 60)}s";
  }

  Duration get totalDuration {
    return sessions.fold(Duration.zero, (a, b) => a + b.duration);
  }

  Future<void> exportCsv() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('\${dir.path}/wear_sessions.csv');
    final csv = StringBuffer("Start,End,Duration (seconds)\n");
    for (var s in sessions) {
      csv.writeln(s.toCsv());
    }
    await file.writeAsString(csv.toString());
    setState(() {
      status = "Exported to \${file.path}";
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("SmartPuck BLE + Health")),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text("Status: \$status"),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: startScan,
                child: const Text("Connect to Prosthetic"),
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: () => sendCommand(true),
                child: const Text("Send ON Command"),
              ),
              ElevatedButton(
                onPressed: () => sendCommand(false),
                child: const Text("Send OFF Command"),
              ),
              const SizedBox(height: 10),
              Text("Total Wear Time: \${formatDuration(totalDuration)}"),
              const SizedBox(height: 10),
              Text("Vacuum Pressure: \$pressure"),
              const SizedBox(height: 10),
              Text("Vacuum Level: \${vacuumLevel.toInt()}"),
              Slider(
                min: 0,
                max: 15,
                divisions: 15,
                value: vacuumLevel,
                label: vacuumLevel.toInt().toString(),
                onChanged: updateVacuumLevel,
              ),
              const SizedBox(height: 10),
              ElevatedButton(
                onPressed: exportCsv,
                child: const Text("Export CSV"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}