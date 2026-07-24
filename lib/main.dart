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
  final GlobalKey _scheduleKey = GlobalKey();
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
      final boundary = _scheduleKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return;

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

  String getDateRange(WeekSchedule s) {
    final sorted = s.days.map((d) => d.dayIndex).toList()..sort();
    if (sorted.isEmpty) return '';
    final first = s.weekStart.add(Duration(days: sorted.first));
    final last = s.weekStart.add(Duration(days: sorted.last));
    return '${first.month}/${first.day} - ${last.month}/${last.day}';
  }

  String _dayName(int dayIndex) {
    const names = ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
    return names[dayIndex];
  }

  /// 天数映射：设置(0=周日,1=周一...6=周六) → 算法(0=周一...6=周日)
  int _toSolverDay(int d) => (d + 6) % 7;

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
    // 从排班数据直接取天数，排除关门日
        final weekDays = schedule.days.map((d) => d.dayIndex).toList()..sort();

    return RepaintBoundary(
      key: _scheduleKey,
      child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('本周排班表', style: Theme.of(context).textTheme.headlineSmall),
                        Text(getDateRange(schedule), style: TextStyle(color: Colors.grey[600])),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _generateNextWeek,
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('生成下周'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 水平滚动日历式排班表
          SizedBox(
            height: 180,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: weekDays.length,
              itemBuilder: (context, index) {
                final dayIndex = weekDays[index];
                final day = schedule.days.firstWhere((d) => d.dayIndex == dayIndex);
                final dayDate = schedule.weekStart.add(Duration(days: dayIndex));
                final today = DateTime.now();
                final isToday = dayDate.year == today.year &&
                                dayDate.month == today.month &&
                                dayDate.day == today.day;

                return Container(
                  width: 130,
                  margin: const EdgeInsets.only(right: 8),
                  child: Card(
                    color: isToday ? Colors.blue[50] : null,
                    shape: isToday
                        ? RoundedRectangleBorder(
                            side: BorderSide(color: Colors.blue, width: 2),
                            borderRadius: BorderRadius.circular(12),
                          )
                        : null,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // 日期头
                          Text(
                            _dayName(dayIndex),
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 16,
                              color: isToday ? Colors.blue : null,
                            ),
                          ),
                          Text(
                            '${dayDate.month}/${dayDate.day}',
                            style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                          ),
                          if (isToday)
                            Container(
                              margin: const EdgeInsets.only(top: 2),
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blue,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text('今天', style: TextStyle(color: Colors.white, fontSize: 10)),
                            ),
                          const Divider(height: 12),

                          // 人员分配
                          _buildSlot('🏦 99999', day.person99999),
                          const SizedBox(height: 3),
                          _buildSlot('🤝 协管', day.personXieguan),
                          const SizedBox(height: 3),

                          // 休班（当天不上班）
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: Colors.orange[100],
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text('休班 ${day.personRest}',
                                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                              ),
                            ],
                          ),

                          // 中午休息（上班但午休）
                          if (day.personNoonRest.isNotEmpty)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.free_breakfast, size: 12, color: Colors.brown[400]),
                                const SizedBox(width: 2),
                                Text('午休 ${day.personNoonRest}',
                                    style: TextStyle(fontSize: 11, color: Colors.brown[600])),
                              ],
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 16),

          // 统计
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('本周统计', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  ...schedule.names.map((name) {
                    int count99999 = 0, countXieguan = 0;
                    for (final day in schedule.days) {
                      if (day.person99999 == name) count99999++;
                      if (day.personXieguan == name) countXieguan++;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        children: [
                          SizedBox(width: 64, child: Text(name, style: const TextStyle(fontWeight: FontWeight.bold))),
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
      ),
    );
  }

  Widget _buildSlot(String label, String name) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text('$label ', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
        Text(name, style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 13)),
      ],
    );
  }


    Future<void> _generateNextWeek() async {
    if (_currentSchedule == null) return;
    // 生成本周下周一的日期
    final nextMonday = _currentSchedule!.weekStart.add(const Duration(days: 7));
    
    // 获取上周日(本周六)的排班用于跨周约束
    String? lastSunday99999;
    for (final day in _currentSchedule!.days) {
      if (day.dayIndex == 6) {
        lastSunday99999 = day.person99999;
        break;
      }
    }

    final solver = SimpleScheduleSolver(
      names: _names,
      userRestDays: _restDays.map(_toSolverDay).toList(),
      closingDay: _toSolverDay(_closingDay),
      lastSunday99999: lastSunday99999,
    );

    final schedule = solver.solve(nextMonday);
    if (schedule != null) {
      await DatabaseService.saveSchedule(schedule);
      setState(() => _currentSchedule = schedule);
      await _loadHistory();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('下周排班已生成！'), backgroundColor: Colors.green),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('排班失败，请检查设置'), backgroundColor: Colors.red),
        );
      }
    }
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
