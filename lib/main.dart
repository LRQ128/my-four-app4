import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';

import 'models/schedule.dart';
import 'models/solver.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const SchedulingApp());
}

class SchedulingApp extends StatelessWidget {
  const SchedulingApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '排班App',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

// ============ 数据服务 ============

class DatabaseService {
  static Database? _db;

  static Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _initDb();
    return _db!;
  }

  static Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = '${dir.path}/schedule.db';
    return await openDatabase(path, version: 1, onCreate: (db, version) async {
      await db.execute('''
        CREATE TABLE schedules (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          week_start TEXT NOT NULL,
          names TEXT NOT NULL,
          closing_day INTEGER NOT NULL,
          rest_days TEXT NOT NULL,
          days_json TEXT NOT NULL,
          created_at TEXT NOT NULL
        )
      ''');
      await db.execute('''
        CREATE TABLE settings (
          key TEXT PRIMARY KEY,
          value TEXT NOT NULL
        )
      ''');
    });
  }

  static Future<void> saveSchedule(WeekSchedule schedule) async {
    final db = await database;
    await db.insert('schedules', {
      'week_start': schedule.weekStart.toIso8601String(),
      'names': schedule.names.join(','),
      'closing_day': schedule.closingDay,
      'rest_days': schedule.restDays.join(','),
      'days_json': DayScheduleEncoder.encodeList(schedule.days),
      'created_at': DateTime.now().toIso8601String(),
    });
  }

  static Future<List<WeekSchedule>> loadSchedules() async {
    final db = await database;
    final maps = await db.query('schedules', orderBy: 'week_start DESC');
    return maps.map((m) => WeekSchedule(
      weekStart: DateTime.parse(m['week_start'] as String),
      names: (m['names'] as String).split(','),
      closingDay: m['closing_day'] as int,
      restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
      days: DayScheduleEncoder.decodeList(m['days_json'] as String),
    )).toList();
  }

  static Future<WeekSchedule?> loadLatestSchedule() async {
    final db = await database;
    final maps = await db.query('schedules', orderBy: 'week_start DESC', limit: 1);
    if (maps.isEmpty) return null;
    final m = maps.first;
    return WeekSchedule(
      weekStart: DateTime.parse(m['week_start'] as String),
      names: (m['names'] as String).split(','),
      closingDay: m['closing_day'] as int,
      restDays: (m['rest_days'] as String).split(',').map(int.parse).toList(),
      days: DayScheduleEncoder.decodeList(m['days_json'] as String),
    );
  }

  static Future<void> saveSetting(String key, String value) async {
    final db = await database;
    await db.insert('settings', {'key': key, 'value': value},
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  static Future<String?> loadSetting(String key) async {
    final db = await database;
    final maps = await db.query('settings', where: 'key = ?', whereArgs: [key]);
    if (maps.isEmpty) return null;
    return maps.first['value'] as String;
  }
}

// ============ 数据编解码 ============

class DayScheduleEncoder {
  static String encodeList(List<DaySchedule> days) {
    return days.map((d) => '${d.dayIndex}|${d.person99999}|${d.personXieguan}|${d.personRest}').join(';;');
  }

  static List<DaySchedule> decodeList(String data) {
    return data.split(';;').map((s) {
      final parts = s.split('|');
      return DaySchedule(
        dayIndex: int.parse(parts[0]),
        person99999: parts[1],
        personXieguan: parts[2],
        personRest: parts[3],
      );
    }).toList();
  }
}

// ============ 主页面 ============

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;
  List<String> _names = ['张三', '李四', '王五'];
  int _closingDay = 6; // 默认周六
  List<int> _restDays = [0,2, 4]; // 默认休班日
  WeekSchedule? _currentSchedule;
  List<WeekSchedule> _history = [];

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadHistory();
  }

  Future<void> _loadSettings() async {
    final namesStr = await DatabaseService.loadSetting('names');
    if (namesStr != null) {
      setState(() => _names = namesStr.split(','));
    }
    final closingStr = await DatabaseService.loadSetting('closing_day');
    if (closingStr != null) {
      setState(() => _closingDay = int.parse(closingStr));
    }
  }

  Future<void> _loadHistory() async {
    final schedules = await DatabaseService.loadSchedules();
    setState(() => _history = schedules);
  }

  Future<void> _generateSchedule() async {
    // 获取上周排班用于跨周约束
    String? lastSunday99999;
    if (_history.isNotEmpty) {
      final lastWeek = _history.first;
      for (final day in lastWeek.days) {
        if (day.dayIndex == 6) {
          // 周日(solver中6=周日)
          lastSunday99999 = day.person99999;
          break;
        }
      }
    }

    // 天数映射：设置(0=周日,1=周一...6=周六) → 算法(0=周一...6=周日)
    int _toSolverDay(int d) => (d + 6) % 7;

    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: lastSunday99999,
    );

    final now = DateTime.now();
    // 计算本周一的日期
    final daysSinceMonday = now.weekday - 1;
    final monday = now.subtract(Duration(days: daysSinceMonday));

    final schedule = solver.solve(monday);

    if (schedule != null) {
      await DatabaseService.saveSchedule(schedule);
      setState(() => _currentSchedule = schedule);
      await _loadHistory();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('排班成功！'), backgroundColor: Colors.green),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('无法生成排班，请检查约束条件'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Future<void> _exportToImage() async {
    if (_currentSchedule == null) return;

    try {
      final repaintBoundaryKey = GlobalKey();
      // 渲染排班表为图片
      final renderObject = context.findRenderObject();
      if (renderObject == null) return;

      // 简化：直接截图当前屏幕
      final boundary = renderObject as RenderRepaintBoundary;
      final image = await boundary.toImage(pixelRatio: 2.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();

      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/schedule_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(pngBytes);

      // 分享功能暂不可用

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('排班表已导出'), backgroundColor: Colors.green),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导出失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  String _dayName(int dayIndex) {
    const names = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];
    return names[dayIndex];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('排班App'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          if (_currentSchedule != null)
            IconButton(
              icon: const Icon(Icons.download),
              onPressed: _exportToImage,
              tooltip: '导出排班表',
            ),
        ],
      ),
      body: _currentSchedule == null ? _buildEmptyState() : _buildScheduleView(),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) => setState(() => _currentIndex = index),
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.calendar_month), label: '排班'),
          BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
          BottomNavigationBarItem(icon: Icon(Icons.history), label: '历史'),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.calendar_today, size: 80, color: Colors.grey[400]),
          const SizedBox(height: 16),
          Text('暂无排班', style: TextStyle(fontSize: 18, color: Colors.grey[600])),
          const SizedBox(height: 8),
          Text('请先在设置中配置柜员和休班日', style: TextStyle(color: Colors.grey[500])),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _showSettings,
            icon: const Icon(Icons.settings),
            label: const Text('去设置'),
          ),
        ],
      ),
    );
  }

  Widget _buildScheduleView() {
    final schedule = _currentSchedule!;
    final weekDays = <int>[];
    for (int d = 0; d < 7; d++) {
      if (d != schedule.closingDay) weekDays.add(d);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '本周排班表',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${schedule.weekStart.month}/${schedule.weekStart.day} - ${schedule.weekStart.add(const Duration(days: 5)).month}/${schedule.weekStart.add(const Duration(days: 5)).day}',
                    style: TextStyle(color: Colors.grey[600]),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 排班表
          ...weekDays.map((dayIndex) {
            final day = schedule.days.firstWhere((d) => d.dayIndex == dayIndex);
            final isToday = DateTime.now().weekday == (dayIndex + 1) % 7;

            return Card(
              color: isToday ? Colors.blue[50] : null,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Row(
                  children: [
                    SizedBox(
                      width: 48,
                      child: Column(
                        children: [
                          Text(
                            _dayName(dayIndex),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: isToday ? Colors.blue : null,
                            ),
                          ),
                          if (isToday)
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text('今天', style: TextStyle(color: Colors.white, fontSize: 10)),
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildRoleRow('🏦 盯99999', day.person99999),
                          const SizedBox(height: 4),
                          _buildRoleRow('🤝 盯协管', day.personXieguan),
                        ],
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.orange[50],
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Column(
                        children: [
                          const Text('休息', style: TextStyle(fontSize: 12, color: Colors.orange)),
                          Text(day.personRest, style: const TextStyle(fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),

          const SizedBox(height: 24),

          // 统计
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本周统计', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ...schedule.names.map((name) {
                    int count99999 = 0, countXieguan = 0;
                    for (final day in schedule.days) {
                      if (day.person99999 == name) count99999++;
                      if (day.personXieguan == name) countXieguan++;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Row(
                        children: [
                          SizedBox(width: 60, child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
                          Text('🏦×$count99999  🤝×$countXieguan'),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoleRow(String label, String name) {
    return Row(
      children: [
        SizedBox(width: 80, child: Text(label, style: TextStyle(color: Colors.grey[600], fontSize: 13))),
        Text(name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 15)),
      ],
    );
  }

  void _showSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => SettingsScreen(
          names: List.from(_names),
          closingDay: _closingDay,
          restDays: List.from(_restDays),
          onSave: (names, closingDay, restDays) async {
            setState(() {
              _names = names;
              _closingDay = closingDay;
              _restDays = restDays;
            });
            await DatabaseService.saveSetting('names', names.join(','));
            await DatabaseService.saveSetting('closing_day', closingDay.toString());
            await DatabaseService.saveSetting('rest_days', restDays.join(','));
            _generateSchedule();
          },
        ),
      ),
    );
  }
}

// ============ 设置页面 ============

class SettingsScreen extends StatefulWidget {
  final List<String> names;
  final int closingDay;
  final List<int> restDays;
  final Function(List<String>, int, List<int>) onSave;

  const SettingsScreen({
    super.key,
    required this.names,
    required this.closingDay,
    required this.restDays,
    required this.onSave,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late List<TextEditingController> _nameControllers;
  late int _closingDay;
  late List<int> _restDays;

  @override
  void initState() {
    super.initState();
    _nameControllers = widget.names.map((n) => TextEditingController(text: n)).toList();
    _closingDay = widget.closingDay;
    _restDays = List.from(widget.restDays);
  }

  @override
  void dispose() {
    for (var c in _nameControllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
        actions: [
          TextButton(
            onPressed: () {
              widget.onSave(
                _nameControllers.map((c) => c.text).toList(),
                _closingDay,
                _restDays,
              );
              Navigator.pop(context);
            },
            child: const Text('保存'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 柜员姓名设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('柜员姓名', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ...List.generate(3, (i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextField(
                      controller: _nameControllers[i],
                      decoration: InputDecoration(
                        labelText: '柜员${i + 1}',
                        border: const OutlineInputBorder(),
                      ),
                    ),
                  )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 关门日设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('每周关门日', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    value: _closingDay,
                    decoration: const InputDecoration(border: OutlineInputBorder()),
                    items: const [
                      DropdownMenuItem(value: 0, child: Text('周日')),
                      DropdownMenuItem(value: 1, child: Text('周一')),
                      DropdownMenuItem(value: 2, child: Text('周二')),
                      DropdownMenuItem(value: 3, child: Text('周三')),
                      DropdownMenuItem(value: 4, child: Text('周四')),
                      DropdownMenuItem(value: 5, child: Text('周五')),
                      DropdownMenuItem(value: 6, child: Text('周六')),
                    ],
                    onChanged: (v) => setState(() => _closingDay = v!),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 休班日设置
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('每人休班日', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  ...List.generate(3, (i) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: DropdownButtonFormField<int>(
                      value: _restDays[i],
                      decoration: InputDecoration(
                        labelText: '${_nameControllers[i].text} 休班日',
                        border: const OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('周日')),
                        DropdownMenuItem(value: 1, child: Text('周一')),
                        DropdownMenuItem(value: 2, child: Text('周二')),
                        DropdownMenuItem(value: 3, child: Text('周三')),
                        DropdownMenuItem(value: 4, child: Text('周四')),
                        DropdownMenuItem(value: 5, child: Text('周五')),
                      ],
                      onChanged: (v) => setState(() => _restDays[i] = v!),
                    ),
                  )),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),

          // 生成排班按钮
          SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton.icon(
              onPressed: () {
                widget.onSave(
                  _nameControllers.map((c) => c.text).toList(),
                  _closingDay,
                  _restDays,
                );
                Navigator.pop(context);
              },
              icon: const Icon(Icons.auto_awesome),
              label: const Text('保存并生成排班', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}
